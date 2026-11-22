#!/bin/sh
# 入口：交给 Python 守护脚本处理（python3 由 Dockerfile 安装）
# 兼容旧的环境变量：CONFIG_PATH 若被设置则忽略（新版固定处理两个文件）
exec python3 /usr/local/bin/gbox_fix.py "$@"
