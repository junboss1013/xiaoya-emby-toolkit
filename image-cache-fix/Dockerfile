FROM docker:27-cli

LABEL org.opencontainers.image.title="gbox-image-cache-fix" \
      org.opencontainers.image.version="1.0.2" \
      org.opencontainers.image.description="Keep 小雅 g-box(ATV) nginx optimizations across rebuilds: imageCachePolicy=1 (so MaxWidth/Quality are honored), gzip on for JSON/JS/CSS, error_log level=error (no more multi-GB logs), and automatic log truncation. No image re-encoding / no maxWidth rewriting." \
      org.opencontainers.image.source="https://github.com/junboss1013/xiaoya-emby-toolkit" \
      org.opencontainers.image.licenses="MIT"

# tzdata: 让守护日志时间戳为 Asia/Shanghai
RUN apk add --no-cache tzdata

COPY gbox-fix.sh /usr/local/bin/gbox-fix.sh
RUN chmod +x /usr/local/bin/gbox-fix.sh

ENV TARGET_NAME=g-box \
    TARGET_IMAGE_MATCH=ailg/g-box \
    ENABLE_GZIP=true \
    ENABLE_LOG_LEVEL=true \
    LOG_MAX_MB=200 \
    INTERVAL=20 \
    TZ=Asia/Shanghai

ENTRYPOINT ["/usr/local/bin/gbox-fix.sh"]
CMD ["loop"]
