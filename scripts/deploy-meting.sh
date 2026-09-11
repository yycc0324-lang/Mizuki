#!/usr/bin/env bash
# ============================================================
# Mizuki 博客 · 自建 Meting 音乐接口一键部署脚本（Docker 版）
# ------------------------------------------------------------
# 用法（在服务器上执行）：
#   bash scripts/deploy-meting.sh            # 构建 + 启动 + 自动自测
#   bash scripts/deploy-meting.sh test       # 只重跑自测（改完歌单/Cookie 后用）
#   bash scripts/deploy-meting.sh refresh    # 改了歌单要立刻同步（清服务端歌单缓存）
#   bash scripts/deploy-meting.sh restart    # 改完 index.php 后重启容器
#   bash scripts/deploy-meting.sh logs       # 查看容器日志
#   bash scripts/deploy-meting.sh down       # 停止并移除容器
#
# 首次使用请按需修改下面的「配置区」。
# ⚠ QQ 音乐 Cookie 请写入 $DEPLOY_DIR/qq-cookie.txt（已加入 .gitignore），
#   不要直接写进本文件后提交到 Git。
# ============================================================
set -euo pipefail

# ----------------------------- 配置区 -----------------------------
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
                                    # 博客源码目录（默认脚本的上级目录）
DEPLOY_DIR="${DEPLOY_DIR:-/www/wwwroot/meting}"
                                    # 音乐服务部署目录（与博客站点目录分开）
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-meting.example.com}"
                                    # ★ 对外域名：会被写进 index.php 的 API_URI，
                                    #   必须是博客前端能访问到的域名（不要带协议前缀）
PUBLIC_SCHEME="${PUBLIC_SCHEME:-https}"
                                    # 对外协议：线上用 https；本地 Docker 联调可设 http
METING_PORT="${METING_PORT:-8899}"  # 宿主机回环端口（只绑 127.0.0.1，不对外）
METING_REPO="${METING_REPO:-https://github.com/injahow/meting-api.git}"
                                    # meting-api 源码仓库（单入口 index.php）
METING_TARBALL="${METING_TARBALL:-https://codeload.github.com/injahow/meting-api/tar.gz/refs/heads/master}"
                                    # 优先使用的 tarball 地址（实测：github.com 的 git 协议
                                    # 在部分网络会超时，而 codeload 正常）
REFRESH_SOURCE="${REFRESH_SOURCE:-true}"
                                    # 每次部署是否重新拉取源码；若你手工改过 index.php
                                    # 且不想被覆盖，设为 false

TEST_SERVER="${TEST_SERVER:-tencent}"               # 自测用平台（tencent / netease）
TEST_PLAYLIST_ID="${TEST_PLAYLIST_ID:-9777005268}"  # 自测用歌单 ID
TEST_NETEASE_ID="${TEST_NETEASE_ID:-14164869977}"   # 自测用网易云歌单（验证出网）

QQ_COOKIE="${QQ_COOKIE:-}"              # QQ 音乐 VIP Cookie；留空则读 qq-cookie.txt
ENABLE_CACHE="${ENABLE_CACHE:-true}"    # 歌单结果文件缓存，减少平台接口压力
CACHE_TIME="${CACHE_TIME:-1800}"        # 歌单缓存时长（秒），默认 30 分钟；
                                        # 在音乐 App 里改完歌单，最多等这么久就会自动同步；
                                        # 想立刻同步请执行：bash scripts/deploy-meting.sh refresh
ENABLE_AUTH="${ENABLE_AUTH:-false}"     # 接口签名校验（只作用于 url/pic/lrc）
AUTH_SECRET="${AUTH_SECRET:-}"          # ENABLE_AUTH=true 时必填
# ------------------------------------------------------------------

# 部署目录解析（兼容两类环境，避免新机器第一次跑就失败）：
#   服务器：/www/wwwroot/meting —— root/www 用户可直接创建
#   本地开发机：/www 通常只读（mkdir 会报 Read-only file system），创建失败则回退到 ~/meting-local
# 注意：这里不能调用 warn()（助手函数在下方才定义），故直接用 echo 输出提示
if [ ! -d "$DEPLOY_DIR" ] && ! mkdir -p "$DEPLOY_DIR" 2>/dev/null; then
	DEPLOY_DIR="$HOME/meting-local"
	echo "⚠ 默认部署目录不可用，已回退到 ${DEPLOY_DIR}（本机开发模式）"
