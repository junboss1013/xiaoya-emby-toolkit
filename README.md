# xiaoya-emby-toolkit

小雅 Alist（g-box / ATV）全家桶 + Emby 的**外网访问与首屏加速**配套工具，两个可独立部署的容器。
所有修复都做成**外部容器**，不修改小雅镜像本身，因此**小雅升级、容器重建后依然自动生效**。

| 组件 | 镜像 | 解决的问题 |
| --- | --- | --- |
| `image-cache-fix` | `bossjun/gbox-image-cache-fix` | Emby 缩略图接口忽略 `MaxWidth/Quality`，VidHub/Infuse 首屏加载慢 |
| `strm-gen` | `bossjun/strm-gen` | STRM 指向仅容器内可解析的地址，外网起播靠服务端中转，慢且耗上行 |

---

## 一、问题根因（image-cache-fix）

小雅 g-box（ATV）用 nginx 的 `js_import` 加载 `constant-ext.js`，其中一个开关：

```js
// /etc/nginx/http.d/config/constant-ext.js
const imageCachePolicy = 0;   // 默认
```

`imageCachePolicy = 0` 时，图片请求的 `proxy_cache_key` 只用 `$uri`，**不含查询参数**。
于是 Emby 的

```
/Items/123/Images/Primary?MaxWidth=200&Quality=90
```

与

```
/Items/123/Images/Primary?MaxWidth=1920
```

命中**同一个缓存条目**。谁先被请求，后续所有人就拿它——VidHub 一次滑屏几十张海报，
命中的是原始大图，首屏自然慢（实测单图 579 KB → 52 KB，`MaxWidth=300&Quality=50` 时 19 KB）。

改成 `1` 后缓存 key 带上参数，不同尺寸各自独立缓存。实测（同一张海报）：

| 请求 | 体积 |
| --- | --- |
| `?MaxWidth=200&Quality=90` | 22.8 KB |
| `?MaxWidth=1920&Quality=90` | 208 KB |
| 不带参数（原图） | 208 KB |

修复前三个请求命中同一条缓存，VidHub 一次滑屏几十张海报全部走 208 KB 的原图。

验证：

```bash
# HIT 且长度接近小图 → 正常
curl -sI "https://<emby域名>/Items/<Id>/Images/Primary?MaxWidth=200" | grep -iE "x-cache-status|content-length"
```

### 为什么不能只改一次

`/etc/nginx/http.d/config/` 在小雅镜像内部，**没有挂载到宿主机**。小雅升级重建容器（`docker compose pull && up -d`）
会回到 `0`，之前的优化全部失效。

`image-cache-fix` 的做法：挂载 `docker.sock`，每 20 秒巡检一次目标容器的这个文件，
发现不是 `1` 就就地改回 `1`，`nginx -t` 通过后 `nginx -s reload`（不重启容器、不断流）。
小雅重建后几十秒内自动恢复，日志里能看到 `已修正 ... imageCachePolicy -> 1`。

---

## 二、部署

### 1）image-cache-fix

```bash
mkdir -p /vol1/1000/docker/gbox-fix && cd /vol1/1000/docker/gbox-fix
# 把本仓库 image-cache-fix/docker-compose.yml 放进来
docker compose up -d
docker logs -f gbox-image-cache-fix
```

期望日志：

```
[2026-11-22 08:30:00] 守护启动：target=g-box image~ailg/g-box interval=20s mode=loop
[2026-11-22 08:30:00] 已修正 g-box 的 imageCachePolicy -> 1 并 reload nginx（小雅重建后自动恢复生效）
```

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `TARGET_NAME` | `g-box` | 小雅主容器名 |
| `TARGET_IMAGE_MATCH` | `ailg/g-box` | 容器名被改时的兜底匹配（按镜像名模糊匹配） |
| `CONFIG_PATH` | `/etc/nginx/http.d/config/constant-ext.js` | 目标文件 |
| `INTERVAL` | `20` | 巡检间隔（秒） |

一次性修复（不想常驻）：

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock --network none \
  bossjun/gbox-image-cache-fix:latest once
```

### 2）strm-gen

```bash
mkdir -p /vol1/1000/docker/strm-gen && cd /vol1/1000/docker/strm-gen
# 放本仓库 strm-gen/docker-compose.yml，改好账号与域名
docker compose up -d
docker logs -f strm-gen        # 运行明细见 ./strmgen-out/run.log
```

它走 Alist API 遍历目录 → 生成 `.strm`（内容为 `PUBLIC_PREFIX + /d + 路径`）→
用 `docker exec ... tar` 灌进 Emby 容器 → 可选触发 `Library/Refresh`。

---

## 三、构建与发布

```bash
# image-cache-fix
cd image-cache-fix && docker build -t bossjun/gbox-image-cache-fix:1.0.0 -t bossjun/gbox-image-cache-fix:latest .
docker push bossjun/gbox-image-cache-fix:1.0.0 && docker push bossjun/gbox-image-cache-fix:latest

# strm-gen
cd ../strm-gen && docker build -t bossjun/strm-gen:latest .
docker push bossjun/strm-gen:latest
```

## 四、注意

- `image-cache-fix` 需要读写 `docker.sock`，等于宿主机 root 权限，请只在自有设备上部署。
- 若小雅后续版本把该文件路径或开关名改掉，容器会在日志里提示 `未找到 ...`，此时改 `CONFIG_PATH` 即可。
- 修改前会自动备份为 `constant-ext.js.bak_imagecachepolicy`（容器内）。

## License

MIT
