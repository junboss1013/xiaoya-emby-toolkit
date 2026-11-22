#!/usr/bin/env python3
# ============================================================
# 小雅 g-box(ATV) nginx 优化守护进程
#
# 周期性检查并就地修正 g-box 容器内的两个文件，不重启容器、
# 只 reload nginx，因此不中断正在播放的会话：
#
#  1) config/constant-ext.js : imageCachePolicy = 1
#     让图片缓存 key 带上查询参数，MaxWidth/Quality 才能生效
#     （修好 VidHub/Infuse 首屏拿到原始大图的问题）
#
#  2) constant.js : getImageCachePolicy 里通用地把 maxWidth 上限
#     压到 MAX_WIDTH（默认 800），对所有客户端生效、不认 UA。
#     小于上限的图片、以及不带 maxWidth 的原图都不受影响。
#
# 这些文件位于容器内部、未挂载到宿主机，小雅升级重建容器后会被
# 镜像原值覆盖。本容器通过挂载的 docker.sock 周期检查并自动恢复。
# ============================================================
import base64
import os
import re
import subprocess
import sys
import time

CJS = "/etc/nginx/http.d/constant.js"
CEXT = "/etc/nginx/http.d/config/constant-ext.js"
TARGET_NAME = os.environ.get("TARGET_NAME", "g-box")
TARGET_IMAGE_MATCH = os.environ.get("TARGET_IMAGE_MATCH", "ailg/g-box")
INTERVAL = int(os.environ.get("INTERVAL", "20"))
MAX_WIDTH = int(os.environ.get("MAX_WIDTH", "800"))
ENABLE_CAP = os.environ.get("ENABLE_IMAGE_CAP", "true").lower() in ("1", "true", "yes", "on")
MODE = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("MODE", "loop")

OLD_FN = """function getImageCachePolicy(r) {
  return extConfig.imageCachePolicy;
}"""

NEW_FN = """function getImageCachePolicy(r) {
  try {
    var u = r.uri || "";
    if (u.indexOf("/Images") >= 0) {
      var a = "" + (r.variables.args || "");
      var m = /(maxWidth=)(\\d+)/i.exec(a);
      if (m && parseInt(m[2], 10) > %d) {
        r.variables.args = a.replace(m[0], m[1] + "%d");
      }
    }
  } catch (e) {}
  return extConfig.imageCachePolicy;
}""" % (MAX_WIDTH, MAX_WIDTH)

LAST_NOCT = False


def log(msg):
    print("[%s] %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def dexec(cid, *args, **kwargs):
    stdin = kwargs.get("input")
    return run(["docker", "exec"] + (["-i"] if stdin is not None else []) + [cid] + list(args))


def find_container():
    if run(["docker", "inspect", TARGET_NAME]).returncode == 0:
        return TARGET_NAME
    p = run(["docker", "ps", "-q"])
    for cid in p.stdout.split():
        img = run(["docker", "inspect", "-f", "{{.Config.Image}}", cid]).stdout.strip()
        if TARGET_IMAGE_MATCH in img:
            return cid
    return None


def read_file(cid, path):
    p = dexec(cid, "cat", path)
    return p.stdout if p.returncode == 0 else None


def write_file(cid, path, content):
    # 用 base64 传输，避免 stdin/换行在不同 docker exec 环境下被改写或截断
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    return dexec(cid, "sh", "-c", "echo %s | base64 -d > %s" % (b64, path))


def backup_once(cid, path):
    bak = path + ".bak_gboxfix"
    dexec(cid, "sh", "-c", "[ -f %s ] || cp %s %s" % (bak, path, bak))


def tick():
    global LAST_NOCT
    cid = find_container()
    if not cid:
        if not LAST_NOCT:
            log("未找到目标容器（name=%s / image~%s），继续等待" % (TARGET_NAME, TARGET_IMAGE_MATCH))
        LAST_NOCT = True
        return
    LAST_NOCT = False
    changed = False

    # ---- 1) imageCachePolicy = 1 ----
    cext = read_file(cid, CEXT)
    if cext is None:
        log("缺少 %s（小雅版本可能改了路径）" % CEXT)
    elif re.search(r"imageCachePolicy\s*=\s*1", cext):
        pass
    else:
        backup_once(cid, CEXT)
        if re.search(r"imageCachePolicy\s*=\s*0", cext):
            new = re.sub(r"imageCachePolicy\s*=\s*0", "imageCachePolicy = 1", cext, count=1)
        else:
            new = re.sub(r"(?m)^export default", "const imageCachePolicy = 1;\n\nexport default", cext, count=1)
        write_file(cid, CEXT, new)
        changed = True
        log("已修正 %s 的 imageCachePolicy -> 1" % cid)

    # ---- 2) constant.js 里的通用 maxWidth 压缩 ----
    if ENABLE_CAP:
        cjs = read_file(cid, CJS)
        if cjs is None:
            log("缺少 %s（跳过 maxWidth 压缩）" % CJS)
        elif "r.variables.args" in cjs and "maxWidth" in cjs:
            pass  # 已patched
        elif OLD_FN in cjs:
            backup_once(cid, CJS)
            write_file(cid, CJS, cjs.replace(OLD_FN, NEW_FN))
            changed = True
            log("已注入 maxWidth>%d -> %d 通用压缩" % (MAX_WIDTH, MAX_WIDTH))
        else:
            log("警告: %s 结构变化，未找到注入锚点，跳过压缩" % CJS)

    if changed:
        if dexec(cid, "nginx", "-t").returncode == 0:
            dexec(cid, "nginx", "-s", "reload")
            log("nginx 校验通过并已 reload")
        else:
            log("nginx -t 未通过，已保留备份，请人工检查")


log("守护启动: target=%s image~%s policy=%s cap=%s(%d) interval=%ss mode=%s" %
    (TARGET_NAME, TARGET_IMAGE_MATCH, CEXT, ENABLE_CAP, MAX_WIDTH, INTERVAL, MODE))

if MODE == "once":
    tick()
    sys.exit(0)

while True:
    tick()
    time.sleep(INTERVAL)