fi

ACTION="${1:-up}"

log()  { echo "✓ $*"; }
info() { echo "ⓘ $*"; }
warn() { echo "⚠ $*"; }
die()  { echo "✘ $*" >&2; exit 1; }

# GNU sed 与 BSD/macOS sed 的 -i 语法不同，这里统一封装
# （宝塔服务器通常是 GNU sed；加上兼容层后本地 macOS 也能直接跑）
if sed --version >/dev/null 2>&1; then
	sed_inplace() { sed -i "$@"; }
else
	sed_inplace() { sed -i '' "$@"; }
fi

# ============================================================
# 1) 依赖检查
# ============================================================
ensure_docker() {
	command -v docker >/dev/null 2>&1 ||
		die "找不到 docker，请先在宝塔「软件商店」安装 Docker 管理器"
	docker info >/dev/null 2>&1 ||
		die "docker 守护进程未运行，请先启动 Docker 服务"
	docker compose version >/dev/null 2>&1 ||
		die "缺少 docker compose 插件（宝塔 Docker 管理器自带；或 apt install docker-compose-plugin）"
	log "docker $(docker version --format '{{.Server.Version}}') / compose 可用"
}

# ============================================================
# 1.5) 获取 meting-api 源码（tarball 优先，git 兜底）
# ------------------------------------------------------------
# 实测：部分网络（含国内服务器）访问 github.com 的 git 协议会直接超时，
#       而 codeload.github.com 的 tarball 正常，因此优先走 tarball。
# ============================================================
fetch_source() {
	local dest="$DEPLOY_DIR/meting-api"
	local tmp_dir extracted

	if [ "$REFRESH_SOURCE" != "true" ] && [ -f "$dest/index.php" ]; then
		info "已存在源码且 REFRESH_SOURCE != true，跳过更新"
		return 0
	fi

	# ① tarball（快，不依赖 git 协议）
	if curl -fsSL --max-time 120 -o /tmp/meting-api.tar.gz "$METING_TARBALL" 2>/dev/null; then
		tmp_dir="$(mktemp -d)"
		if tar xzf /tmp/meting-api.tar.gz -C "$tmp_dir" 2>/dev/null; then
			extracted="$(ls -d "$tmp_dir"/*/ 2>/dev/null | head -1 || true)"
			if [ -n "$extracted" ]; then
				mkdir -p "$dest"
				cp -R "${extracted}." "$dest"/
				rm -rf "$tmp_dir" /tmp/meting-api.tar.gz
				log "已通过 tarball 获取 meting-api 源码"
				return 0
			fi
		fi
		rm -rf "$tmp_dir" /tmp/meting-api.tar.gz
		warn "tarball 解包异常，回退 git clone…"
	else
		warn "tarball 下载失败，回退 git clone…"
	fi

	# ② git 兜底
	command -v git >/dev/null 2>&1 ||
		die "tarball 与 git 都不可用，请手动把 meting-api 源码放到 $dest"
	if [ -d "$dest/.git" ]; then
		git -C "$dest" pull --ff-only || warn "git pull 失败，继续使用现有源码"
	else
		rm -rf "$dest"
		git clone --depth 1 "$METING_REPO" "$dest" ||
			die "源码获取失败（tarball 与 git 都不通），可手动上传 release 包解压为 $dest"
	fi
	log "已通过 git 获取 meting-api 源码"
}

# ============================================================
# 2) 准备部署目录（源码 + 构建文件）
# ============================================================
prepare_dir() {
	mkdir -p "$DEPLOY_DIR"
	cd "$DEPLOY_DIR"

	# 从博客仓库同步我们维护的 Dockerfile / compose / 反代片段
	for f in Dockerfile docker-compose.yml nginx-meting.conf; do
		if [ -f "$PROJECT_DIR/docs/meting/$f" ]; then
			cp -f "$PROJECT_DIR/docs/meting/$f" "$DEPLOY_DIR/$f"
		fi
	done
	[ -f "$DEPLOY_DIR/Dockerfile" ] ||
		die "缺少 Dockerfile（应位于 $PROJECT_DIR/docs/meting/Dockerfile）"
	log "部署目录已就绪：$DEPLOY_DIR"

	# 拉取 / 更新 meting-api 源码
	fetch_source
	mkdir -p "$DEPLOY_DIR/meting-api/cache/playlist"
	log "meting-api 源码就绪"
}

