#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
配置驱动的 strm 生成器（Docker 版）

- 扫描 Alist 目录生成 .strm（电影 / 电视剧命名规则）
- 经 docker.sock 用 tar 管道写入 Emby 容器媒体目录
  （兼容飞牛/老G速装里 /media 为容器内层叠 loop 镜像、宿主机无对应目录的情况）
- 可选触发 Emby 媒体库刷新

新增挂载目录：只改 compose 里的 MAPPINGS（加一条映射），重启/重跑即可。
也可挂载 config.json 并用 CONFIG_FILE 指向它来配置。
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse

import requests

OUT_ROOT = os.environ.get("OUT_ROOT", "/out")
VIDEO_EXT = {
    ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm",
    ".ts", ".m2ts", ".iso", ".rmvb", ".vob", ".mpg", ".mpeg",
}

TOKEN = None
ALIST = ""


def _env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and (v is None or str(v).strip() == ""):
        print(f"[FATAL] 缺少必需环境变量 {name}", flush=True)
        sys.exit(2)
    return v


def load_config():
    cfg = {
        "alist_base": _env("ALIST_BASE", "http://127.0.0.1:5678"),
        "alist_username": _env("ALIST_USERNAME", "guest"),
        "alist_password": _env("ALIST_PASSWORD", "guest_Api789"),
        "public_prefix": _env("PUBLIC_PREFIX", ""),
        "emby_public": _env("EMBY_PUBLIC", ""),
        "emby_api_key": _env("EMBY_API_KEY", ""),
        "emby_container": _env("EMBY_CONTAINER", "emby"),
        "auto_scan": _env("AUTO_SCAN", "true").lower() in ("1", "true", "yes", "on"),
    }
    # 可选：挂载 config.json 覆盖上面的环境变量
    cfg_file = os.environ.get("CONFIG_FILE", "")
    if cfg_file and os.path.exists(cfg_file):
        with open(cfg_file, encoding="utf-8") as f:
            cfg.update(json.load(f))
    # mappings：环境变量 MAPPINGS 优先，其次 config.json
    mappings = None
    if os.environ.get("MAPPINGS"):
        try:
            mappings = json.loads(os.environ["MAPPINGS"])
        except Exception as e:
            print(f"[FATAL] MAPPINGS 不是合法 JSON: {e}", flush=True)
            sys.exit(2)
    elif cfg.get("mappings"):
        mappings = cfg["mappings"]
    if not isinstance(mappings, list) or not mappings:
        print("[FATAL] 未配置 MAPPINGS（映射列表为空）", flush=True)
        sys.exit(2)
    cfg["mappings"] = mappings
    return cfg


def login(cfg):
    global TOKEN, ALIST
    ALIST = cfg["alist_base"].rstrip("/")
    r = requests.post(
        ALIST + "/api/auth/login",
        json={"username": cfg["alist_username"], "password": cfg["alist_password"]},
        timeout=30,
    )
    data = r.json()
    if data.get("code") != 200:
        raise RuntimeError(f"Alist 登录失败: {data}")
    TOKEN = data["data"]["token"]


def list_dir(path):
    items, page = [], 1
    while True:
        headers = {"Content-Type": "application/json"}
        if TOKEN:
            headers["Authorization"] = TOKEN
        r = requests.post(
            ALIST + "/api/fs/list",
            headers=headers,
            json={"path": path, "page": page, "per_page": 1000, "refresh": False},
            timeout=60,
        )
        r.raise_for_status()
        d = r.json()
        if d.get("code") != 200:
            print(f"  [WARN] list {path} code={d.get('code')} msg={d.get('message')}", flush=True)
            break
        data = d.get("data") or {}
        items.extend(data.get("content") or [])
        total = data.get("total") or 0
        if page * 1000 >= total:
            break
        page += 1
    return items


def is_video(name):
    return os.path.splitext(name)[1].lower() in VIDEO_EXT


def gen_se(name, fallback):
    m = re.search(r"[Ss](\d{1,2})[Ee](\d{1,4})", name)
    if m:
        return int(m.group(1)), int(m.group(2))
    m = re.search(r"[Ee][Pp]?(\d{1,4})", name)
    if m:
        return 1, int(m.group(1))
    m = re.search(r"第\s*(\d{1,4})\s*集", name)
    if m:
        return 1, int(m.group(1))
    return 1, fallback


