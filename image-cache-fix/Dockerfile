FROM docker:27-cli

LABEL org.opencontainers.image.title="gbox-image-cache-fix" \
      org.opencontainers.image.version="1.1.1" \
      org.opencontainers.image.description="Keep 小雅 g-box(ATV) nginx optimizations across rebuilds: imageCachePolicy=1 so MaxWidth/Quality are honored, plus a universal maxWidth cap (default 800px) for faster Emby detail pages in yamby/VidHub/Infuse." \
      org.opencontainers.image.source="https://github.com/junboss1013/xiaoya-emby-toolkit" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache tzdata python3

COPY gbox_fix.py /usr/local/bin/gbox_fix.py
COPY entrypoint.sh /usr/local/bin/gbox-fix.sh
RUN chmod +x /usr/local/bin/gbox_fix.py /usr/local/bin/gbox-fix.sh

ENV TARGET_NAME=g-box \
    TARGET_IMAGE_MATCH=ailg/g-box \
    MAX_WIDTH=800 \
    ENABLE_IMAGE_CAP=true \
    INTERVAL=20 \
    TZ=Asia/Shanghai

ENTRYPOINT ["/usr/local/bin/gbox-fix.sh"]
CMD ["loop"]
