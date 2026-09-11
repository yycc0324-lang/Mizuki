# 服务器部署总纲（供 AI 执行）

> **读者**：服务器侧 AI / 运维。**目标**：把本仓库部署成可访问的博客站点，并按需自建音乐接口。
> **用法**：先读「零」，按「二」的决策表选路径，然后严格按对应章节的**命令 + 验收标准**执行。
> 本文件是唯一入口，其余文档（`DEPLOYMENT_BAOTA.md` / `DEPLOYMENT_METING.md`）是它的展开与附录。

---

## 零、开始前必须知道的事实

### 0.1 项目性质
| 项 | 值 |
|---|---|
| 类型 | **纯静态站点**（`astro.config.mjs` → `output: "static"`，**无 SSR 适配器**） |
| 产物 | `dist/`（当前约 **26 MB / 329 个文件**，含 `pagefind` 搜索索引 640 KB） |
| 运行时 | **不需要 Node 常驻进程、不需要 PM2、不需要「启动项」**，Nginx 直接托管 `dist/` 即可 |
| 页面数 | 22 页（构建输出 `22 page(s) built`） |
| 包管理器 | **只能用 pnpm**（`package.json` 的 `preinstall` 是 `npx only-allow pnpm`，用 npm/yarn 会直接失败） |
| Node | **≥ 22** |

### 0.2 资源画像（实测，Apple Silicon + Node 24；Linux 同量级）
| 步骤 | 耗时 | 峰值内存 |
|---|---|---|
| `astro build` | 8.9 s | **~2.0 GB**（加 `--max-old-space-size=1024` 也能成功，7.5 s） |
| `pagefind --site dist` | 1.1 s | 350 MB |
| 字体子集化 | <1 s | 80 MB |
| 完整 `pnpm build` | 9.9 s | 1.5–2 GB |
| 磁盘（仓库） | `node_modules` 631 MB + `.git` 192 MB + `dist` 26 MB；pnpm store 另需 ~1 GB |

**结论**：**4 核 4 G 完全可跑**。
- 只做静态托管：nginx 常驻 10–30 MB，几乎不吃 CPU；
- 如需在服务器上构建：留出 2 GB 余量，建议加 2 GB swap，并设 `MEM_LIMIT=1536`（见 3.3）；
- 若同机再跑 Docker 音乐接口：再加 50–80 MB（见 4.8）。

### 0.3 三条「绝对不要做」
1. ❌ **不要**给这个项目配 Node 项目 / PM2 / `npm start`（那是 SSR 应用的东西）；
2. ❌ **不要**用 `npm install` / `yarn install` 装依赖；
3. ❌ **不要**把 `.image-backup/`（原图备份 16 MB）、`reports/`（测量结果）、`.git/` 同步到网站目录或打进 `dist`。

### 0.4 目录与脚本地图
| 路径 | 说明 |
|---|---|
| `dist/` | 构建产物（**部署的就是它**） |
| `scripts/deploy-baota.sh` | 静态站一键：拉依赖 → 构建（失败回退）→ 校验 → `rsync` 到网站目录 |
| `scripts/deploy-meting.sh` | 音乐接口一键：拉源码 → 改写 `index.php` → 构建镜像 → 启动 → 自测 |
| `scripts/update-meting-cookie.sh` | 更新 QQ/网易云登录 Cookie（交互式） |
| `docs/nginx/baota.conf` | 静态站 Nginx 片段（缓存 / try_files / gzip / 安全头） |
| `docs/meting/{Dockerfile,docker-compose.yml,nginx-meting.conf,qq-cookie.txt.example}` | Docker 音乐接口全套文件 |
| `scripts/optimize-images.mjs` | **本地**图片重压工具（服务器不用跑；`--dry-run` 预览） |
| `scripts/measure-first-load.py` | **本地**首屏测量工具（需 Python+Playwright+Chrome；服务器不用跑） |

---

## 一、部署架构总览

```
                       ┌──────────────────────────── 你的服务器（4C4G 即可） ───────────────────────────┐
浏览器 ──HTTPS──► ① 宝塔 Nginx（:443）
                       │   root = /www/wwwroot/mizuki-web   ← 静态站（dist 同步过来）
                       │   try_files $uri $uri/ $uri/index.html =404
                       ├── /_astro/*      → immutable 1y（带 hash，可长缓存）
                       ├── /pagefind/*    → 7d（搜索索引）
                       ├── /assets/ /images/ → 30d（图片）
                       │
                       └─ ② 独立站点 meting.你的域名（:443）→ proxy_pass 127.0.0.1:8899
                                                        │
                                            ③ Docker 容器 meting（PHP 8.2 + Apache）
                                               volume: ./meting-api/cache、./qq-cookie.txt(ro)
                                               → 由容器内 PHP 去请求音乐平台
浏览器 ──fetch──► ② /?server=…&type=playlist…  → 小 JSON（走你的机器，流量极小）
浏览器 ──<audio>─► ② ?type=url… → **302 跳转音乐平台 CDN**（音频流量不经过你的服务器）
```

