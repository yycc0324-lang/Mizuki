# 自建 Meting 音乐接口指南（Docker 反代 / 宝塔 PHP 双路径）

> 适用场景：博客的在线音乐播放器（`src/config/musicConfig.ts` 中 `mode: "meting"`）
> 需要稳定、可控、可带 **QQ 音乐 VIP Cookie** 的接口，而不是依赖随时可能失效的公共实例。

## 📖 目录

- [一、先搞清楚：请求是怎么走的](#一先搞清楚请求是怎么走的)
- [二、三条实现路径与「适配度」对比](#二三条实现路径与适配度对比)
- [三、路径 C：Docker + Nginx 反代（完整步骤）](#三路径-cdocker--nginx-反代完整步骤)
- [四、三个必须改的坑（否则配好了也播不出声）](#四三个必须改的坑否则配好了也播不出声)
- [五、QQ 音乐（tencent）VIP Cookie 配置](#五qq-音乐tencentvip-cookie-配置)
- [六、博客前端需要改什么](#六博客前端需要改什么)
- [七、验证清单](#七验证清单)
- [八、故障排查](#八故障排查)
- [九、回滚](#九回滚)
- [十、附：路径 A（宝塔 PHP 站点，不用 Docker）](#十附路径-a宝塔-php-站点不用-docker)
- [十一、附：路径 B（现有站点子路径反代）](#十一附路径-b现有站点子路径反代)
- [十二、附：换一台电脑从零部署](#十二附换一台电脑从零部署)

---

## 一、先搞清楚：请求是怎么走的

```
① 浏览器（https://cnyicheng.top，Astro 静态站）
        │  musicPlayerStore.fetchMetingPlaylist() 在「客户端」fetch
        ▼
② 你的接口域名（https://meting.cnyicheng.top/?server=netease&type=playlist&id=xxx）
        │  Nginx 反代（443 → 127.0.0.1:8899）
        ▼
③ Meting 服务（Docker 容器 / PHP 站点，由 PHP 去请求音乐平台）
        │  返回 JSON：{name, artist, url, pic, lrc}
        ▼
④ <audio> 播放 musicPlayerStore 得到的 url
        │  该 url 是 ② 的域名 + ?type=url&id=xxx
        ▼
⑤ Meting 服务返回 302 跳转到音乐平台 CDN，音频直连 CDN 播放
```

**关键结论（决定了整体改造成本）：**

| 结论 | 说明 |
|---|---|
| 接口必须是 **HTTPS** | 博客是 https，浏览器会拦截 https 页面里的 http 请求（混合内容） |
| 接口必须带 **CORS** | `meting-api` 的 `index.php` 已自带 `Access-Control-Allow-Origin: *`，无需额外配置 |
| **音频流量不经过你的服务器** | `type=url` 是 302 跳转到平台 CDN，只有「取播放列表/取地址」这类小请求走你的机器，带宽压力极小 |
| 对博客构建**零影响** | 接口是独立服务，`pnpm build` / `scripts/deploy-baota.sh` 完全不用改 |
| 与静态站**完全隔离** | 静态站继续由宝塔 Nginx 托管 `dist`；接口是另一个站点/容器，互不干扰 |

---

## 二、三条实现路径与「适配度」对比

你当前服务器环境（依据 `docs/DEPLOYMENT_BAOTA.md`）：
纯静态 Astro 站点 + 宝塔面板 + Nginx 静态托管 + 独立发布目录 + `scripts/deploy-baota.sh`，
**没有 Docker、没有 Node 常驻进程、没有 SSR**。

| 维度 | 路径 A：宝塔 PHP 站点 | 路径 B：现有站点子路径反代 | **路径 C：Docker + 反代** |
|---|---|---|---|
| 需要 Docker | ❌ 不需要 | ❌ 不需要 | ✅ 需要（宝塔 Docker 管理器） |
| 需要新域名/子域名 | ✅ `meting.cnyicheng.top` | ❌ 复用 `cnyicheng.top/meting/` | ✅ `meting.cnyicheng.top` |
| 需要新证书/备案 | ✅ 需（子域名也要备案） | ❌ 复用现有证书 | ✅ 需 |
| 对现有 Nginx 配置的侵入 | 无（独立站点） | ⚠️ 要在主站配置里加 location | 无（独立站点） |
| 与静态站一起重建时是否会中断 | 不影响 | 不影响 | 不影响 |
| 环境隔离 / 可迁移性 | 一般（依赖面板 PHP 扩展） | 差 | ✅ 好（镜像 + compose，换服务器可直接搬） |
| 额外故障点 | 少 | 中（缓存/安全头互相干扰） | 中（Docker 守护进程、镜像拉取、网络） |
| 国内服务器拉镜像 | — | — | ⚠️ 需配加速器（否则很慢） |
| 内存占用 | ~30MB（PHP-FPM 共享） | ~30MB | ~50–80MB（独立容器） |
| 适配度评分 | ⭐⭐⭐⭐⭐（最省事） | ⭐⭐⭐ | ⭐⭐⭐⭐（最规范、可迁移） |

**选择建议**

- 只想**最快跑通**、不想在服务器上装 Docker → **路径 A**；
- 服务器上已经有 Docker，或以后还想跑别的自建服务 → **路径 C**（本文重点，因为你问的就是它）；
- 不想再申请域名/证书，能接受动主站配置 → **路径 B**（注意子路径下 `API_URI` 自动适配没问题，见第四节）。

> 三条路最终都在同一个位置收尾：把 `src/config/musicConfig.ts` 的 `meting_api` 换成你自己的接口地址。

---

## 三、路径 C：Docker + Nginx 反代（完整步骤）

本仓库已提供以下可直接使用的文件：

| 文件 | 用途 |
|---|---|
| [`scripts/deploy-meting.sh`](../scripts/deploy-meting.sh) | **一键部署脚本**：依赖检查 → 拉源码 → 改写 `index.php`（API_URI / Cookie / 缓存 / 签名）→ 构建启动 → 自动自测 → 打印后续待办 |
| [`docs/meting/Dockerfile`](./meting/Dockerfile) | 基于 `php:8.2-apache` 构建 meting-api 镜像（补 bcmath 扩展） |
| [`docs/meting/docker-compose.yml`](./meting/docker-compose.yml) | 启动容器，只监听 `127.0.0.1:8899` |
| [`docs/meting/nginx-meting.conf`](./meting/nginx-meting.conf) | 宝塔站点里的 Nginx 反代片段 |
| [`docs/meting/qq-cookie.txt.example`](./meting/qq-cookie.txt.example) | QQ 音乐 Cookie 填写说明（复制为 `qq-cookie.txt` 放进部署目录即可，已被 `.gitignore` 忽略） |

### 第 0 步（推荐）：一条命令完成服务端部分

```bash
# 在服务器上的博客源码目录执行
cd /www/wwwroot/mizuki
PUBLIC_DOMAIN=meting.cnyicheng.top TEST_PLAYLIST_ID=9777005268 bash scripts/deploy-meting.sh
```

脚本会完成下面第 1~5 步的全部工作（含逐首探测播放地址的自测），并打印「宝塔建站 + 前端配置」的待办清单。

| 子命令 | 作用 |
|---|---|
| `bash scripts/deploy-meting.sh` | 构建 + 启动 + 自测 + 打印待办（默认） |
| `bash scripts/deploy-meting.sh test` | 只重跑自测（改完歌单 / Cookie 后用） |
| `bash scripts/deploy-meting.sh restart` | 改完 `index.php` 或 Cookie 后重启容器 |
| `bash scripts/deploy-meting.sh logs` | 查看容器日志 |
| `bash scripts/deploy-meting.sh down` | 停止并移除容器 |

配置项集中在脚本顶部「配置区」，也可用环境变量临时覆盖：
`DEPLOY_DIR`、`PUBLIC_DOMAIN`、`METING_PORT`、`QQ_COOKIE`、`ENABLE_CACHE`、`ENABLE_AUTH`、`AUTH_SECRET`、`TEST_SERVER`、`TEST_PLAYLIST_ID`。

> 不想用脚本？下面第 1~8 步是**等价的手工流程**，可任选一种。

### 第 1 步：安装 Docker（宝塔）

宝塔面板 →「软件商店」→ 搜索 **Docker**（Docker 管理器）→ 安装。
安装后在「软件商店 → Docker → 配置」里加镜像加速器（国内服务器必做，否则拉 `php:8.2-apache` 会超时）：

```json
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.mirrors.ustc.edu.cn"
  ]
}
```

改完保存并**重启 Docker 服务**，然后验证：

```bash
docker version && docker compose version
```

### 第 2 步：部署目录与源码

```bash
mkdir -p /www/wwwroot/meting && cd /www/wwwroot/meting

# 1) 拉取 meting-api 源码（单一入口 index.php + src/Meting.php，无依赖安装）
git clone --depth 1 https://github.com/injahow/meting-api.git

# 2) 上传本仓库的 Dockerfile 与 docker-compose.yml 到当前目录
#    （宝塔「文件」面板上传，或 scp）
#    最终目录结构：
#    /www/wwwroot/meting/
#    ├── Dockerfile
#    ├── docker-compose.yml
#    └── meting-api/   ← 含 index.php、public/、src/、cache/
```

### 第 3 步：修改 `meting-api/index.php`（两处，见第四节）

打开 `/www/wwwroot/meting/meting-api/index.php`，按第四节改写 `API_URI` 与 Cookie。

### 第 4 步：构建并启动

```bash
cd /www/wwwroot/meting
docker compose up -d --build

# 查看状态 & 日志
docker compose ps
docker compose logs -f --tail=50
```

### 第 5 步：本机自测（先别动博客）

```bash
# 网易云歌单（能返回 JSON 即说明服务活着）
curl -s "http://127.0.0.1:8899/?server=netease&type=playlist&id=14164869977" | head -c 300

# QQ 音乐歌单（验证 Cookie 是否生效，重点看能不能取到 audio/mpeg）
curl -s "http://127.0.0.1:8899/?server=tencent&type=playlist&id=9777005268" | python3 -m json.tool | head -20
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" -L \
  "http://127.0.0.1:8899/?server=tencent&type=url&id=<上一步返回里某一首的 id>"
```

### 第 6 步：宝塔新建站点并反代

1. 「网站 → 添加站点」：域名 `meting.cnyicheng.top`，根目录随意（如 `/www/wwwroot/meting-web`），PHP 选**纯静态**，不建数据库/FTP；
2. 「站点 → 设置 → 反向代理 → 添加反向代理」：
   - 代理名称：`meting`
   - 目标 URL：`http://127.0.0.1:8899`
   - 发送域名：`$host`（**必须**，见第四节）
3. 再把 [`docs/meting/nginx-meting.conf`](./meting/nginx-meting.conf) 的内容合并进站点配置文件（或伪静态），
   用于补齐超时、缓冲、`X-Forwarded-Proto` 等参数；
4. 若面板已经生成了 `location / { proxy_pass ... }`，**不要重复写两份**，把面板生成的那份替换成我们的片段即可；
5. 「站点 → SSL」申请 Let's Encrypt 证书并开启**强制 HTTPS**；
6. DNS 添加 `meting` 的 A 记录指向服务器 IP，云厂商安全组与宝塔防火墙放行 `80/443`。

### 第 7 步：域名可达性验证

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" "https://meting.cnyicheng.top/?server=netease&type=playlist&id=14164869977"

# 确认 CORS 头存在（浏览器 fetch 才不会被拦）
curl -s -D - -o /dev/null "https://meting.cnyicheng.top/?server=netease&type=playlist&id=14164869977" \
  | grep -i "access-control-allow-origin"
```

### 第 8 步：改博客配置（见第六节）并重新构建发布

---

## 四、三个必须改的坑（否则配好了也播不出声）

### 坑 1：`API_URI` 必须写死成 https 域名

`index.php` 默认这样生成对外地址：

```php
function api_uri() {
    return (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? 'https://' : 'http://')
        . $_SERVER['HTTP_HOST'] . strtok($_SERVER['REQUEST_URI'], '?');
}
```

Nginx 反代时 HTTPS 在 Nginx 上终止，容器内 Apache 看到的是 http，
于是播放列表里返回的音频地址会变成 **`http://...`**，被浏览器按混合内容拦截 → **点了没声音**。

**改法（一行，最稳）**：把文件顶部

```php
define('API_URI', api_uri());
```

改成写死对外地址（注意结尾不要带问号，代码内部会拼 `?server=`）：

```php
// 宝塔 Docker 反代 / 独立域名：写死对外 https 地址，避免 HTTPS 判断失效
define('API_URI', 'https://meting.cnyicheng.top/');
```

> 附带好处：路径 B（子路径反代 `https://cnyicheng.top/meting/`）也只需把这里写成 `https://cnyicheng.top/meting/` 即可，不会因为路径变化而错乱。

### 坑 2：反代必须保留 `Host` 头

Nginx 里 `proxy_set_header Host $host;` 不能省，否则 `$_SERVER['HTTP_HOST']` 变成上游主机名，
返回的 `url/pic/lrc` 会指向错误域名。

### 坑 3：QQ 音乐没 Cookie 就一定播不了 VIP 曲目

实测（公共实例、无 Cookie）：同一个 QQ 歌单 4 首里只有 1 首免费曲能拿到 `audio/mpeg`，
其余返回空地址。必须配置 Cookie（见下一节）。

---

## 五、QQ 音乐（tencent）VIP Cookie 配置

`meting-api` 的 `index.php` 里已经预留了设置 Cookie 的位置（默认注释掉了网易云的示例）：

```php
$api = new Meting($server);
$api->format(true);

// 设置cookie
/*if ($server == 'netease') {
    $api->cookie('os=pc; ... MUSIC_U=****** ; __remember_me=true');
}*/
```

### 1. 怎么拿到 QQ 音乐的 Cookie

> **推荐做法**：用 [`scripts/update-meting-cookie.sh`](../scripts/update-meting-cookie.sh) 写入
> `$DEPLOY_DIR/qq-cookie.txt`（模板见 [`docs/meting/qq-cookie.txt.example`](./meting/qq-cookie.txt.example)），
> 脚本会校验字段、备份旧文件、以 600 权限写入，并解析出大致过期时间。
>
> **为什么不用重启**：Cookie 没有写死在 PHP 里 —— compose 把 `qq-cookie.txt` 以只读方式挂进容器，
> `index.php` 每次请求都读取它（即 Dockerfile 注入的 `mizuki-meting:cookie` 段）。
> 因此**覆盖文件 → 刷新页面即生效**（实测：清空文件后未重启即掉回 1/4，恢复后立刻回到 4/4）。
>
> **⚠ 数字 `uin` 是硬要求**：`Meting.php` 用 `preg_match('/uin=(\d+)/')` 取账号，
> 浏览器给出的是 `uin=o1234567890`（带 `o`）匹配不上；若 Cookie 里没有纯数字 `uin`，请在末尾追加 `; uin=你的QQ号`。
>
> **有效期**：通常 1~2 个月（可直接看 Cookie 里的 `psrf_access_token_expiresAt` 时间戳转换）；
> 期间若浏览器退出登录 / 改密码 / 一键退登，会立即失效 → 重新执行一次更新脚本即可。
>
> 下面手工写进 `index.php` 的方式已**不再需要**，仅作原理参考。


1. 电脑浏览器打开 <https://y.qq.com> 并**登录有绿钻/VIP 的账号**；
2. 按 `F12` → `Application / 应用` → 左侧 `Cookies` → `https://y.qq.com`；
3. 至少需要这几项：`uin`（纯数字）、`qm_keyst`、`qqmusic_key`；
   ⚠️ **整条复制有个坑**：浏览器 Cookie 里的 `ct=`（客户端类型，值形如 `11`/`24`）会让 QQ 的
   vkey 接口拒绝下发播放地址 —— 症状是「VIP 曲目拿不到地址」，严重时**连原本能播的免费曲目
   也全部变成 `text/html`**。`scripts/update-meting-cookie.sh` 已内置剔除逻辑（执行时会打印
   「已剔除客户端标识字段 ct=」），所以整条复制也能直接用；若是手工拼接，务必不要带 `ct=`。
4. 拼成一行 `k=v; k=v` 形式，例如：

```
uin=o0123456789; qm_keyst=Q_H_L_xxxxxxxx; qqmusic_key=Q_H_L_xxxxxxxx
```

### 2. 写进 `index.php`

```php
$api = new Meting($server);
$api->format(true);

// 设置cookie：QQ 音乐（tencent）VIP 曲目必须带登录态才有播放地址
if ($server == 'tencent') {
    $api->cookie('uin=o0123456789; qm_keyst=Q_H_L_xxxxxxxx; qqmusic_key=Q_H_L_xxxxxxxx');
}
```

改完重启服务：

```bash
cd /www/wwwroot/meting && docker compose restart
# 或路径 A（PHP 站点）：宝塔 → PHP → 重载，通常改完即时生效
```

### 3. 安全性提醒（务必看）

| 风险 | 说明与建议 |
|---|---|
| Cookie = 账号凭证 | 拿到 `qm_keyst` 等于拿到你的登录态，**不要提交到 Git、不要贴到聊天里** |
| 建议用独立账号 | 有条件就注册一个小号开会员专门给站点用，别用主力账号 |
| Cookie 会过期 | 通常几个月失效；失效后症状是"VIP 曲目又变回空地址"，重新复制一次即可 |
| 只放在你自己的服务器 | 该 Cookie 只存在于服务器上的 `index.php`，不会下发到浏览器（前端只拿到音频直链） |

### 4. 防滥用与「歌单同步」

`index.php` 顶部的开关（`scripts/deploy-meting.sh` 会自动回写这几个值）：

```php
define('CACHE', true);        // 歌单结果文件缓存（减少对 QQ/网易云接口的请求次数）
define('CACHE_TIME', 1800);   // ← 由脚本的 CACHE_TIME 决定，默认 30 分钟
define('AUTH', true);         // 接口签名校验（只作用于 url/pic/lrc）
define('AUTH_SECRET', '改成你自己的随机字符串');
```

**在音乐 App 里改了歌单后，博客怎么同步？**

| 方式 | 操作 | 生效速度 |
|---|---|---|
| 自动 | 什么都不用做 | ≤ `CACHE_TIME`（默认 30 分钟） |
| 立即 | `bash scripts/deploy-meting.sh refresh` | 立刻（清掉服务端歌单缓存，再刷新浏览器页面即可） |

> 博客前端每次打开/刷新页面都会重新请求接口（请求里带 `r=时间戳` 破缓存），
> 所以只要服务端缓存被清掉，**浏览器刷新一下就能看到新歌** —— 既不用重启容器，也不用重建。
>
> 注意：QQ 音乐里**已下架 / 无版权**的曲目接口不会返回，所以接口返回的数量可能少于 App 里显示的总数。

> ✅ 开启 `AUTH` 后**博客前端不需要任何改动**：播放列表响应里的 `url/pic/lrc` 已经自动带上签名参数。
> 若开了 `CACHE`，请保证 `cache/playlist` 目录可写（本仓库的 Dockerfile 已建好并 `chown`）。


---

## 六、博客前端需要改什么

**只有一个文件**：`src/config/musicConfig.ts`

```ts
export const musicPlayerConfig: MusicPlayerConfig = {
	enable: true,
	showFloatingPlayer: true,
	floatingEntryMode: "fab",
	mode: "meting", // ① local → meting
	meting_api:
		"https://meting.cnyicheng.top/?server=:server&type=:type&id=:id&r=:r", // ② 换成你的接口
	id: "9777005268", // ③ 歌单 ID
	server: "tencent", // ④ 平台：tencent / netease / kugou ...
	type: "playlist", // ⑤ 类型：playlist / album / song / artist
};
```

需要注意的实现细节（都已确认过，不用改代码）：

- `musicPlayerStore` 会用 `Date.now()` 替换 `:r` 做缓存穿透；
- `:auth` 占位符会被替换成空串，而 `AUTH` 只校验 `url/pic/lrc`，所以开启签名校验也不影响歌单拉取；
- 接口返回的字段名 `name|title`、`artist|author` 前端都做了兜底兼容；
- 接口不返回 `duration`，前端会在音频加载完成时自动读取真实时长。

改用在线模式后，本地那 4 首（`public/assets/music/**`，共 21MB）及其硬编码歌单条目**已删除**（`LOCAL_PLAYLIST` 已清空）。
若日后要回退到本地模式，把音频放回 `public/assets/music/url/`、封面放回 `public/assets/music/cover/`，再按 `Song` 结构补回条目即可。

---

## 七、验证清单

| # | 验证项 | 命令 / 操作 | 预期 |
|---|---|---|---|
| 1 | 容器活着 | `docker compose ps` | `Up (healthy)` |
| 2 | 本机接口通 | `curl "http://127.0.0.1:8899/?server=netease&type=playlist&id=14164869977"` | 返回 JSON 数组 |
| 3 | QQ Cookie 生效 | 把第 2 步换成 `server=tencent&id=9777005268`，再逐首测 `type=url` | `HTTP 206` + `audio/mpeg` |
| 4 | 外网域名通 | `curl "https://meting.cnyicheng.top/?server=tencent&type=playlist&id=9777005268"` | 返回 JSON |
| 5 | CORS 存在 | `curl -D - -o /dev/null <上面的地址>` | 含 `Access-Control-Allow-Origin: *` |
| 6 | 地址是 https | 检查 JSON 里的 `url` 字段 | 以 `https://meting.cnyicheng.top/` 开头 |
| 7 | 博客生效 | `pnpm dev` 或重新 `bash scripts/deploy-baota.sh` | 悬浮播放器 + 侧边栏音乐组件都能拉到歌单并播放 |

---

## 八、故障排查

| 现象 | 可能原因与处理 |
|---|---|
| 博客里歌单一直转圈 / 控制台 CORS 报错 | 反代层把 `Access-Control-Allow-Origin` 覆盖掉了；检查站点配置里是否又加了一份 `add_header`，删掉自定义那份 |
| 歌曲列表能出来，但点了没声音 | 第 4 节坑 1：JSON 里的 `url` 是 `http://` → 把 `API_URI` 写死为 https 域名 |
| 返回的 `url/pic` 域名不对 | 反代缺少 `proxy_set_header Host $host;` |
| 只有免费曲能播，VIP 曲目空地址 | Cookie 未配置或已过期，重新获取 `qm_keyst` |
| 配了 Cookie 后**连免费曲也不可播**（`url` 全返回 `text/html`） | Cookie 里带了 `ct=`（客户端类型）→ 去掉该字段后重跑 `bash scripts/update-meting-cookie.sh`（脚本已自动剔除并会打印提示）；对照验证见下方「Cookie 字段 A/B 自测」 |
| 返回 `{"error":"unknown playlist id"}` | 歌单 ID 与 `server` 不匹配（如 QQ 歌单 ID 配了 `server=netease`），或歌单被删/设为私密 |
| 接口偶发 502/504 | 平台接口慢，调大 `proxy_read_timeout`（片段里已设 30s），或开启 `CACHE` |
| 容器起不来 | `docker compose logs --tail=100`；常见是镜像拉取失败（配加速器）或 8899 端口被占用 |
| 首页加载变慢 | 播放列表是**客户端异步获取**的，不影响首屏；若确实慢，开启 `CACHE` 把结果缓存到本地文件 |

### Cookie 字段 A/B 自测（定位 `ct` 类问题的方法）

怀疑 Cookie 有问题时，不用重建镜像、不用重启容器，直接把一段对照 PHP 丢进容器执行即可
（`cache/` 目录是挂载出来的，宿主机写文件容器里立刻可见）：

```bash
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/meting-local}"   # 服务器上为 /www/wwwroot/meting
mkdir -p "$DEPLOY_DIR/meting-api/cache"
cat > "$DEPLOY_DIR/meting-api/cache/probe.php" <<'PHP'
<?php
include '/var/www/html/src/Meting.php';
use Metowolf\Meting;

$full = trim(file_get_contents('/var/www/html/qq-cookie.txt'));
$min  = '';
foreach (['uin', 'qm_keyst', 'qqmusic_key'] as $k) {
    if (preg_match('/(?:^|;\s*)' . $k . '=([^;]*)/', $full, $m)) {
        $min .= ($min === '' ? '' : '; ') . $k . '=' . trim($m[1]);
    }
}
foreach (['完整 cookie' => $full, '仅登录三件套' => $min] as $label => $ck) {
    $api = new Meting('tencent');
    $api->format(true);
    $api->cookie($ck);
    $j = json_decode($api->url('001NgljR0RUhy1', 320), true);   // 任取一首 VIP 曲目
    printf("%-16s => %s\n", $label, empty($j['url']) ? '(空地址 ✗)' : '可播 ✓');
}
PHP

docker exec meting php /var/www/html/cache/probe.php
```

实测输出（Cookie 里带 `ct=` 时）：

```
完整 cookie   => (空地址 ✗)
仅登录三件套  => 可播 ✓
```

> 这说明问题出在 **Cookie 字段本身**，而不是账号权限、出网或反代配置。
> 想确定具体是哪个字段，把「完整 cookie」逐个字段剔除后再测，能恢复的那个就是元凶（本项目实测为 `ct`）。

---

## 九、回滚

自建接口是**独立服务**，回滚不影响博客本体：

```bash
# 1) 博客侧：把 musicConfig.ts 改回公共实例或本地模式
#    mode: "local"（本地文件）或 meting_api 换回公共地址

# 2) 服务端：停掉容器（保留数据与源码，随时可再起）
cd /www/wwwroot/meting && docker compose down

# 3) 彻底清理（可选）
docker rmi mizuki-meting:latest
# 宝塔站点 meting.cnyicheng.top 可直接删除，DNS 解析一并清理
```

---

## 十、附：路径 A（宝塔 PHP 站点，不用 Docker）

最贴合你现有面板环境，步骤如下：

1. **装 PHP 环境**：宝塔「软件商店」安装 PHP 8.x（或 7.4），确认扩展里有 `curl`、`openssl`、`bcmath`（前两个默认有，`bcmath` 需在「PHP 设置 → 安装扩展」里装）；
2. **新建站点**：`meting.cnyicheng.top`，根目录 `/www/wwwroot/meting-web`，PHP 版本选刚装的版本；
3. **放源码**：把 meting-api 源码内容解压到站点根目录，确保 `index.php` 直接位于站点根；
4. **改 `index.php`**：同第四节（写死 `API_URI`）+ 第五节（Cookie）；
5. **开目录写入权限**：若启用 `CACHE`，把 `cache` 目录属主设为 `www:www`；
6. **申请 SSL** 并开启强制 HTTPS；
7. **验证**：`curl "https://meting.cnyicheng.top/?server=tencent&type=playlist&id=9777005268"`。

优点：不装 Docker、不需要反代、内存占用更低；
缺点：需要在面板里维护 PHP 扩展，换服务器时要重新配环境。

---

## 十一、附：路径 B（现有站点子路径反代）

不想再申请域名/证书时可用：在**主站** `cnyicheng.top` 的 Nginx 配置里加一段子路径反代。

```nginx
location /meting/ {
    proxy_pass http://127.0.0.1:8899/;          # 注意结尾斜杠：会剥掉 /meting/ 前缀
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 30s;
}
```

同时把 `index.php` 里的 `API_URI` 写死为：

```php
define('API_URI', 'https://cnyicheng.top/meting/');
```

对应前端配置：

```ts
meting_api: "https://cnyicheng.top/meting/?server=:server&type=:type&id=:id&r=:r",
```

> ⚠️ 两个注意点：
> 1. `proxy_pass` 结尾的斜杠决定了 `/meting/` 前缀是否被剥离，写错会 404；
> 2. 主站静态缓存规则里若对 `location /` 做了 `try_files`，要确保 `/meting/` 这段 location 优先级正确（本片段是前缀匹配，放在 `location /` 之前即可）。
> 该方案把动态接口混进了静态站，缓存与安全头更容易互相干扰，故排在最后。

---

## 十二、附：换一台电脑从零部署

> 场景：换了一台电脑（或换了一台服务器），想**只靠仓库里的文件**把音乐服务重新跑起来。

### 1. 仓库里有什么 / 没有什么

| ✅ 已在仓库（`git clone` 即有） | ⚠️ 不在仓库（需自己准备） |
|---|---|
| `docs/meting/Dockerfile`、`docker-compose.yml`、`nginx-meting.conf` | **Docker 镜像源配置**（属机器级设置，见 2.1） |
| `scripts/deploy-meting.sh`、`scripts/update-meting-cookie.sh` | **QQ Cookie**（`qq-cookie.txt` 已被 `.gitignore` 忽略） |
| `docs/DEPLOYMENT_METING.md`（本文） | meting-api 源码 —— 由脚本自动下载，**无需手工准备** |

### 2. 前置条件自检

| 条件 | 检查命令 | 不满足时怎么办 |
|---|---|---|
| Docker + compose v2 | `docker version && docker compose version` | 装 Docker Desktop，或 `apt install docker-compose-plugin` |
| 能拉取 `php:8.2-apache` | `docker pull php:8.2-apache` | 配镜像源（见 2.1）后重启 Docker |
| 能访问 `codeload.github.com` | `curl -sI https://codeload.github.com \| head -1` | 手动下载 release 解压为 `$DEPLOY_DIR/meting-api/` |
| 8899 端口空闲（可改） | macOS：`lsof -i:8899`；Linux：`ss -ltnp \| grep 8899` | 用 `METING_PORT=xxxx` 覆盖 |

#### 2.1 配置 Docker 镜像源（国内常见，一次性）

编辑 `~/.docker/daemon.json`：

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run"
  ]
}
```

改完**重启 Docker**（Docker Desktop 重启 / `sudo systemctl restart docker`），
再用 `docker info --format '{{.RegistryConfig.Mirrors}}'` 确认已生效。

### 3. 三条命令跑起来

```bash
git clone <你的仓库> && cd Mizuki

# ① 本地 / 开发机（http + 回环地址；部署目录会自动回退到 ~/meting-local）
PUBLIC_SCHEME=http PUBLIC_DOMAIN=127.0.0.1:8899 bash scripts/deploy-meting.sh

# ② 服务器（域名 + https；默认部署目录 /www/wwwroot/meting）
PUBLIC_DOMAIN=meting.你的域名 bash scripts/deploy-meting.sh

# ③ 补上 QQ Cookie 之后（VIP 曲目必需）
bash scripts/deploy-meting.sh restart && bash scripts/deploy-meting.sh test
```

> 脚本会自动完成：拉取源码 → 改写 `index.php`（API_URI / 缓存 / Cookie 读取）→ 构建镜像 → 启动容器 → `php -l` 自检 → 逐首探测音频地址。

### 4. 把 QQ Cookie 带到新机器

`qq-cookie.txt` 被 `.gitignore` 忽略，**不会随仓库走**。两种方式：

1. **重新导出（推荐）**：新机器浏览器登录 y.qq.com → DevTools → Network → 任意请求的 `cookie` → 执行
   ```bash
   bash scripts/update-meting-cookie.sh
   ```
2. **手工拷贝**：把旧机器的 `~/meting-local/qq-cookie.txt` 复制到新机器同一路径，并 `chmod 600`

> ⚠️ 不要提交进 Git、不要贴到聊天或截图里（它等于账号登录态）。

### 5. 拉不到 Docker Hub？直接把镜像搬过去

```bash
# 有镜像的机器
docker save mizuki-meting:latest | gzip > mizuki-meting.tar.gz

# 新机器
docker load < mizuki-meting.tar.gz
```

想直接用导入的镜像（不重新构建），二选一：

- 把 `docker-compose.yml` 里的 `build: .` 注释掉（保留 `image: mizuki-meting:latest`）
- 或不用 compose，直接跑：

```bash
docker run -d --name meting -p 127.0.0.1:8899:80 \
  -v "$PWD/meting-api/cache:/var/www/html/cache" \
  -v "$PWD/qq-cookie.txt:/var/www/html/qq-cookie.txt:ro" \
  --restart unless-stopped mizuki-meting:latest
```

> 注意：**镜像里不含 Cookie**（它是运行时挂载的文件），所以 4 的步骤仍要做。

### 6. 常见报错对照

| 报错 | 原因与处理 |
|---|---|
| 构建时 `failed to fetch oauth token ... i/o timeout` | 拉不到基础镜像 → 按 2.1 配镜像源并重启 Docker |
| `mkdir: /www: Read-only file system` | 在非服务器环境用了默认目录 → 现在脚本会自动回退 `~/meting-local`；也可显式指定 `DEPLOY_DIR=...` |
| `✘ 源码获取失败（tarball 与 git 都不通）` | 网络到 GitHub 不通 → 手动把 [meting-api](https://github.com/injahow/meting-api) 源码放到 `$DEPLOY_DIR/meting-api/` |
| 歌单能出来但点了没声音 | `API_URI` 与实际访问地址不一致 → 确认 `PUBLIC_SCHEME` / `PUBLIC_DOMAIN` 传对了 |
| VIP 曲目不可播 | `qq-cookie.txt` 缺失或已过期 → 用 `update-meting-cookie.sh` 更新后 `test` |
| `容器已就绪` 之后自测全不可播、且是 `text/html` | 多半是 Cookie 没生效或 PHP 警告污染响应（本仓库 Dockerfile 已修）→ `bash scripts/deploy-meting.sh logs` |