# ============================================================
# 3) 改写 index.php（API_URI / Cookie / 缓存 / 签名）
# ============================================================
patch_index_php() {
	local file="$DEPLOY_DIR/meting-api/index.php"
	[ -f "$file" ] || die "找不到 $file"

	# 3.1 对外地址写死为「协议://域名」
	#     默认的 api_uri() 依赖 $_SERVER['HTTPS']，反代场景下会得到 http://，
	#     返回的音频地址会被浏览器按「混合内容」拦截（列表能出来但没声音）。
	local api_uri
	api_uri="define('API_URI', '$PUBLIC_SCHEME://$PUBLIC_DOMAIN/');"
	if grep -Fq "$api_uri" "$file"; then
		info "API_URI 已是 $PUBLIC_SCHEME://$PUBLIC_DOMAIN/ ，跳过"
	else
		# ① 上游默认写法：define('API_URI', api_uri());
		sed_inplace "s|define('API_URI', api_uri());|$api_uri|" "$file"
		# ② 兼容此前已写死的其它值（换域名/换协议时一并改写）
		if ! grep -Fq "$api_uri" "$file"; then
			sed_inplace "s|define('API_URI', '[^']*');|$api_uri|" "$file"
		fi
		grep -Fq "$api_uri" "$file" || die "API_URI 改写失败，请手动修改 $file"
		log "已写死 API_URI = $PUBLIC_SCHEME://$PUBLIC_DOMAIN/"
	fi

	# 3.2 缓存 / 签名开关
	if [ "$ENABLE_CACHE" = "true" ]; then
		sed_inplace "s|define('CACHE', false);|define('CACHE', true);|" "$file"
		sed_inplace "s|define('CACHE_TIME', [0-9]*);|define('CACHE_TIME', $CACHE_TIME);|" "$file"
		log "已开启歌单文件缓存（CACHE=true，时长 ${CACHE_TIME} 秒）"
	fi
	if [ "$ENABLE_AUTH" = "true" ]; then
		[ -n "$AUTH_SECRET" ] || die "ENABLE_AUTH=true 时必须设置 AUTH_SECRET"
		sed_inplace "s|define('AUTH', false);|define('AUTH', true);|" "$file"
		sed_inplace "s|define('AUTH_SECRET', 'meting-secret');|define('AUTH_SECRET', '$AUTH_SECRET');|" "$file"
		log "已开启接口签名校验（AUTH=true）"
	fi

	# 3.3 登录 Cookie：注入「运行时读文件」逻辑（而不是把 Cookie 写死进代码）
	#     - 好处：Cookie 过期后只需覆盖 $DEPLOY_DIR/qq-cookie.txt，
	#             下一次请求即时生效，不用重启容器、更不用重建镜像
	#     - compose 已把该文件只读挂载到容器内 /var/www/html/qq-cookie.txt
	local cookie_file="$DEPLOY_DIR/qq-cookie.txt"
	[ -f "$cookie_file" ] || : > "$cookie_file"

	if [ -n "${QQ_COOKIE:-}" ]; then
		printf '%s' "$QQ_COOKIE" > "$cookie_file"
		log "已把传入的 Cookie 写入 $cookie_file"
	fi

	if grep -q "mizuki-meting:cookie" "$file"; then
		info "index.php 已包含 Cookie 读取逻辑，跳过注入"
	else
		cat > /tmp/mizuki-meting-cookie.php <<'COOKIEEOF'
/* mizuki-meting:cookie —— 由 scripts/deploy-meting.sh 生成：运行时读取挂载的 qq-cookie.txt */
$__cookie_file = __DIR__ . '/qq-cookie.txt';
if (is_file($__cookie_file)) {
    $__cookie = trim(file_get_contents($__cookie_file));
    if ($__cookie !== '') {
        $api->cookie($__cookie);
    }
}
COOKIEEOF
		sed_inplace "/^\$api->format(true);/r /tmp/mizuki-meting-cookie.php" "$file"
		rm -f /tmp/mizuki-meting-cookie.php
		grep -q "mizuki-meting:cookie" "$file" || die "Cookie 注入失败，请手动修改 $file"
		log "已注入「运行时读取 qq-cookie.txt」的 Cookie 逻辑"
	fi

	# 提示 Cookie 是否可用（需同时含数字 uin 与 qm_keyst/qqmusic_key）
	if grep -qE '(^|[;[:space:]])uin=[0-9]+' "$cookie_file" 2>/dev/null &&
		grep -qE '(qm_keyst|qqmusic_key)=' "$cookie_file" 2>/dev/null; then
		log "检测到可用的登录 Cookie（数字 uin + qm_keyst/qqmusic_key）"
	else
		warn "未检测到可用的 QQ Cookie（需同时含数字 uin 与 qm_keyst）"
		warn "  QQ 音乐 VIP 曲目将拿不到播放地址；配好后无需重启，刷新页面即生效"
	fi
}


