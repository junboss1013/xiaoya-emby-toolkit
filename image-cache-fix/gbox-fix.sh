#!/bin/sh
# ============================================================
# 小雅 g-box(ATV) nginx 优化守护 —— 持久化版 v1.0.2
#
# 每 INTERVAL 秒巡检一次 g-box 容器，就地修复以下四项（全部幂等）：
#
#  1) config/constant-ext.js : imageCachePolicy = 1
#     nginx 图片缓存 key 带上查询参数，Emby 的 MaxWidth/Quality
#     才能生效（VidHub/Infuse/Yamby 首屏不再拉原始大图）。
#
#  2) /etc/nginx/nginx.conf : 开启 gzip（含 gzip_types/min_length/
#     comp_level/proxied）—— 详情页 JSON 体积约 -55%，外网加载更快。
#
#  3) /etc/nginx/nginx.conf : error_log 级别 warn -> error
#     njs 的 console.log 不再写进 error.log（曾涨到 2.3GB 拖慢磁盘）。
#
#  4) 日志超限时截断：access.log / error.log 超过 LOG_MAX_MB 就清空，
#     防止日志无限增长吃掉容器磁盘。
#
# 为什么需要守护：这些文件都在容器内部、未挂载到宿主机，小雅升级或
# 重建容器后会被镜像原值覆盖（gzip 默认注释掉、error_log 是 warn）。
# 本容器通过 docker.sock 周期检查并自动恢复，重建 g-box 后几十秒内
# 优化自动重新生效，无需人工干预。
#
# 安全设计：改写 nginx.conf 前先备份，改完执行 nginx -t；校验不通过
# 自动回滚备份，绝不把 nginx 改成起不来的状态（1.1.x 的教训）。
#
# 用法：
#   loop（默认）  常驻巡检
#   once          只执行一次（docker run --rm ... once）
#
# 环境变量：
#   TARGET_NAME          目标容器名，默认 g-box
#   TARGET_IMAGE_MATCH   容器改名时按镜像名兜底匹配，默认 ailg/g-box
#   ENABLE_GZIP          是否开启 gzip，默认 true
#   ENABLE_LOG_LEVEL     是否把 error_log 降到 error，默认 true
#   LOG_MAX_MB           日志截断阈值（MB），0 = 不截断，默认 200
#   INTERVAL             巡检间隔秒，默认 20
#   NGINX_CONF           主配置路径，默认 /etc/nginx/nginx.conf
# ============================================================
set -u

TARGET_NAME="${TARGET_NAME:-g-box}"
TARGET_IMAGE_MATCH="${TARGET_IMAGE_MATCH:-ailg/g-box}"
CONFIG_PATH="${CONFIG_PATH:-/etc/nginx/http.d/config/constant-ext.js}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/nginx.conf}"
ENABLE_GZIP="${ENABLE_GZIP:-true}"
ENABLE_LOG_LEVEL="${ENABLE_LOG_LEVEL:-true}"
LOG_MAX_MB="${LOG_MAX_MB:-200}"
INTERVAL="${INTERVAL:-20}"
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

# ---------- 在容器内执行幂等修复（脚本经 stdin 传入，避免转义问题） ----------
run_patch() {
  cid="$1"
  docker exec -i "$cid" sh -s -- \
    "$CONFIG_PATH" "$NGINX_CONF" "$ENABLE_GZIP" "$ENABLE_LOG_LEVEL" "$LOG_MAX_MB" <<'PATCH_EOF'
set -u
CFG="$1"; NGX="$2"; GZ="$3"; LL="$4"; LOGMB="$5"
NEED_RELOAD=0

# ---- 1) imageCachePolicy = 1 ----
if [ ! -f "$CFG" ]; then
  echo "WARN:policy-missing:$CFG"
elif [ ! -s "$CFG" ]; then
  # 镜像里的模板是 0 字节占位，运行时才生成真实内容，跳过不反复重试
  echo "WARN:policy-empty:$CFG"
else
  has=0; bad=0
  while IFS= read -r l; do
    case "$l" in
      *imageCachePolicy*=*0*) bad=1 ;;
      *imageCachePolicy*=*1*) has=1 ;;
    esac
  done < "$CFG"
  if [ "$bad" = "1" ]; then
    [ -f "$CFG.bak_gboxfix" ] || cp "$CFG" "$CFG.bak_gboxfix"
    sed -i 's/imageCachePolicy *= *0/imageCachePolicy = 1/' "$CFG"
  elif [ "$has" = "0" ] && grep -q '^export default' "$CFG"; then
    [ -f "$CFG.bak_gboxfix" ] || cp "$CFG" "$CFG.bak_gboxfix"
    sed -i '/^export default/i const imageCachePolicy = 1;' "$CFG"
  fi
  # 复核写入结果，避免空文件/结构变化时每轮都"改一遍再 reload"
  if grep -q 'imageCachePolicy *= *1' "$CFG"; then
    [ "$has" = "1" ] || { echo "CHANGED:policy"; NEED_RELOAD=1; }
  else
    echo "WARN:policy-patch-failed:$CFG"
  fi
