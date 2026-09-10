#!/usr/bin/env bash
# ============================================================
# Mizuki 博客 · 宝塔面板一键构建 + 发布脚本
# ------------------------------------------------------------
# 用法：
#   1) 直接在宝塔终端执行：bash scripts/deploy-baota.sh
#   2) 宝塔 → 计划任务 / WebHook 里执行上面的命令，实现更新即发布
#
# 首次使用请按需修改下面的「配置区」
# ============================================================
set -euo pipefail

# ----------------------------- 配置区 -----------------------------
# 均可通过环境变量临时覆盖，例如：
#   SITE_DIR=/tmp/test-web bash scripts/deploy-baota.sh
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
                                    # 源码目录（默认脚本的上级目录）
SITE_DIR="${SITE_DIR-/www/wwwroot/mizuki-web}"
                                    # 网站根目录（= 宝塔的「部署目录 + 运行目录」）：
                                    #   填路径 → 构建产物会 rsync 同步到这里（推荐）
                                    #   留空   → SITE_DIR="" 或 SITE_DIR= 直接用 $PROJECT_DIR/dist
                                    #           （此时宝塔的部署目录应填 .../mizuki/dist）
                                    #   注意：重建期间 Astro 会清空 dist，独立目录可避免空窗
WEB_USER="${WEB_USER:-www}"         # 宝塔站点属主，一般就是 www
NODE_BIN_DIR="${NODE_BIN_DIR:-}"    # 如 /www/server/nodejs/v22.18.0/bin；留空自动探测
MEM_LIMIT="${MEM_LIMIT:-2048}"      # Node 构建内存上限(MB)，1~2G 内存机器保持 2048
# ------------------------------------------------------------------

cd "$PROJECT_DIR"

# 1) 定位 node / pnpm -------------------------------------------------
#    宝塔「Node.js 版本管理器」安装的 node 不在默认 PATH 中，需要显式加入
if [ -z "$NODE_BIN_DIR" ]; then
	NODE_BIN_DIR="$(ls -d /www/server/nodejs/v*/bin 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -n "$NODE_BIN_DIR" ] && [ -d "$NODE_BIN_DIR" ]; then
	export PATH="$NODE_BIN_DIR:$PATH"
fi

command -v node >/dev/null 2>&1 || {
	echo "✘ 找不到 node，请先在宝塔「软件商店」安装 Node.js 版本管理器（需 >= 22）"
	exit 1
}
# package.json 的 preinstall 是 only-allow pnpm，本项目只能用 pnpm 安装依赖
command -v pnpm >/dev/null 2>&1 || {
	echo "✘ 找不到 pnpm，请执行：npm i -g pnpm@11.1.3"
	exit 1
}
echo "✓ node $(node -v) / pnpm $(pnpm -v)"

# 2) 安装依赖 ---------------------------------------------------------
pnpm install --frozen-lockfile

# 3) 构建 -------------------------------------------------------------
#    pnpm build 的第一步会跑 scripts/update-anime.mjs，
#    它可能因服务器网络受限或接口异常而中断整条构建链，这里做一次回退。
if ! NODE_OPTIONS="--max-old-space-size=$MEM_LIMIT" pnpm build; then
	echo "⚠ 完整构建失败，回退为纯 astro build（跳过番剧数据抓取）…"
	NODE_OPTIONS="--max-old-space-size=$MEM_LIMIT" pnpm exec astro build
	pnpm exec pagefind --site dist
	pnpm exec node scripts/compress-fonts/index.js || true
fi

[ -f dist/index.html ] || {
	echo "✘ 构建产物缺失：$PROJECT_DIR/dist/index.html"
	exit 1
}

# 4) 发布到站点目录 ---------------------------------------------------
if [ -n "$SITE_DIR" ]; then
	if ! mkdir -p "$SITE_DIR" 2>/dev/null; then
		echo "✘ 无法创建/访问网站根目录：$SITE_DIR"
		echo "  请确认路径正确，且当前用户（宝塔计划任务为 root）有写权限；"
		echo "  或改成宝塔站点已存在的网站目录。"
		exit 1
	fi
	if command -v rsync >/dev/null 2>&1; then
		# 排除 .user.ini，避免删掉宝塔「防跨站攻击」生成的配置文件
		rsync -a --delete --exclude='.user.ini' dist/ "$SITE_DIR/"
	else
		find "$SITE_DIR" -mindepth 1 -maxdepth 1 ! -name '.user.ini' -exec rm -rf {} +
		cp -a dist/. "$SITE_DIR/"
	fi
	TARGET_DIR="$SITE_DIR"
else
	TARGET_DIR="$PROJECT_DIR/dist"
fi

# 5) 权限（宝塔站点属主通常是 www）-------------------------------------
#    仅 root 执行时才调整属主：宝塔的「计划任务」默认以 root 运行；
#    普通用户执行会 chown 失败，此处直接跳过，避免被 set -e 中断。
if [ "$(id -u)" = "0" ]; then
	if id "$WEB_USER" >/dev/null 2>&1; then
		chown -R "$WEB_USER:$WEB_USER" "$TARGET_DIR" 2>/dev/null ||
			echo "⚠ chown 失败，请检查站点目录属主"
		find "$TARGET_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
		find "$TARGET_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
		echo "✓ 已将 $TARGET_DIR 的属主设置为 $WEB_USER"
	else
		echo "ⓘ 系统中不存在用户 $WEB_USER，跳过属主调整"
	fi
else
	echo "ⓘ 当前非 root 用户，跳过属主/权限调整（宝塔计划任务默认以 root 运行）"
fi

echo "✓ 发布完成：$TARGET_DIR"
du -sh "$TARGET_DIR"