要点：
- 静态站与音乐接口**完全隔离**（不同站点、不同进程），互不影响；
- 音乐接口**必须是 HTTPS**（博客是 https，http 接口会被浏览器按混合内容拦截）；
- 接口自带 `Access-Control-Allow-Origin: *`（无需在 Nginx 里重复加）。

---

## 二、路径选择决策表

| 你的情况 | 选择 | 章节 |
|---|---|---|
| 服务器有 Node ≥22 且内存 ≥4G（有 2G 余量） | 服务器上构建 + 发布 | 3.1 → 3.3 → 3.4 → 3.5 → 3.7 |
| 服务器内存小 / 不想装 Node | **本地构建后上传 `dist`** | 3.6 → 3.4 → 3.5 → 3.7 |
| 需要 QQ 音乐 VIP / 稳定歌单接口，且服务器愿装 Docker | 自建 Meting（Docker 反代） | 四（含全部文件内容） |
| 只要站点能跑，暂时不搞音乐接口 | 跳过四，或在 `src/config/musicConfig.ts` 里 `enable: false` | 三 + 五 |
| 不想装 Docker，但想自建接口 | 宝塔 PHP 站点方案 | `docs/DEPLOYMENT_METING.md` 第十节 |

---
## 三、路径 1：静态站部署（宝塔 Nginx 静态托管）

### 3.1 前置环境
```bash
# 宝塔「软件商店 → Node.js 版本管理器」安装 v22+，然后：
export PATH=/www/server/nodejs/v22.*/bin:$PATH
node -v                 # 期望 v22.x 或更高
npm i -g pnpm@11.1.3
pnpm -v
```
**验收**：两条命令都有版本输出。
> 宝塔安装的 node 不在默认 PATH（位于 `/www/server/nodejs/vXX/bin`）；
> `scripts/deploy-baota.sh` 会自动探测并加入 PATH，无需手工处理。

### 3.2 获取代码与依赖
```bash
mkdir -p /www/wwwroot && cd /www/wwwroot
git clone <仓库地址> mizuki && cd mizuki
cp .env.example .env       # 不使用「内容分离」功能就保持 ENABLE_CONTENT_SYNC=false
pnpm install --frozen-lockfile
```
**验收**：`test -x node_modules/.bin/astro && echo ok`

### 3.3 构建（重点：内存 + 产物完整性）
`pnpm build` 的完整链路是：
```
node scripts/update-anime.mjs && astro build && pagefind --site dist && node scripts/compress-fonts/index.js
```

**① 内存受限（4 G 机器）**
```bash
NODE_OPTIONS=--max-old-space-size=1536 pnpm build
```
（实测 `astro build` 峰值约 2 GB；限制到 1 GB 也能构建成功，只是慢一点。建议同时挂 2 GB swap。）

**② 网络受限时用回退链路**（`update-anime.mjs` 会访问番剧接口，字体子集化会访问 3 个远程接口）
```bash
NODE_OPTIONS=--max-old-space-size=1536 pnpm exec astro build \
  && pnpm exec pagefind --site dist \
  && node scripts/compress-fonts/index.js   # 这一步失败可跳过（仅影响字体体积）
```

**③ 构建后必须校验这三样**（AI 必做）
```bash
ls dist/index.html          # 站点入口
ls -d dist/pagefind         # 站内搜索索引；缺失 = 搜索功能坏掉
ls -d dist/_astro           # 带 hash 的 JS/CSS/字体
```
> ⚠️ **最常见的坑**：只执行了 `astro build` 而漏了 `pagefind`，构建"成功"但 `dist/pagefind` 不存在，
> 线上搜索会 404。我们本地实测踩到过，务必校验。

### 3.4 宝塔站点配置（网站目录 / 运行目录）
「网站 → 添加站点」：

| 字段 | 填写 |
|---|---|
| 域名 | `你的域名`，换行再填 `www.你的域名` |
| 根目录 | `/www/wwwroot/mizuki-web` |
| FTP / 数据库 | 不创建 |
| PHP 版本 | **纯静态** |

「站点 → 设置 → 网站目录」：网站目录 `/www/wwwroot/mizuki-web`，运行目录 `/`（不要选子目录）。

| 方式 | 网站目录 | 运行目录 | 评价 |
|---|---|---|---|
| **独立发布目录（推荐）** | `/www/wwwroot/mizuki-web` | `/` | `rsync` 同步产物，**重建期间线上不空窗**，也不会动到宝塔的 `.user.ini` |
| 直接指向 dist | `/www/wwwroot/mizuki/dist` | `/` | 可用，但 `astro build` 会先清空 `dist` → 重建那十几秒线上 404/白屏 |
| 源码目录 + 子目录 | `/www/wwwroot/mizuki` | `/dist` | 同上的空窗问题，且把源码也暴露在站点目录 |

> **最终根目录 = 网站目录 + 运行目录**，由面板写入 Nginx 的 `root`；
> 因此**不要**在站点配置里再写 `root`，避免冲突。