fi

# ---- 2) gzip ----
if [ "$GZ" = "true" ] && [ -f "$NGX" ]; then
  if grep -q '^[[:space:]]*gzip[[:space:]][[:space:]]*on[[:space:]]*;' "$NGX"; then
    :
  elif grep -q '^[[:space:]]*#[[:space:]]*gzip[[:space:]][[:space:]]*on[[:space:]]*;' "$NGX"; then
    [ -f "$NGX.bak_gboxfix" ] || cp "$NGX" "$NGX.bak_gboxfix"
    sed -i 's|^\([[:space:]]*\)#[[:space:]]*gzip[[:space:]][[:space:]]*on[[:space:]]*;|\1gzip on;|' "$NGX"
    echo "CHANGED:gzip"; NEED_RELOAD=1
  fi

  if grep -q '^[[:space:]]*gzip[[:space:]][[:space:]]*on' "$NGX"; then
    ADD=""
    grep -q '^[[:space:]]*gzip_vary'        "$NGX" || ADD="${ADD}gzip_vary on;
"
    grep -q '^[[:space:]]*gzip_types'       "$NGX" || ADD="${ADD}gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/x-javascript;
"
    grep -q '^[[:space:]]*gzip_min_length'  "$NGX" || ADD="${ADD}gzip_min_length 1024;
"
    grep -q '^[[:space:]]*gzip_comp_level'  "$NGX" || ADD="${ADD}gzip_comp_level 4;
"
    grep -q '^[[:space:]]*gzip_proxied'     "$NGX" || ADD="${ADD}gzip_proxied any;
"
    if [ -n "$ADD" ]; then
      [ -f "$NGX.bak_gboxfix" ] || cp "$NGX" "$NGX.bak_gboxfix"
      printf '%s' "$ADD" | sed 's/^/    /' > /tmp/.gbox_gzadd
      awk -v addfile=/tmp/.gbox_gzadd '
        { print }
        !done && /^[[:space:]]*gzip[[:space:]][[:space:]]*on[[:space:]]*;/ {
          while ((getline line < addfile) > 0) print line
          close(addfile); done = 1
        }' "$NGX" > "$NGX.gboxnew" && cat "$NGX.gboxnew" > "$NGX"
      rm -f "$NGX.gboxnew" /tmp/.gbox_gzadd
      echo "CHANGED:gzip-params"; NEED_RELOAD=1
    fi
  fi
fi

# ---- 2b) proxy headers hash 扩容（emby.conf 头部很多，否则启动告警） ----
if [ -f "$NGX" ] && ! grep -q '^[[:space:]]*proxy_headers_hash_max_size' "$NGX"; then
  # 注意：容器里的 grep 可能是 ripgrep，不支持 [..]*{ 这种正则，用 awk 判断
  if awk '/^[[:space:]]*http[[:space:]]*\{/ { f = 1 } END { exit(f ? 0 : 1) }' "$NGX"; then
    [ -f "$NGX.bak_gboxfix" ] || cp "$NGX" "$NGX.bak_gboxfix"
    printf '%s\n' '    proxy_headers_hash_max_size 1024;' \
                  '    proxy_headers_hash_bucket_size 128;' > /tmp/.gbox_hashadd
    awk -v addfile=/tmp/.gbox_hashadd '
      { print }
      !done && /^http[[:space:]]*\{/ {
        while ((getline line < addfile) > 0) print line
        close(addfile); done = 1
      }' "$NGX" > "$NGX.gboxnew" && cat "$NGX.gboxnew" > "$NGX"
    rm -f "$NGX.gboxnew" /tmp/.gbox_hashadd
    echo "CHANGED:hashsize"; NEED_RELOAD=1
  fi
fi

# ---- 3) error_log 级别 ----
if [ "$LL" = "true" ] && [ -f "$NGX" ]; then
  ln=$(grep -n '^[[:space:]]*error_log' "$NGX" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$ln" ]; then
    cur=$(sed -n "${ln}p" "$NGX")
    case "$cur" in
      *" warn;"*|*" notice;"*|*" info;"*|*" debug;"*)
        [ -f "$NGX.bak_gboxfix" ] || cp "$NGX" "$NGX.bak_gboxfix"
        sed -i -E "${ln}s/[[:space:]]+(warn|notice|info|debug)([[:space:]]*;)[[:space:]]*$/ error\2/" "$NGX"
        echo "CHANGED:loglevel"; NEED_RELOAD=1
        ;;
    esac
  fi
fi

# ---- 4) 日志超限截断 ----
case "$LOGMB" in
  ''|*[!0-9]*) LOGMB=0 ;;
