# xiaoya-emby-toolkit

小雅 Alist（g-box / ATV）全家桶 + Emby 的**外网访问与首屏加速**配套工具，两个可独立部署的容器。
所有修复都做成**外部容器**，不修改小雅镜像本身，因此**小雅升级、容器重建后依然自动生效**。

| 组件 | 镜像 | 解决的问题 |
| --- | --- | --- |
| `image-cache-fix` | `bossjun/gbox-image-cache-fix:1.0.3` | ① Emby 缩略图缓存 key 忽略 `MaxWidth/Quality` 导致首屏慢；② 详情页 JSON 未压缩、外网加载慢；③ nginx 日志写爆（曾 2.3GB）拖慢磁盘；④ 图片缓存 key 被 api_key 放大；⑤ 图片缺 `max-age` 导致客户端每次重下 |
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

`image-cache-fix` 的做法：挂载 `docker.sock`，每 20 秒巡检一次目标容器的这些文件，
发现被还原就就地改回，`nginx -t` 通过后 `nginx -s reload`（不重启容器、不断流）。
小雅重建后几十秒内自动恢复，日志里能看到 `已应用优化 [policy,gzip,...] 并 reload nginx`。

## 一·2、详情页/列表 JSON 太慢：开 gzip（1.0.2 新增）

小雅 g-box 的 `nginx.conf` 里 `gzip` 默认是**注释掉**的：

```nginx
# Enable gzipping of responses.
#gzip on;
```

详情页、列表接口返回的都是 JSON（详情页单个 Items 响应 5.4 KB），公网上要几十次往返，
不压缩等于白白多传一倍多的字节。

1.0.2 起守护容器会把这段改成：

```nginx
gzip on;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript application/x-javascript;
gzip_min_length 1024;
gzip_comp_level 4;
gzip_proxied any;
gzip_vary on;
```

实测（`/emby/Users/<uid>/Items/<id>?Fields=...`，经公网域名）：

| 场景 | 体积 | 说明 |
| --- | --- | --- |
| 未开 gzip | 5437 B | 基线 |
| 开 gzip 后 | 2440 B | **-55%**，`content-encoding: gzip` |

`gzip_types` 只含文本类，视频/图片流不受影响；`gzip_proxied any` 是必须的，否则 nginx 不会压缩
反向代理回来的 Emby 响应。

## 一·3、日志写爆磁盘（1.0.2 新增）

- `nginx.conf` 的 `error_log ... warn;` 会把 njs 脚本里的 `console.log` 全部落盘，
  实测 `error.log` 长到 **2.3 GB** 且以 ~130 KB/s 继续增长，直接拖慢磁盘 IO。
  1.0.2 把它调到 `error` 级别，正常运行的 `[notice]/[warn]` 不再落盘。
- `access.log` 同样无上限（实测 6 天 1 GB）。守护容器每小时级别检查一次，
  超过 `LOG_MAX_MB`（默认 200 MB）就截断，nginx 以 `O_APPEND` 写日志，截断后继续正常写入。

> 提醒：`constant.js` 里"把 maxWidth 统一压到 800"的做法（1.1.x）**已废弃**，见下节。

## 一·4、为什么不做 maxWidth 通用压缩（1.1.x 废弃说明）

1.1.0 / 1.1.1 曾在 `constant.js` 的 `getImageCachePolicy(r)` 里改写 `r.variables.args`，
把所有图片请求的 `maxWidth` 压到 800。这在部分客户端上会让转发给上游 Emby 的 query
被破坏（签名/参数不一致），Yamby / VidHub 带 `maxWidth` 的图片请求直接 **HTTP 500**，
表现为详情页剧集卡片黑图、图片加载失败。

而且 `ENABLE_IMAGE_CAP=false` 只让守护"不再注入"，**不会撤销**已经注入的代码，回退很麻烦。

结论：**不要改写请求参数**。要图片变小，应在客户端请求时带 `MaxWidth`（配合
`imageCachePolicy=1` 让不同尺寸各自缓存），而不是在 nginx 里偷偷改参数。
`latest` 与 `1.0.3` 均为不含压缩的版本；`1.1.x` 仅作历史保留，不建议使用。

## 一·5、图片缓存 key 与客户端缓存头（1.0.3 新增）

### 1）缓存 key 去掉 `api_key`

`imageCachePolicy = 1` 时，图片的 `proxy_cache_key` 直接取 `$request_uri`，等于把
`api_key` / 登录 token 也算进了缓存 key：

```
/emby/Items/123/Images/Primary?maxWidth=400&quality=90&api_key=<token>
```

同一个用户重新登录、换客户端（token 变了）后，他看过的图会在缓存里**再存一份**，
等于把自己的缓存热度清零。1.0.3 在 `emby.conf` 里加了一个 `map`，把 `api_key`
从 key 里剥掉（尺寸、画质、`tag` 仍然各自独立）：