### 3.5 Nginx 配置（把 `docs/nginx/baota.conf` 合并进站点 `server { }`）
```nginx
index index.html;

location / {
    try_files $uri $uri/ $uri/index.html =404;
}
error_page 404 /404.html;

location /_astro/  { expires 1y; }   # 带内容 hash → 长缓存
location /pagefind/{ expires 7d; }   # 搜索索引
location /assets/  { expires 30d; }
location /images/  { expires 30d; }
location /pio/     { expires 30d; }
location /js/      { expires 30d; }

gzip on;
gzip_vary on;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css application/javascript application/json image/svg+xml application/xml application/rss+xml;

add_header X-Content-Type-Options nosniff;
add_header X-Frame-Options DENY;
add_header X-XSS-Protection "1; mode=block";
add_header Referrer-Policy strict-origin-when-cross-origin;
```
为什么必须保留 `try_files`：项目设了 `trailingSlash: "always"`，所有页面编译成 `/xxx/index.html`。
为什么用 `expires` 而不写 `add_header Cache-Control`：location 里一旦出现自己的 `add_header`，
父级的安全响应头就不再继承（Nginx 继承规则）。

保存后「软件商店 → Nginx → 重载配置」。

### 3.6 方案二：本地构建后上传（服务器内存小就用这个）
1. 本地 `pnpm build`（同样要确认 `dist/pagefind` 存在）；
2. 打包 `dist` → 宝塔「文件」上传 → **在线解压**到网站目录；
3. 解压后 `index.html` **必须直接位于网站根**（不要多套一层 `dist/`）。

### 3.7 验收清单（逐条执行，全绿才算部署成功）
```bash
DOMAIN=你的域名
curl -sI  https://$DOMAIN/ | head -1                  # 期望 HTTP/2 200
curl -s   https://$DOMAIN/ | grep -c 'id="banner-wrapper"'   # ≥1：首页横幅渲染出来了
curl -sI  https://$DOMAIN/404 | head -1               # 期望 404（自定义页生效）
curl -s   https://$DOMAIN/pagefind/pagefind.js | head -c 40  # 非空：搜索索引在线
curl -sI  https://$DOMAIN/assets/desktop-banner/1.webp | grep -i 'cache-control\|expires'  # 有缓存策略
# 带宽压缩是否生效（任选一个大文本资源）
curl -sI -H 'Accept-Encoding: gzip' https://$DOMAIN/ | grep -i 'content-encoding'   # 期望 gzip
```

### 3.8 更新流程
```bash
cd /www/wwwroot/mizuki && git pull && bash scripts/deploy-baota.sh
```
`deploy-baota.sh` 依次做：探测 Node → `pnpm install --frozen-lockfile` → 构建（失败自动回退纯 `astro build`）
→ 校验 `dist/index.html` → `rsync` 到 `SITE_DIR` → 以 root 运行时 `chown www:www`。

可覆盖的环境变量：`SITE_DIR`（默认 `/www/wwwroot/mizuki-web`）、`WEB_USER`（默认 `www`）、
`NODE_BIN_DIR`（自动探测）、`MEM_LIMIT`（默认 2048，**4 G 机器建议 1536**）。

定时自动发布（宝塔「计划任务 → Shell」）：
```bash
cd /www/wwwroot/mizuki && git pull && MEM_LIMIT=1536 bash scripts/deploy-baota.sh
```

---

## 四、路径 2：Docker 自建 Meting 音乐接口（本节内容自包含）

> 只有当博客需要「稳定的在线音乐播放器 + QQ 音乐 VIP 曲目」时才做本章。
> 不做也不影响静态站运行（在 `src/config/musicConfig.ts` 里把 `enable` 设为 `false` 即可）。

### 4.1 请求链路与三条硬性要求
```
① 浏览器 fetch  → ② https://meting.你的域名/?server=tencent&type=playlist&id=xxx
                     │ Nginx 反代（443 → 127.0.0.1:8899）
                     ▼
                  ③ Docker 容器 meting（PHP 8.2 + Apache，内含 meting-api）
                     │ 容器内 PHP 去请求音乐平台，返回 JSON {name, artist, url, pic, lrc}
                     ▼
④ <audio src="https://meting.你的域名/?type=url&id=xxx">
      → 容器返回 **302 跳转音乐平台 CDN** → 音频直连 CDN 播放（**流量不经过你的服务器**）
```
| 硬性要求 | 原因 |
|---|---|
| 接口必须是 **HTTPS** | 主站是 https，http 接口会被浏览器按「混合内容」拦截 |
| 容器端口**只绑 127.0.0.1** | 避免 8899 暴露公网；对外统一走 Nginx |
| 反代必须保留 `proxy_set_header Host $host` | meting-api 用 `HTTP_HOST` 生成 url/pic/lrc，Host 错了音频地址就指错域名 |

CORS 由 `index.php` 自带（`Access-Control-Allow-Origin: *`），**Nginx 里不要再加**，
否则 `add_header` 的继承规则可能把它覆盖掉。

### 4.2 前置检查（缺一不可）
```bash
docker version && docker compose version        # 需要 compose v2（docker compose，不是 docker-compose）
docker pull php:8.2-apache                      # 能拉基础镜像
curl -sI https://codeload.github.com | head -1  # 能取 meting-api 源码（脚本走 tarball）
ss -ltnp | grep 8899 || echo "8899 空闲"
```

