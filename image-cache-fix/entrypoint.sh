#!/bin/sh
# ============================================================
# 小雅 g-box(ATV) 图片缓存修正守护进程
#
# 作用：确保 g-box 容器内 /etc/nginx/http.d/config/constant-ext.js
#       里的 imageCachePolicy 恒为 1（nginx 缓存 key 带上查询参数）。
#
# 为什么需要它：该文件位于容器内部、未挂载到宿主机，小雅升级重建容器
# 后会被镜像原值(0)覆盖，导致 Emby 图片接口的 MaxWidth/Quality 等参数
# 被缓存 key 忽略 —— VidHub/Infuse 首屏拿到的是原始大图，加载变慢。
#
# 本容器通过挂载的 docker.sock 周期性检查并就地修正，g-box 重建后
# 几十秒内自动重新生效，无需人工干预。
#
# 用法：
#   loop（默认）  常驻巡检
#   once          只检查一次（配合 docker run --rm 使用）
# ============================================================
set -u

TARGET_NAME="${TARGET_NAME:-g-box}"                     # 优先按容器名匹配
TARGET_IMAGE_MATCH="${TARGET_IMAGE_MATCH:-ailg/g-box}"  # 名字找不到时按镜像名匹配（小雅换容器名也能命中）
CONFIG_PATH="${CONFIG_PATH:-/etc/nginx/http.d/config/constant-ext.js}"
INTERVAL="${INTERVAL:-20}"                              # 巡检间隔（秒）
MODE="${1:-${MODE:-loop}}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------- 找到目标容器 ----------
find_container() {
  if docker inspect "$TARGET_NAME" >/dev/null 2>&1; then
    echo "$TARGET_NAME"; return 0
  fi
  for id in $(docker ps -q 2>/dev/null); do
    img=$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true)
    case "$img" in
      *"$TARGET_IMAGE_MATCH"*) echo "$id"; return 0 ;;
    esac
  done
  return 1
}

# ---------- 纯 POSIX 方式判断状态（不依赖容器内 grep 的 -E 支持） ----------
# 输出：patched / unpatched / missing
container_state() {
  cid="$1"
  if ! docker exec "$cid" test -f "$CONFIG_PATH" >/dev/null 2>&1; then
    echo missing; return
  fi
  docker exec "$cid" sh -c '
    while IFS= read -r line; do
      case "$line" in
        *imageCachePolicy*=*1*) exit 0 ;;
      esac
    done < "$1"
    exit 1
  ' gbox-fix-check "$CONFIG_PATH" >/dev/null 2>&1 && echo patched || echo unpatched
}

# ---------- 就地修复 + nginx reload（不重启容器） ----------
apply_patch() {
  cid="$1"
  docker exec "$cid" sh -c '
    f="$1"
    [ -f "$f" ] || { echo MISSING_FILE; exit 3; }
    [ -f "$f.bak_imagecachepolicy" ] || cp -n "$f" "$f.bak_imagecachepolicy" 2>/dev/null || true
    has=0; bad=0
    while IFS= read -r line; do
      case "$line" in
        *imageCachePolicy*=*0*) bad=1 ;;
        *imageCachePolicy*=*1*) has=1 ;;
      esac
    done < "$f"
    if [ "$bad" = "1" ]; then
      sed -i "s/imageCachePolicy *= *0/imageCachePolicy = 1/" "$f"
    elif [ "$has" = "0" ]; then
      sed -i "/^export default/i const imageCachePolicy = 1;" "$f"
    fi
    if nginx -t >/dev/null 2>&1; then
      nginx -s reload >/dev/null 2>&1 || true
      echo PATCHED
    else
      echo NGINX_CONF_INVALID
      exit 4
    fi
  ' gbox-fix-patch "$CONFIG_PATH" 2>&1
}

# ---------- 单次巡检 ----------
LAST_STATE=""
tick() {
  cid=$(find_container) || {
    [ "$LAST_STATE" = "noct" ] || log "未找到目标容器（name=$TARGET_NAME / image~$TARGET_IMAGE_MATCH），继续等待"
    LAST_STATE=noct; return 0; }

  state=$(container_state "$cid")
  case "$state" in
    patched)
      [ "$LAST_STATE" = "patched" ] || log "容器 $cid 已处于修正状态（imageCachePolicy=1），无需操作"
      LAST_STATE=patched ;;
    unpatched)
      out=$(apply_patch "$cid")
      case "$out" in
        *PATCHED*) log "已修正 $cid 的 imageCachePolicy -> 1 并 reload nginx"; LAST_STATE=patched ;;
        *NGINX_CONF_INVALID*) log "写入完成但 nginx -t 未通过，已保留备份，请人工检查 $cid"; LAST_STATE=err ;;
        *) log "修正失败：$(echo "$out" | tr '\n' ' ')"; LAST_STATE=err ;;
      esac ;;
    missing)
      [ "$LAST_STATE" = "missing" ] || log "容器 $cid 内未找到 $CONFIG_PATH（小雅版本可能改了路径，可用 CONFIG_PATH 指定）"
      LAST_STATE=missing ;;
  esac
  return 0
}

log "守护启动：target=$TARGET_NAME image~$TARGET_IMAGE_MATCH config=$CONFIG_PATH interval=${INTERVAL}s mode=$MODE"

if [ "$MODE" = "once" ]; then
  tick
  exit 0
fi

while :; do
  tick
  sleep "$INTERVAL"
done