# ============================================================
# 4) 构建并启动容器
# ============================================================
compose_up() {
	cd "$DEPLOY_DIR"
	info "构建镜像并启动容器（首次构建需数分钟，取决于网络）…"
	docker compose up -d --build

	# 容器内语法自检：防止 sed 改写把 index.php 改坏
	if docker compose exec -T meting php -l /var/www/html/index.php >/dev/null 2>&1; then
		log "index.php 语法检查通过"
	else
		warn "index.php 语法检查未通过，请执行：docker compose exec meting php -l /var/www/html/index.php"
	fi

	local base="http://127.0.0.1:${METING_PORT}" i
	info "等待服务就绪…"
	for i in $(seq 1 30); do
		if curl -fsS --max-time 5 "$base/?server=netease&type=name&id=416892104" >/dev/null 2>&1; then
			log "容器已就绪：${base}"
			return 0
		fi
		sleep 2
	done
	warn "探测 30 次仍未就绪，请执行：bash scripts/deploy-meting.sh logs"
	return 1
}

# ============================================================
# 5) 自测（确认接口真的能返回可播地址，而不只是「服务活着」）
# ============================================================
run_selftest() {
	local base="http://127.0.0.1:${METING_PORT}"
	local pl total n_net

	echo "── 自测 1/3：服务存活 + 出网能力（网易云公共歌单）"
	n_net="$(curl -fsS --max-time 25 "$base/?server=netease&type=playlist&id=${TEST_NETEASE_ID}" 2>/dev/null |
		grep -o '"name"' | wc -l | tr -d ' ' || true)"
	if [ -z "$n_net" ] || [ "$n_net" = "0" ]; then
		warn "取不到网易云歌单：查容器日志，或确认服务器能否访问外网"
	else
		log "网易云歌单解析成功（${n_net} 首）"
	fi

	echo "── 自测 2/3：目标歌单（server=${TEST_SERVER} / id=${TEST_PLAYLIST_ID}）"
	pl="$(curl -fsS --max-time 30 "$base/?server=${TEST_SERVER}&type=playlist&id=${TEST_PLAYLIST_ID}" 2>/dev/null || true)"
	if [ -z "$pl" ]; then
		warn "目标歌单取不到数据：请检查 id 与 server 是否匹配、歌单是否为公开歌单"
		return 1
	fi
	total="$(printf '%s' "$pl" | grep -o '"name"' | wc -l | tr -d ' ' || true)"
	log "歌单解析成功（${total} 首）"

	echo "── 自测 3/3：逐首探测播放地址（VIP 曲目依赖 Cookie）"
	local ids ok=0 all=0 id ct
	ids="$(printf '%s' "$pl" | grep -o 'type=url&id=[A-Za-z0-9]*' | sed 's/.*id=//' | sort -u || true)"
	for id in $ids; do
		all=$((all + 1))
		ct="$(curl -s -L -o /dev/null -w '%{content_type}' --max-time 25 \
			"$base/?server=${TEST_SERVER}&type=url&id=${id}" || true)"
		case "$ct" in
			audio/*) ok=$((ok + 1)); echo "  ✓ ${id} 可播放（${ct}）" ;;
			*) echo "  ✘ ${id} 不可播放（${ct:-无响应}）" ;;
		esac
	done
	echo "→ 可播放：${ok}/${all}"
	[ "$ok" -gt 0 ] || warn "全部不可播：QQ 音乐需配置 Cookie；网易云需确认歌曲是否下架"
}


# ============================================================
# 6) 收尾提示：宝塔建站 + 前端配置
# ============================================================
print_next_steps() {
	cat <<EOF

────────────────────────────────────────────────────────────
✓ 服务端已完成，接下来在宝塔面板做 3 件事（只需一次）：

1) 新建站点：域名 ${PUBLIC_DOMAIN}，PHP 选「纯静态」，不建库/FTP
2) 站点 → 设置 → 反向代理 → 添加：
     代理名称   meting
     目标 URL   http://127.0.0.1:${METING_PORT}
     发送域名   \$host            ← 必须（否则返回的播放地址域名会错）
   然后把 ${DEPLOY_DIR}/nginx-meting.conf 合并进站点配置（或伪粘贴到「伪静态」）
3) 站点 → SSL → Let's Encrypt 申请证书并开启「强制 HTTPS」

然后外网验证：
   curl -s -D - -o /dev/null "${PUBLIC_SCHEME}://${PUBLIC_DOMAIN}/?server=netease&type=playlist&id=${TEST_NETEASE_ID}" | grep -i access-control

────────────────────────────────────────────────────────────
✓ 博客前端只改一个文件：src/config/musicConfig.ts

   mode: "meting",
   meting_api: "${PUBLIC_SCHEME}://${PUBLIC_DOMAIN}/?server=:server&type=:type&id=:id&r=:r",
   id: "${TEST_PLAYLIST_ID}",
   server: "${TEST_SERVER}",
   type: "playlist",

改完执行：bash scripts/deploy-baota.sh
（**换歌单 = 改上面的 id/server，再重新构建发布一次**；
  同一平台换歌单只改 id；换平台要同时改 server，例如腾讯的 id 配 netease 会返回空歌单）

常用维护命令：
   bash scripts/deploy-meting.sh test     # 改完歌单/Cookie 后重跑自测
   bash scripts/deploy-meting.sh restart  # 改完 index.php 后重启
   bash scripts/deploy-meting.sh logs     # 看日志
   bash scripts/deploy-meting.sh down     # 停服务（博客会自动用不了在线音乐）
────────────────────────────────────────────────────────────
EOF
}

# ============================================================
# 主流程
# ============================================================
case "$ACTION" in
	up)
		ensure_docker
		prepare_dir
		patch_index_php
		compose_up || true
		run_selftest || true
		print_next_steps
		;;
	test)
		run_selftest
		;;
	refresh)
		# 立即同步歌单：清掉服务端文件缓存，下次请求就会重新拉取
		# （博客端不需要重启，浏览器刷新页面即可）
		if [ -d "$DEPLOY_DIR/meting-api/cache/playlist" ]; then
			rm -f "$DEPLOY_DIR"/meting-api/cache/playlist/*.json
			log "已清除歌单缓存（$DEPLOY_DIR/meting-api/cache/playlist）"
		else
			warn "缓存目录不存在：$DEPLOY_DIR/meting-api/cache/playlist"
			warn "  请确认 DEPLOY_DIR 是否正确（本地联调可直接用自动识别，或加 DEPLOY_DIR=\$HOME/meting-local）"
		fi
		run_selftest
		;;
	restart)
		ensure_docker
		cd "$DEPLOY_DIR"
		docker compose restart
		run_selftest || warn "自测未通过，请查看日志：bash scripts/deploy-meting.sh logs"
		;;
	logs)
		cd "$DEPLOY_DIR"
		docker compose logs -f --tail=100
		;;
	down)
		cd "$DEPLOY_DIR"
		docker compose down
		log "已停止 meting 服务（重新启动：bash scripts/deploy-meting.sh）"
		;;
	*)
		die "未知参数：${ACTION}（可用：up / test / refresh / restart / logs / down）"
		;;
esac