**国内服务器拉不到 Docker Hub → 配镜像源（一次性）**：编辑 `~/.docker/daemon.json`
```json
{ "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run"] }
```
重启 Docker 后确认：`docker info --format '{{.RegistryConfig.Mirrors}}'`

### 4.3 全套文件（仓库已提供，可原样复制）

**`docs/meting/docker-compose.yml`**
```yaml
services:
  meting:
    build: .
    image: mizuki-meting:latest
    container_name: meting
    restart: unless-stopped
    ports:
      - "127.0.0.1:8899:80"                            # 只绑回环，不对外
    volumes:
      - ./meting-api/cache:/var/www/html/cache          # 歌单缓存持久化
      - ./qq-cookie.txt:/var/www/html/qq-cookie.txt:ro  # 登录 Cookie（只读挂载）
    environment:
      TZ: Asia/Shanghai
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS 'http://127.0.0.1/?server=netease&type=name&id=416892104' >/dev/null || exit 1"]
      interval: 60s
      timeout: 10s
      retries: 3
# 可选（4C4G 同机跑静态站时限制资源）：
#    mem_limit: 256m
#    cpus: 0.5
```

**`docs/meting/Dockerfile`**
```dockerfile
FROM php:8.2-apache

# Meting.php 的签名/加密逻辑依赖 bcmath
RUN docker-php-ext-install bcmath

# ★ 关键：Meting.php（2019 年代码）在 PHP 8.2 下会抛 Deprecated/Warning，
#   而 index.php 靠 header('Location: ...') 做 302 跳转，
#   一旦警告污染响应体，header 就会失败 → 播放列表能拿到、但点了没声音。
#   因此关闭 display_errors、压低错误级别、错误转存容器日志。
RUN printf '%s\n' \
        'display_errors = Off' \
        'display_startup_errors = Off' \
        'error_reporting = E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_WARNING & ~E_STRICT' \
        'log_errors = On' \
        'error_log = /dev/stderr' \
        > /usr/local/etc/php/conf.d/zz-meting.ini

COPY meting-api/ /var/www/html/

RUN mkdir -p /var/www/html/cache/playlist \
    && chown -R www-data:www-data /var/www/html/cache

EXPOSE 80
```

**`docs/meting/nginx-meting.conf`**（合并进「meting 独立站点」的 `server { }`）
```nginx
location / {
    proxy_pass http://127.0.0.1:8899;
    proxy_http_version 1.1;

    proxy_set_header Host $host;              # ★ 必须保留
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_connect_timeout 10s;
    proxy_send_timeout 30s;
    proxy_read_timeout 30s;

    proxy_buffering off;                      # 播放列表是小 JSON，直接透传
}
```

**`docs/meting/qq-cookie.txt.example`**（复制成 `qq-cookie.txt` 后只保留一行真实值）
```
uin=o0123456789; qm_keyst=Q_H_L_xxxx; qqmusic_key=Q_H_L_xxxx
```

---

### 4.4 一键部署（推荐：`scripts/deploy-meting.sh`）
```bash
cd /www/wwwroot/mizuki
DEPLOY_DIR=/www/wwwroot/meting \
PUBLIC_DOMAIN=meting.你的域名 \
PUBLIC_SCHEME=https \
bash scripts/deploy-meting.sh
```
脚本自动：① 检查 docker/compose → ② 拉 meting-api 源码（tarball 优先，失败回退 git）→
③ 复制本仓库的 `Dockerfile / docker-compose.yml` → ④ **改写 `index.php`**（`API_URI`、Cookie 读取、缓存开关）→
⑤ `docker compose up -d --build` → ⑥ `php -l` 自检 → ⑦ 逐首探测音频地址。

**脚本全部动作**：

| 命令 | 作用 |
|---|---|
| `bash scripts/deploy-meting.sh` | 构建 + 启动 + 自测（默认） |
| `bash scripts/deploy-meting.sh test` | 只重跑自测（改完歌单/Cookie 后） |
| `bash scripts/deploy-meting.sh refresh` | 清服务端歌单缓存（换歌单后立刻生效） |
| `bash scripts/deploy-meting.sh restart` | 改完 `index.php` 后重启容器 |
| `bash scripts/deploy-meting.sh logs` | 查看容器日志 |
| `bash scripts/deploy-meting.sh down` | 停止并移除容器 |

**可覆盖的环境变量**：`DEPLOY_DIR`（默认 `/www/wwwroot/meting`）、`PUBLIC_DOMAIN`、
`PUBLIC_SCHEME`（默认 https）、`METING_PORT`（默认 8899）。
非服务器环境若 `/www` 只读，脚本会自动回退到 `~/meting-local`。

