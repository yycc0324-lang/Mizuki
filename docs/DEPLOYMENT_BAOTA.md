# 宝塔面板部署指南（Nginx 静态托管）

本项目是**纯静态站点**（`astro.config.mjs` 中 `output: "static"`，未安装任何 SSR 适配器），
构建产物为 `dist/` 目录，**不需要常驻 Node 进程，也不需要配置任何「启动项」**。
宝塔面板里正确的做法是：用 **Nginx 直接托管 `dist/`**。

> 🔎 找不到「启动项」是正常的：宝塔的「Node 项目 / PM2」只服务于 SSR 应用（如服务端渲染的 Next.js）。
> 本项目没有 `ecosystem.config.js`、`Dockerfile` 之类的启动文件，
> `package.json` 里的 `start` / `preview` 也只是本地开发与预览用途。

## 📖 目录

- [环境要求](#-环境要求)
- [方案一：服务器上构建（推荐）](#方案一服务器上构建推荐)
- [方案二：本地构建后上传](#方案二本地构建后上传)
- [宝塔站点配置：网站目录 / 运行目录](#-宝塔站点配置网站目录--运行目录)
- [Nginx 配置（伪静态）](#-nginx-配置伪静态)
- [域名解析与 HTTPS](#-域名解析与-https)
- [后续更新流程](#-后续更新流程)
- [故障排查](#-故障排查)

---

## 🧩 环境要求

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| Node.js | **≥ 22** | 宝塔「软件商店 → Node.js 版本管理器」中安装 |
| 包管理器 | **pnpm** | `package.json` 的 `preinstall` 为 `npx only-allow pnpm`，**用 npm / yarn 安装依赖会直接失败** |
| 内存 | 建议 ≥ 2G | 小内存机器构建时可加 `NODE_OPTIONS=--max-old-space-size=2048` |
| Nginx | 任意稳定版 | 宝塔「软件商店」安装 |

> 宝塔 Node 版本管理器安装的 node 不在默认 PATH 中（位于 `/www/server/nodejs/vXX/bin`），
> 直接执行 `node -v` 可能提示找不到命令；`scripts/deploy-baota.sh` 会自动探测并加入 PATH。

---

## 方案一：服务器上构建（推荐）

### 1. 安装 Node 与 pnpm

宝塔「软件商店」→ 安装 **Node.js 版本管理器**（选 v22 或更高）→ 在「终端」执行：

```bash
export PATH=/www/server/nodejs/v22.*/bin:$PATH
npm i -g pnpm@11.1.3
node -v && pnpm -v
```

### 2. 拉取代码并构建

```bash
cd /www/wwwroot/mizuki          # 换成你的项目目录
cp .env.example .env            # 不使用内容分离功能就保持 ENABLE_CONTENT_SYNC=false
pnpm install
pnpm build                      # 产物在 ./dist
```

`pnpm build` 的完整链路为：

```
node scripts/update-anime.mjs && astro build && pagefind --site dist && node scripts/compress-fonts/index.js
```

其中 `update-anime.mjs` 在番剧模式为 `bangumi` / `bilibili` 时会请求外部接口，
**服务器网络受限或接口异常时会导致整条构建链中断**。遇到这种情况可以只执行核心构建：

```bash
pnpm exec astro build && pnpm exec pagefind --site dist
```

### 3. 一键构建 + 发布（可选）

项目提供了 `scripts/deploy-baota.sh`，它会依次完成：
探测 Node 路径 → `pnpm install --frozen-lockfile` → 构建（失败自动回退）→
校验 `dist/index.html` → 同步到网站目录 → 以 root 运行时自动 `chown www:www`。

```bash
cd /www/wwwroot/mizuki
bash scripts/deploy-baota.sh
```

脚本顶部「配置区」可按实际情况调整：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SITE_DIR` | `/www/wwwroot/mizuki-web` | 网站根目录（= 宝塔的「网站目录 + 运行目录」）；设为空字符串则直接使用项目内的 `dist` |
| `WEB_USER` | `www` | 宝塔站点属主 |
| `NODE_BIN_DIR` | 自动探测 | 如 `/www/server/nodejs/v22.18.0/bin` |
| `MEM_LIMIT` | `2048` | Node 构建内存上限（MB） |

也支持临时覆盖，便于测试：

```bash
SITE_DIR=/tmp/test-web bash scripts/deploy-baota.sh
```

---

## 方案二：本地构建后上传

适合服务器内存较小、不想在服务器安装 Node 的机器：

1. 本地执行 `pnpm build` 生成 `dist/`；
2. 将 `dist` 打包为 zip 上传到宝塔「文件」，右键**在线解压**到网站目录；
3. 解压后确保 `index.html` **直接位于**网站根目录（不要多套一层 `dist/`）。

---

## 📁 宝塔站点配置：网站目录 / 运行目录

「网站 → 添加站点」时：

| 字段 | 填写 |
| --- | --- |
| 域名 | `example.com`，换行再填 `www.example.com` |
| 根目录 | `/www/wwwroot/mizuki-web` |
| FTP / 数据库 | 不创建 |
| PHP 版本 | **纯静态** |

「站点 → 设置 → 网站目录」：

| 字段 | 填写 |
| --- | --- |
| 网站目录 | `/www/wwwroot/mizuki-web` |
| 运行目录 | `/`（保持根目录，不要选子目录） |

> **最终对外访问的根 = 网站目录 + 运行目录。**
> 该路径必须与 Nginx 的 `root` 一致；宝塔会依据这两项自动写入 `root` 指令，
> 因此**不要**再在站点配置文件里重复写 `root`，以免两处冲突。

三种常见填写方式对比：

| 方案 | 网站目录 | 运行目录 | 说明 |
| --- | --- | --- | --- |
| ✅ 独立发布目录（推荐） | `/www/wwwroot/mizuki-web` | `/` | 构建产物由脚本 `rsync` 同步过来，**重建期间线上不空窗**，也不会动到宝塔写入的 `.user.ini` |
| ⚠ 直接指向 dist | `/www/wwwroot/mizuki/dist` | `/` | 可以使用，但 `pnpm build` 会先清空 `dist`，重建那几十秒线上会 404 / 白屏 |
| ⚠ 源码目录 + 子目录 | `/www/wwwroot/mizuki` | `/dist` | 效果同上（实际根为 `.../mizuki/dist`），但把源码也放进了站点目录，不推荐 |

---

## ⚙ Nginx 配置（伪静态）

在站点「设置 → 配置文件」中，把 `docs/nginx/baota.conf` 的内容合并进已有的 `server { }` 块内
（或粘贴到「设置 → 伪静态」中，二者取其一，不要重复）。

这样做是因为本项目 `astro.config.mjs` 设置了 `trailingSlash: "always"`，
所有页面都会编译成 `/xxx/index.html`，需要靠 `try_files` 才能正确兜底并显示自定义 404：

```nginx
index index.html;

location / {
    try_files $uri $uri/ $uri/index.html =404;
}
error_page 404 /404.html;

location /_astro/  { expires 1y; }
location /pagefind/{ expires 7d; }
location /assets/  { expires 30d; }

gzip on;
gzip_vary on;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css application/javascript application/json image/svg+xml application/xml;

add_header X-Content-Type-Options nosniff;
add_header X-Frame-Options DENY;
add_header Referrer-Policy strict-origin-when-cross-origin;
```

> 说明：缓存使用 `expires` 而非 `add_header Cache-Control`，
> 因为 Nginx 中 location 块一旦定义了自己的 `add_header`，父级的安全响应头就不再继承。

保存后若未生效，前往「软件商店 → Nginx → 重载配置」。

---

## 🌐 域名解析与 HTTPS

1. **添加解析**（在你域名的 DNS 服务商，或宝塔的 DNS 管理里）：

   | 主机记录 | 类型 | 记录值 | TTL |
   | --- | --- | --- | --- |
   | `@` | A | 服务器公网 IP | 600 |
   | `www` | A | 服务器公网 IP | 600 |

   验证是否生效：

   ```bash
   dig +short example.com A      # 必须返回你的服务器 IP
   ```

2. **站点绑定域名**：在「站点 → 域名管理」中加入 `example.com` 与 `www.example.com`，
   否则即使解析正确，也可能命中默认站点。

3. **申请证书**：解析生效后再「站点 → SSL → Let's Encrypt」申请，成功后开启**强制 HTTPS**。
   Let's Encrypt 校验要求域名已解析且 80 端口可达。

4. **放行端口**：云厂商安全组与宝塔「安全 → 防火墙」都要放行 `80`、`443`。
   服务器位于中国大陆时，域名还需完成 **ICP 备案**，否则会被运营商阻断
   （现象：能 ping 通 IP，但网站打不开、证书也申请不下来）。

---

## 🔄 后续更新流程

1. 修改 `src/content/posts/` 下的 Markdown，或更新 `src/config/` 中的配置；
2. 执行 `bash scripts/deploy-baota.sh`（或手动 `pnpm build` 后把 `dist` 内容覆盖到网站目录）；
3. 浏览器刷新验证。

若想让服务器定时自动拉取代码并发布，可在宝塔「计划任务」中新建 Shell 脚本：

```bash
cd /www/wwwroot/mizuki && git pull && bash scripts/deploy-baota.sh
```

---

## 🛠 故障排查

| 现象 | 可能原因与处理 |
| --- | --- |
| 访问显示宝塔默认页 | 域名未在站点「域名管理」中绑定，或解析未生效而命中默认站点 |
| `Could not resolve host` / 浏览器提示找不到服务器 | A 记录未添加或未生效；用 `dig +short 域名 A` 确认 |
| 403 Forbidden | 「运行目录」填错（多选了一层子目录），或网站目录属主不是 `www`、目录权限不足 |
| 404 Not Found | 解压 / 复制时多套了一层目录，`index.html` 未直接位于网站根；或未配置 `try_files` |
| 页面白屏、样式全丢 | `_astro/`、`assets/` 等资源未上传完整，或根目录指错 |
| 构建报内存不足 | 使用 `NODE_OPTIONS=--max-old-space-size=2048 pnpm build` |
| 构建在 `update-anime.mjs` 处中断 | 服务器访问外部接口失败；改用 `pnpm exec astro build && pnpm exec pagefind --site dist` |
| `npm install` 报 only-allow 错误 | 本项目必须使用 pnpm 安装依赖 |
| 面板提示防跨站文件 `.user.ini` 丢失 | 网站目录直接指向了 `dist`，重建时被清空；改用独立发布目录，脚本已用 `rsync --exclude='.user.ini'` 规避 |
| 想确认站点实际根目录 | 在服务器执行 `nginx -T \| grep -A2 'server_name 你的域名'` 查看真实 `root` |

---

## 📌 要点回顾

- 静态站点**没有启动项**，无需 PM2 / Node 项目面板；
- 必须用 **pnpm** 安装依赖（受 `only-allow` 限制）；
- 部署前把 `src/config/siteConfig.ts` 中的 `siteURL` 改成自己的域名，
  否则 sitemap / RSS / OG 图会指向主题作者的站点；
- 推荐「独立发布目录 + `scripts/deploy-baota.sh`」组合，重建时线上不空窗。