```nginx
map $args $img_cache_args {
    default                                        $args;
    "~^(?<ck_a>.*?)(&?)api_key=[^&]*$"             $ck_a;
    "~^api_key=[^&]*&(?<ck_b>.*)$"                 $ck_b;
    "~^(?<ck_c>.*?)(&?)api_key=[^&]*(?<ck_d>&.*)$" "$ck_c$ck_d";
}
...
set $tmp_proxy_cache_key "$uri?$img_cache_args";
```

安全性：Emby 的图片接口本身**不校验** `api_key`（实测 `?api_key=deadbeef` 也返回 200），
剥掉它只影响缓存 key，不影响鉴权与内容；上游请求仍然带着原始 `api_key`。

实测四种入参（固定 key / 登录 token / 不带 key / key 在开头）现在共用同一条缓存，
而 `maxWidth=300/400/1080` 仍是三条独立缓存（分别 33 KB / 48 KB / 226 KB，不会串图）。

### 2）图片加客户端缓存头

Emby 原样返回的是 `Cache-Control: public`（**没有 max-age**），客户端无法判断能缓存多久，
每次打开同一个详情页都要把海报重下一遍。1.0.3 改为：

```nginx
proxy_hide_header Cache-Control;
add_header Cache-Control "public, max-age=604800";   # 7 天，IMG_MAX_AGE 可调
proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
proxy_cache_background_update on;
```

`IMAGE_TAG` 变化时客户端 URL 会带新的 `tag=`，所以改图能立刻看到；对不带 `tag` 的请求
最多 7 天旧图，嫌长就把 `IMG_MAX_AGE` 调小（如 `86400`）。

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
[2026-11-23 11:34:14] 守护启动 v1.0.3：target=g-box image~ailg/g-box gzip=true loglevel=true logmax=200MB imgcache=true max-age=604800s interval=20s mode=loop
（小雅重建后）已应用优化 [policy,gzip,gzip-params,hashsize,loglevel,img-map,img-key,img-cachehdr] 并 reload nginx（g-box）
（日志超限时）已应用优化 [logtrunc:access.log=1073805189]（g-box）
（稳定后）容器 g-box 已处于优化状态（policy=1 / gzip on / error_log error / img-cache key+max-age），无需操作
```

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `TARGET_NAME` | `g-box` | 小雅主容器名 |
| `TARGET_IMAGE_MATCH` | `ailg/g-box` | 容器名被改时的兜底匹配（按镜像名模糊匹配） |
| `ENABLE_GZIP` | `true` | 是否开启 gzip |
| `ENABLE_LOG_LEVEL` | `true` | 是否把 `error_log` 级别降到 `error` |
| `ENABLE_IMG_CACHE` | `true` | 是否改图片缓存 key（去 api_key）、加客户端缓存头与 stale |
| `IMG_MAX_AGE` | `604800` | 图片客户端缓存秒数（7 天），`0` = 不改缓存头 |
| `EMBY_CONF` | `/etc/nginx/http.d/emby.conf` | emby 站点配置路径（小雅改版时用）
| `LOG_MAX_MB` | `200` | `access.log`/`error.log` 超过该体积自动截断，`0` = 不截断 |
| `INTERVAL` | `20` | 巡检间隔（秒） |
| `CONFIG_PATH` | `/etc/nginx/http.d/config/constant-ext.js` | 缓存策略文件路径（小雅改版时用） |
| `NGINX_CONF` | `/etc/nginx/nginx.conf` | nginx 主配置路径 |

一次性修复（不想常驻）：

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  bossjun/gbox-image-cache-fix:1.0.3 once
```

安全设计：改写 `nginx.conf` / `emby.conf` 前先备份（`.bak_gboxfix`），改完执行 `nginx -t`；
校验不通过**自动回滚全部文件**并打日志，绝不会把 nginx 改成起不来的状态。

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
cd image-cache-fix
docker build -t bossjun/gbox-image-cache-fix:1.0.3 -t bossjun/gbox-image-cache-fix:latest .
docker push bossjun/gbox-image-cache-fix:1.0.3
docker push bossjun/gbox-image-cache-fix:latest

# strm-gen
cd ../strm-gen && docker build -t bossjun/strm-gen:latest .
docker push bossjun/strm-gen:latest
```

## 四、注意

- `image-cache-fix` 需要读写 `docker.sock`，等于宿主机 root 权限，请只在自有设备上部署。
- 若小雅后续版本改了文件路径/开关名，容器会在日志里提示，按新版文件结构调整即可。
- 修改前会自动备份：`constant-ext.js.bak_gboxfix`、`nginx.conf.bak_gboxfix`、`emby.conf.bak_gboxfix`（容器内）。
- gzip 只压缩文本类响应，视频 302 直链与图片均不走压缩，不影响播放与画质。

## License

MIT