**等价的手工命令**（脚本不可用时）：
```bash
mkdir -p /www/wwwroot/meting && cd /www/wwwroot/meting
git clone --depth 1 https://github.com/injahow/meting-api.git
cp /www/wwwroot/mizuki/docs/meting/{Dockerfile,docker-compose.yml,nginx-meting.conf} .
# 手工把 meting-api/index.php 顶部的 API_URI 改成 https://meting.你的域名/，并打开 Cookie 读取
docker compose up -d --build
curl "http://127.0.0.1:8899/?server=netease&type=playlist&id=14164869977" | head -c 200
```

### 4.5 为接口建站点 + 反代 + 证书（宝塔）
1. 「网站 → 添加站点」：域名 `meting.你的域名`，PHP 选**纯静态**（容器里已带 PHP）；
2. 「设置 → 配置文件」：把 `nginx-meting.conf` 里的 `location / { ... }` 合并进该站点 `server { }`；
3. 「设置 → SSL」：申请 Let's Encrypt，并**开启强制 HTTPS**；
4. 「域名管理」确认已绑定；DNS 把 `meting` 解析到服务器 IP；
5. 放行 80/443（云安全组 + 宝塔防火墙）。

### 4.6 QQ / 网易云 Cookie（VIP 曲目必需）
```bash
bash scripts/update-meting-cookie.sh      # 交互式：粘贴浏览器 Cookie
# 或手工：
#   cp docs/meting/qq-cookie.txt.example /www/wwwroot/meting/qq-cookie.txt
#   编辑成一行真实 Cookie 后 chmod 600
bash scripts/deploy-meting.sh test        # 验证 VIP 曲目可播
```
- Cookie 通过**只读 volume** 挂进容器，`index.php` 每次请求都读它 →
  **过期后只需覆盖宿主机文件，刷新页面即生效，无需重启容器、无需重建镜像**；
- 已被 `.gitignore` 忽略；建议用**独立小号**，别用主力账号；通常几个月过期一次。

### 4.7 健康检查 / 日志 / 自测
```bash
docker compose -f /www/wwwroot/meting/docker-compose.yml ps     # 期望 (healthy)
docker inspect --format '{{.State.Health.Status}}' meting
docker logs --tail 100 meting
bash scripts/deploy-meting.sh test                             # 逐首探测音频地址
curl -s "https://meting.你的域名/?server=tencent&type=name&id=416892104" | head -c 120
```

### 4.8 与静态站同机（4C4G）的资源预算
| 组件 | 常驻内存 |
|---|---|
| 系统 + 宝塔面板 + nginx | 300–600 MB |
| meting 容器 | 50–80 MB（可加 `mem_limit: 256m`） |
| **一次服务器构建（瞬时峰值）** | **1.5–2 GB**（务必留余量；建议 2 GB swap） |
| MySQL / PHP 站点（本博客不需要，别装） | 各 +200–400 MB |

结论：4C4G 同机「静态站 + meting 容器」很轻松；**构建时**别同时做镜像重建或大文件解压。

### 4.9 备份 / 迁移 / 回滚
```bash
# 备份三样：镜像、歌单缓存、Cookie
docker save mizuki-meting:latest | gzip > mizuki-meting.tar.gz
tar czf meting-data.tar.gz -C /www/wwwroot/meting meting-api/cache qq-cookie.txt

# 新机器恢复
docker load < mizuki-meting.tar.gz
mkdir -p /www/wwwroot/meting && tar xzf meting-data.tar.gz -C /www/wwwroot/meting
cd /www/wwwroot/meting && docker compose up -d      # compose 里保留 image: 则不必重新构建

# 回滚（不影响静态站）
docker compose down
```
> 镜像里**不含 Cookie**（运行时挂载），迁移后必须补 `qq-cookie.txt`。

### 4.10 常见报错对照
| 现象 | 原因与处理 |
|---|---|
| `failed to fetch oauth token ... i/o timeout` | 拉不到基础镜像 → 按 4.2 配镜像源并重启 Docker |
| `mkdir: /www: Read-only file system` | 在非服务器环境用了默认目录 → `DEPLOY_DIR=$HOME/meting-local` |
| `✘ 源码获取失败（tarball 与 git 都不通）` | 手动把 meting-api 源码放到 `$DEPLOY_DIR/meting-api/` |
| 歌单能出来、点了没声音 | `API_URI` 与实际访问地址不一致 → 核对 `PUBLIC_SCHEME/PUBLIC_DOMAIN`；或 PHP 警告污染响应（本仓库 Dockerfile 已修） |
| VIP 曲目不可播 | `qq-cookie.txt` 缺失/过期 → `update-meting-cookie.sh` 后 `test` |
| 容器 healthy 但自测全不可播、响应 `text/html` | Cookie 未生效或 PHP 警告 → `deploy-meting.sh logs` |
| 主站报「混合内容被拦截」 | 接口没上 HTTPS → 给 `meting.你的域名` 配证书 + 强制 HTTPS |
| 8899 被占用 | `METING_PORT=xxxx bash scripts/deploy-meting.sh`，并同步改反代 `proxy_pass` |

### 4.11 不想用 Docker？
→ 见 `docs/DEPLOYMENT_METING.md`「路径 A：宝塔 PHP 站点」（约 30 MB 内存，不装 Docker）；
或改用公共 Meting 实例（把 `src/config/musicConfig.ts` 的 `meting_api` 换成公共地址，稳定性不保证）。

