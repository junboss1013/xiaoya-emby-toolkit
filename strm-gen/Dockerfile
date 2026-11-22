FROM python:3.11-alpine

LABEL org.opencontainers.image.title="strm-gen" \
      org.opencontainers.image.description="Generate .strm files from Alist directories and sync them into the Emby container, so playback goes straight to the public URL instead of being relayed by the server." \
      org.opencontainers.image.source="https://github.com/junboss1013/xiaoya-emby-toolkit" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache tzdata ca-certificates \
 && pip install --no-cache-dir requests \
 && rm -rf /root/.cache

WORKDIR /app
COPY gen_strm.py entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

ENV OUT_ROOT=/out \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

VOLUME ["/out"]
ENTRYPOINT ["/app/entrypoint.sh"]