esac
if [ "$LOGMB" -gt 0 ]; then
  LIMIT=$((LOGMB * 1048576))
  for f in /var/log/nginx/access.log /var/log/nginx/error.log; do
    [ -f "$f" ] || continue
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -gt "$LIMIT" ]; then
      : > "$f"
      echo "CHANGED:logtrunc:$(basename "$f")=$sz"
    fi
  done
fi

# ---- 5) 校验 + reload，失败自动回滚 ----
if [ "$NEED_RELOAD" = "1" ]; then
  if nginx -t -c "$NGX" >/dev/null 2>&1; then
    nginx -s reload >/dev/null 2>&1 && echo "RELOADED" || echo "WARN:reload-failed"
  else
    [ -f "$NGX.bak_gboxfix" ] && cat "$NGX.bak_gboxfix" > "$NGX"
    [ -f "$CFG.bak_gboxfix" ] && cat "$CFG.bak_gboxfix" > "$CFG"
    echo "ROLLED_BACK"
  fi
fi
PATCH_EOF
}

# ---------- 单次巡检 ----------
LAST_STATE=""
tick() {
  cid=$(find_container) || {
    [ "$LAST_STATE" = "noct" ] || log "未找到目标容器（name=$TARGET_NAME / image~$TARGET_IMAGE_MATCH），继续等待"
    LAST_STATE=noct; return 0; }

  out=$(run_patch "$cid" 2>&1)
  rc=$?

  if echo "$out" | grep -q 'ROLLED_BACK'; then
    log "警告：写入后 nginx -t 未通过，已自动回滚到修改前状态，请人工检查 $cid"
    LAST_STATE=err; return 0
  fi
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
    [ "$LAST_STATE" = "err" ] || log "巡检失败（docker exec 返回 $rc）"
    LAST_STATE=err; return 0
  fi

  note=""
  if echo "$out" | grep -q 'WARN:policy-missing'; then
    note="（未找到 $CONFIG_PATH，仅做 nginx 优化）"
  elif echo "$out" | grep -q 'WARN:policy-empty\|WARN:policy-patch-failed'; then
    note="（$CONFIG_PATH 为空或结构变化，跳过 imageCachePolicy）"
  fi

  if echo "$out" | grep -q 'CHANGED:'; then
    items=$(echo "$out" | grep 'CHANGED:' | sed 's/^CHANGED://' | tr '\n' ',' | sed 's/,$//')
    if echo "$out" | grep -q 'RELOADED'; then
      log "已应用优化 [$items] 并 reload nginx（$cid）$note"
    else
      log "已应用优化 [$items]（$cid）$note"
    fi
    LAST_STATE="patched"
  else
    [ "$LAST_STATE" = "patched" ] || log "容器 $cid 已处于优化状态（imageCachePolicy=1 / gzip on / error_log error），无需操作 $note"
    LAST_STATE="patched"
  fi
  return 0
}

log "守护启动 v1.0.2：target=$TARGET_NAME image~$TARGET_IMAGE_MATCH gzip=$ENABLE_GZIP loglevel=$ENABLE_LOG_LEVEL logmax=${LOG_MAX_MB}MB interval=${INTERVAL}s mode=$MODE"

if [ "$MODE" = "once" ]; then
  tick
  exit 0
fi

while :; do
  tick
  sleep "$INTERVAL"
done