---

## 五、部署后必须改的前端配置（改完要重新构建发布）

| 文件 | 项 | 当前值 | 部署时要改成 |
|---|---|---|---|
| `src/config/siteConfig.ts` | `siteURL` | `https://cnyicheng.top/` | **你的域名**（不改会导致 sitemap / RSS / OG 图指向别人的站点） |
| `src/config/musicConfig.ts` | `meting_api` | `http://127.0.0.1:8899/?server=:server&type=:type&id=:id&r=:r` | **`https://meting.你的域名/?server=:server&type=:type&id=:id&r=:r`**（本地开发才用 127.0.0.1） |
| `src/config/musicConfig.ts` | `enable` | `true` | 不做音乐接口就设 `false`（可省掉第三方请求） |
| `src/config/musicConfig.ts` | `server` / `id` / `type` | `tencent` / `9777005268` / `playlist` | 按你的歌单改（QQ=tencent、网易云=netease） |
| `src/config/rainyDayConfig.ts` | `enable` 等 | 见 6.5 | 不需要雨特效就 `enable: false` |

> 改完执行 `bash scripts/deploy-baota.sh`（或本地构建后上传），**配置改动需要重新构建才生效**。

---

## 六、【本次改动补充】2026-09 性能优化对部署的影响（AI 必读）

本节记录最近一轮优化（首屏减重 + 图片重压 + 岛屿修正）中**会影响部署**的部分。

### 6.1 ⚠️ 横幅图现在带 `crossorigin="anonymous"` —— 用 CDN/OSS 必须配 CORS
- 现状：`src/components/layout/Banner.astro` 会给**同源**横幅图加 `crossorigin="anonymous"`；
  `src/components/atoms/Image/Image.astro` 新增了 `crossorigin` 属性支持。
- **原因**：雨滴特效用 THREE 加载横幅图时是 CORS 模式请求，而轮播 `<img>` 默认是 no-cors，
  浏览器把两者分成两份 HTTP 缓存 → **每次轮播换帧雨层都会把同一张图完整重下一次**
  （实测 `3.webp` 874 KB 下了两遍，一个 12 秒周期白下约 1.8 MB）。统一成 CORS 模式后共用缓存，问题消失。
- **对部署的要求**：
  | 场景 | 是否要额外配置 |
  |---|---|
  | 图片与站点**同域**（默认、推荐） | ✅ 不用管，同源请求不受 CORS 限制 |
  | 图片放 **CDN / OSS / 独立域名**（或用了 `assetsPrefix`） | ❌ **必须**让图片响应带 `Access-Control-Allow-Origin`，否则**横幅图会加载失败** |
  | CDN 回源站 | 在源站（Nginx）加：`add_header Access-Control-Allow-Origin "*" always;`（仅对图片路径），或在 CDN 控制台开启 CORS |
- 同理，雨滴特效的纹理请求也是 CORS 模式 —— 跨域方案下必须满足上面的条件。

### 6.2 两个新增脚本是**本地/CI 工具**，服务器不需要执行
| 脚本 | 用途 | 服务器 | 依赖 |
|---|---|---|---|
| `scripts/optimize-images.mjs` | 图片重压（`--dry-run` 可预览；原图备份到 `.image-backup/`） | ❌ 不需要 | 项目自带 `sharp` |
| `scripts/measure-first-load.py` | 首屏传输量/雨特效时机测量（产出 `reports/first-load-*.json`） | ❌ 不需要 | 本机 Python + Playwright + Chrome |

### 6.3 不要部署 / 不要同步到网站目录的东西
| 路径 | 说明 |
|---|---|
| `.image-backup/` | 图片重压前的**原图备份（约 16 MB）**，已加入 `.gitignore`；`git clone` 不会带、`rsync dist/` 也不会带 |
| `reports/` | 首屏测量结果，已 gitignore |
| `.git/` | 若手工上传，注意别把整个源码目录当站点根 |
| `qq-cookie.txt` | 音乐 Cookie，已 gitignore；**绝不要**放进 `dist/` 或提交 |

> 部署走 `dist/` 目录时天然不会带上这些；但如果把**整个源码目录**作为网站根（不推荐），
> 必须在 Nginx 里 `deny` 掉 `.image-backup/`、`.git/`、`reports/`。

### 6.4 构建产物完整性（最容易踩）
- 只跑 `astro build` 会**缺 `dist/pagefind/`**（站内搜索 404）→ 必须补 `pagefind --site dist`；
- 完整链路 = `astro build` + `pagefind` + `compress-fonts`（见 3.3）；
- 构建后校验：`dist/index.html`、`dist/pagefind/`、`dist/_astro/` 三者都在。

### 6.5 雨滴特效改为「延后加载」（对服务器无额外要求）
- 现在默认 `lazyMount: true`：等页面 `load` + 浏览器空闲后才加载 Three.js（**117 KB gzip**）并淡入，
  弱网/省流（`saveData` / 2G）直接不加载；用户手动切换雨滴面板时立即挂载。
