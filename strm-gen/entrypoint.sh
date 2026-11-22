#!/bin/sh
# 容器入口：
#   - 默认：生成一次后退出（适合手动 docker compose run 或外部 cron 调用）
#   - 设置 CRON（如 "0 3 * * *"）：常驻并由容器内 crond 定时执行
set -e

LOG=/out/run.log
mkdir -p /out

RUN_CMD="cd /app && /usr/local/bin/python /app/gen_strm.py >> $LOG 2>&1"

if [ -n "$CRON" ]; then
    echo "[$CRON] $RUN_CMD" > /etc/crontabs/root
    echo "[entrypoint] cron 模式：$CRON（日志 $LOG）"
    exec crond -f -l 2
else
    echo "[entrypoint] 单次运行模式"
    exec /usr/local/bin/python /app/gen_strm.py
fi