def walk(path, rel=""):
    for it in list_dir(path):
        name = it.get("name", "")
        full = path.rstrip("/") + "/" + name
        if it.get("is_dir"):
            yield from walk(full, os.path.join(rel, name) if rel else name)
        elif is_video(name):
            yield (rel, name, full)


def direct_url(public_prefix, alist_full_path):
    return public_prefix.rstrip("/") + "/d" + urllib.parse.quote(alist_full_path, safe="/")


def clean(s):
    return re.sub(r"\s+", " ", s).strip()


def process(cfg, mapping, root):
    src, dtype, target = mapping["alist_path"], mapping["type"], mapping["emby_path"]
    public_prefix = cfg["public_prefix"]
    if not public_prefix:
        print("[FATAL] 未配置 PUBLIC_PREFIX（strm 直链前缀）", flush=True)
        sys.exit(2)
    out = os.path.join(root, target.strip("/"))
    os.makedirs(out, exist_ok=True)
    cnt = 0
    for rel, name, full in walk(src):
        if dtype == "movie":
            folder = rel.split(os.sep)[0] if os.sep in rel else clean(os.path.splitext(name)[0])
            md = os.path.join(out, folder)
            os.makedirs(md, exist_ok=True)
            sp = os.path.join(md, clean(os.path.splitext(name)[0]) + ".strm")
        else:
            parts = rel.split(os.sep)
            series = parts[0] if parts else "未知剧集"
            sdir = parts[1] if len(parts) >= 2 and re.match(
                r"(?i)season|第.{1,3}季|S\d", parts[1]
            ) else None
            season, ep = gen_se(name, 1)
            if sdir:
                sm = re.search(r"(\d+)", sdir)
                if sm:
                    season = int(sm.group(1))
            ed = os.path.join(out, series, f"Season {season}")
            os.makedirs(ed, exist_ok=True)
            ep_title = clean(os.path.splitext(name)[0])
            sp = os.path.join(ed, f"{series} - S{season:02d}E{ep:02d} - {ep_title}.strm")
        with open(sp, "w", encoding="utf-8") as f:
            f.write(direct_url(public_prefix, full))
        cnt += 1
    return cnt


def sync_to_emby(cfg, root):
    """tar 管道经 docker exec 解包进 Emby 容器根目录，写入 /media/...。"""
    container = cfg["emby_container"]
    tar = subprocess.Popen(
        ["tar", "-cf", "-", "-C", root, "."],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    dx = subprocess.run(
        ["docker", "exec", "-i", container, "tar", "-xf", "-", "-C", "/"],
        stdin=tar.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    tar.wait()
    if dx.returncode != 0:
        print("  [WARN] tar 同步警告:", dx.stderr.decode("utf-8", "replace")[:300], flush=True)
        return False
    return True


def trigger_scan(cfg):
    if not cfg["emby_public"] or not cfg["emby_api_key"]:
        return False
    requests.post(
        cfg["emby_public"].rstrip("/") + "/Library/Refresh",
        headers={"X-Emby-Token": cfg["emby_api_key"]},
        timeout=30,
    )
    return True


def main():
    cfg = load_config()
    login(cfg)
    # OUT_ROOT 通常是挂载卷，不能直接删除目录本身（Resource busy），只清空其内容
    os.makedirs(OUT_ROOT, exist_ok=True)
    for entry in os.listdir(OUT_ROOT):
        p = os.path.join(OUT_ROOT, entry)
        if os.path.isdir(p) and not os.path.islink(p):
            import shutil
            shutil.rmtree(p)
        else:
            os.remove(p)
    total = 0
    for m in cfg["mappings"]:
        n = process(cfg, m, OUT_ROOT)
        total += n
        print(f"[OK] {m['alist_path']} -> {m['emby_path']} : {n} strm", flush=True)
    if sync_to_emby(cfg, OUT_ROOT):
        print(f"[SYNC] {total} strm -> {cfg['emby_container']}:/", flush=True)
    if cfg["auto_scan"]:
        try:
            if trigger_scan(cfg):
                print("[SCAN] Emby 媒体库刷新已触发", flush=True)
        except Exception as e:
            print(f"[SCAN] 跳过/失败: {e}", flush=True)
    print(f"[DONE] 共 {total} 个 strm", flush=True)


if __name__ == "__main__":
    main()