- 对服务器：只是普通静态 JS 请求，走 `/_astro/` 的 1 年缓存即可，无需任何配置。
- 若想恢复"开屏就有雨"：`src/config/rainyDayConfig.ts` 里 `lazyMount: false`（会重新回到首屏关键路径）。

### 6.6 岛屿（`client:*`）指令调整 —— 服务端零影响
- 9 个 `client:only` 降为：7 个 `client:idle` + 1 个 `client:media` + 1 个 `client:visible`；
  仍保留 2 个 `client:only`（Search、ArchivePanel——它们在渲染期依赖浏览器 API）。
- 效果：这些按钮/图标现在**直接出现在静态 HTML**，水合推迟到空闲/可见。
- 只有一处体感变化：首屏 HTML 体积略增（多出 SSR 的按钮标记），无服务端成本。

### 6.7 资产体积变化（图片重压明细）
`node scripts/optimize-images.mjs` 共重压 **39 个文件、省 8.69 MB**：

| 资产 | 改前 | 改后 |
|---|---|---|
| `public/assets/desktop-banner/*` | 1.7 MB（`3.webp` 是 **6400×3396 / 874 KB**） | **800 KB**（`3.webp` → 2560×1358 / 205 KB） |
| `public/assets/mobile-banner/*` | 636 KB | 504 KB |
| `public/images/**`（相册/日记/设备） | 9.7 MB（最大 901 KB） | **3.8 MB** |
| 文章封面 `src/content/posts/**/cover.*` | 1.3 MB（4096×2891） | 260 KB |
| 头像 `src/assets/images/avatar.webp` | 497 KB（实为 PNG 编码） | 32 KB |
| `logo.png` | 267 KB | 27 KB |
| **`dist/` 总体积** | **44 MB** | **26 MB** |

> 回滚：原图在 `.image-backup/`（保持原目录结构），拷回原路径即可。

### 6.8 已知遗留（不影响本次部署，供后续排期）
1. 桌面/移动两套首图**在错误的一端仍会下载**（约 347 KB/端）—— 需用 `<picture><source media>` 或把图片迁到
   `src/assets` 走 `astro:assets` 才能根治；
2. 图片目前只有 WebP，尚未输出 AVIF（可再省 ~35%）；
3. 首页仍加载部分未用 CSS（katex / fancybox / twikoo 等，约 22 KB gzip）；
4. `dist` 里 KaTeX 同时有 ttf/woff/woff2（约 932 KB 字体，可再瘦身）。

---

## 七、AI 执行完成后的统一自查清单

部署完成后**逐条**核对（把 `DOMAIN` 换成真实域名）：

### 静态站
- [ ] `ls dist/index.html dist/pagefind dist/_astro` 三者齐全
- [ ] `curl -sI https://$DOMAIN/ | head -1` → `HTTP/2 200`
- [ ] `curl -s https://$DOMAIN/ | grep -c 'banner-wrapper'` → ≥1（首页横幅存在）
- [ ] `curl -sI https://$DOMAIN/404 | head -1` → 404（自定义错误页生效，说明 `try_files` + `error_page` 正常）
- [ ] `curl -s https://$DOMAIN/pagefind/pagefind.js | head -c 20` → 非空（搜索索引在线）
- [ ] `curl -sI -H 'Accept-Encoding: gzip' https://$DOMAIN/ | grep -i content-encoding` → `gzip`
- [ ] `curl -sI https://$DOMAIN/_astro/ 某个 js | grep -i expires` → 有长缓存
- [ ] 浏览器打开：无 404 资源、无控制台报错、暗色/亮色切换正常、移动端布局正常
- [ ] 站点根目录属主是 `www:www`，`.user.ini` 未被删除
- [ ] `siteURL` 已改成自己的域名（检查 `dist/sitemap-index.xml` / `dist/rss.xml` 里的域名）

### 音乐接口（做了第四章才检查）
- [ ] `docker compose ps` → `(healthy)`
- [ ] `curl -s "https://meting.你的域名/?server=tencent&type=name&id=416892104"` → 返回含 `name` 的 JSON
- [ ] `bash scripts/deploy-meting.sh test` → 可播放曲目数 > 0
- [ ] 博客页面点开播放器 → 能取到歌单、能出声（VIP 曲目依赖 Cookie）
- [ ] `src/config/musicConfig.ts` 的 `meting_api` 已改为**公网 https** 地址，且已重新构建发布
- [ ] Cookie 文件权限 `600`、不在 Git 里

### 资源与安全
- [ ] 构建时观察 `free -m`：`available` 未跌破 100 MB（否则加 swap 或调低 `MEM_LIMIT`）
- [ ] `docker stats --no-stream` → meting 容器内存 < 150 MB
- [ ] 8899 端口**未**对公网开放（`ss -ltnp | grep 8899` 只显示 127.0.0.1）
- [ ] 云安全组只放行 80/443/（按需的 SSH 端口）

---

