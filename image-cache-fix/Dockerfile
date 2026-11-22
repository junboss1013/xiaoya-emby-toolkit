FROM docker:27-cli

LABEL org.opencontainers.image.title="gbox-image-cache-fix" \
      org.opencontainers.image.version="1.0.1" \
      org.opencontainers.image.description="Keep 小雅 g-box(ATV) nginx imageCachePolicy=1 so Emby image requests honor MaxWidth/Quality (fast VidHub/Infuse first load). Survives container rebuild." \
      org.opencontainers.image.source="https://github.com/junboss1013/xiaoya-emby-toolkit" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache tzdata

COPY entrypoint.sh /usr/local/bin/gbox-fix.sh
RUN chmod +x /usr/local/bin/gbox-fix.sh

ENV TARGET_NAME=g-box \
    TARGET_IMAGE_MATCH=ailg/g-box \
    CONFIG_PATH=/etc/nginx/http.d/config/constant-ext.js \
    INTERVAL=20 \
    TZ=Asia/Shanghai

ENTRYPOINT ["/usr/local/bin/gbox-fix.sh"]
CMD ["loop"]