## 八、故障排查总表

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 访问显示宝塔默认页 | 域名未绑定 / 解析未生效 | 站点「域名管理」绑定；`dig +short 域名 A` 确认 |
| 403 Forbidden | 运行目录多选了一层，或属主/权限不对 | 改运行目录为 `/`；`chown -R www:www 网站目录` |
| 404 / 白屏、样式全丢 | 资源没上传全 / `index.html` 不在根 / 漏了 `try_files` | 见 3.4、3.5 |
| 站内搜索报错 | `dist/pagefind/` 缺失（只跑了 `astro build`） | 补跑 `pnpm exec pagefind --site dist`，或走完整 `pnpm build` |
| 构建报内存不足 | 4G 机器默认堆偏大 | `NODE_OPTIONS=--max-old-space-size=1536 pnpm build` + 2 GB swap |
| 构建卡在 `update-anime.mjs` | 服务器访问不到番剧接口 | 用 3.3 的回退链路（`astro build` + `pagefind`） |
| `npm install` 报 only-allow | 用了 npm/yarn | 必须 `pnpm install` |
| 面板提示 `.user.ini` 丢失 | 网站目录直接指向了 `dist`，被清空 | 改用独立发布目录（`rsync --exclude='.user.ini'`） |
| 雨滴特效不出现 | 移动端默认禁用 / 弱网跳过 / `respectReducedMotion` | 桌面端 + 正常网络；配置见 `rainyDayConfig.ts` |
| 雨滴特效晚 1 秒才出现 | `lazyMount: true`（设计如此，为了首屏更快） | 想开屏就有雨 → `lazyMount: false` |
| 上线 CDN 后横幅图裂开 | 图片跨域但没返回 CORS 头（见 6.1） | 给图片路径加 `Access-Control-Allow-Origin` |
| 音乐播放器无歌单 | 接口地址还是 `127.0.0.1` | 改成 `https://meting.你的域名/` 并重新构建发布 |
| 点了歌单没声音 | PHP 警告污染响应 / Cookie 失效 | `deploy-meting.sh logs`；`update-meting-cookie.sh` 后 `test` |
| 主站被拦「混合内容」 | 音乐接口未上 HTTPS | 给 `meting.你的域名` 配证书 + 强制 HTTPS |

---

## 九、附录：文件与脚本索引

| 文件 | 作用 |
|---|---|
| `docs/DEPLOYMENT_FOR_AI.md` | **本文件**：总纲（AI 执行入口） |
| `docs/DEPLOYMENT_BAOTA.md` | 静态站部署详解（面板截图级步骤、目录方案对比） |
| `docs/DEPLOYMENT_METING.md` | 音乐接口三条路径详解（含不用 Docker 的 PHP 方案、跨机迁移） |
| `docs/nginx/baota.conf` | 静态站 Nginx 片段 |
| `docs/meting/Dockerfile` / `docker-compose.yml` / `nginx-meting.conf` / `qq-cookie.txt.example` | Docker 音乐接口全套文件 |
| `scripts/deploy-baota.sh` | 静态站一键构建 + 发布（`SITE_DIR` / `MEM_LIMIT` / `WEB_USER`） |
| `scripts/deploy-meting.sh` | 音乐接口一键部署（默认 / `test` / `refresh` / `restart` / `logs` / `down`） |
| `scripts/update-meting-cookie.sh` | 更新 QQ/网易云 Cookie |
| `scripts/optimize-images.mjs` | **本地**图片重压（`--dry-run` 预览；备份到 `.image-backup/`） |
| `scripts/measure-first-load.py` | **本地**首屏测量（`reports/first-load-*.json`） |
| `docs/README.md` | 文档索引（含"我想优化首屏加载 / 压缩图片"入口） |

---

### 最小可执行路径（赶时间就看这一段）

**只要站点能跑**（服务器已装 Node ≥22 + 宝塔 Nginx）：
```bash
# ① 构建
cd /www/wwwroot/mizuki
cp .env.example .env
pnpm install --frozen-lockfile
NODE_OPTIONS=--max-old-space-size=1536 pnpm build
ls dist/index.html dist/pagefind dist/_astro        # 三者必须都在

# ② 发布（独立发布目录，重建不空窗）
SITE_DIR=/www/wwwroot/mizuki-web MEM_LIMIT=1536 bash scripts/deploy-baota.sh

# ③ 面板：站点根目录 = /www/wwwroot/mizuki-web，PHP 选「纯静态」
#    伪静态粘贴 docs/nginx/baota.conf，绑定域名，申请证书 + 强制 HTTPS

# ④ 验收
curl -sI https://你的域名/ | head -1                      # 200
curl -s  https://你的域名/ | grep -c banner-wrapper        # ≥1
curl -s  https://你的域名/pagefind/pagefind.js | head -c 20
```
**再加音乐接口**：
```bash
cd /www/wwwroot/mizuki
DEPLOY_DIR=/www/wwwroot/meting PUBLIC_DOMAIN=meting.你的域名 bash scripts/deploy-meting.sh
# 面板新建站点 meting.你的域名 + 粘贴 docs/meting/nginx-meting.conf 的 location + 上证书
# 最后把 src/config/musicConfig.ts 的 meting_api 改成 https://meting.你的域名/ ，重新构建发布
```

