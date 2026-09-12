#!/usr/bin/env bash
# ============================================================
# Mizuki 博客 · Meting 服务「登录 Cookie」更新脚本
# ------------------------------------------------------------
# 用途：Cookie 过期后（症状：QQ 音乐 VIP 曲目又变回「不可播放」）
#       一条命令把新 Cookie 写进部署目录，刷新页面即生效。
#       —— 不需要重启容器，也不需要重建镜像。
#
# 用法：
#   1) 在浏览器里复制整条 Cookie（DevTools → Network → 任意 y.qq.com 请求
#      → Request Headers → cookie → 右键 Copy value）
#   2) 执行：bash scripts/update-meting-cookie.sh          # 直接读剪贴板（macOS）
#      或    bash scripts/update-meting-cookie.sh -f cookie.txt
#      或    cat cookie.txt | bash scripts/update-meting-cookie.sh
# ============================================================
set -euo pipefail

# ----------------------------- 配置区 -----------------------------
DEPLOY_DIR="${DEPLOY_DIR:-/www/wwwroot/meting}"   # 与 deploy-meting.sh 保持一致
                                                     # 本地测试可 DEPLOY_DIR=$HOME/meting-local
# ------------------------------------------------------------------

log()  { echo "✓ $*"; }
info() { echo "ⓘ $*"; }
warn() { echo "⚠ $*"; }
die()  { echo "✘ $*" >&2; exit 1; }

COOKIE_FILE="$DEPLOY_DIR/qq-cookie.txt"
SRC_FILE=""

# ---------- 1) 读取 Cookie 内容 ----------
while [ $# -gt 0 ]; do
	case "$1" in
		-f | --file)
			[ -n "${2:-}" ] || die "用法：$0 -f <cookie.txt>"
			SRC_FILE="$2"
			shift 2
			;;
		-h | --help)
			sed -n '2,20p' "$0"
			exit 0
			;;
		*)
			die "未知参数：$1（可用：-f <file> / -h）"
			;;
	esac
done

raw=""
if [ -n "$SRC_FILE" ]; then
	[ -f "$SRC_FILE" ] || die "文件不存在：$SRC_FILE"
	raw="$(cat "$SRC_FILE")"
elif [ ! -t 0 ]; then
	raw="$(cat)"
elif command -v pbpaste >/dev/null 2>&1; then
	raw="$(pbpaste)"
elif command -v xclip >/dev/null 2>&1; then
	raw="$(xclip -selection clipboard -o)"
else
	die "无法读取剪贴板，请用 -f <cookie.txt> 指定文件，或用管道输入"
fi

# 去掉注释行、换行与首尾空白（Cookie 必须是一行）
cookie="$(printf '%s' "$raw" | grep -v '^[[:space:]]*#' | tr -d '\r\n' |
	sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
[ -n "$cookie" ] || die "Cookie 内容为空（剪贴板里没有东西？）"

# ---------- 1.5) 剔除会破坏鉴权的客户端标识字段 ----------
# 实测（容器内 A/B 对照，详见 docs/DEPLOYMENT_METING.md 第八节故障排查）：
#   浏览器「整条复制」拿到的 Cookie 里含 `ct=`（客户端类型，值形如 11/24），
#   它会让 QQ 音乐的 vkey 接口拒绝下发播放地址 ——
#   现象：VIP 曲目拿不到地址；严重时连原本能播的免费曲目也全部变成 text/html。
#   逐个字段剔除的对照测试中，只有去掉 `ct` 能恢复，把它加回最小集合即立刻复现。
# 因此这里统一剔除客户端标识字段，登录凭证（uin / qm_keyst / qqmusic_key / psrf_*）全部保留。
had_ct=0
if printf '%s' "$cookie" | grep -qE '(^|;[[:space:]]*)ct='; then
	had_ct=1
fi
cookie="$(printf '%s' "$cookie" | tr ';' '\n' |
	sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
	grep -v '^$' | grep -vE '^ct=' | paste -sd';' - | sed 's/;/; /g')"
[ -n "$cookie" ] || die "剔除 ct 字段后 Cookie 变空了，请检查复制的内容"
if [ "$had_ct" = "1" ]; then
	log "已剔除客户端标识字段 ct=（保留它会导致 QQ 拒绝下发播放地址）"
fi

# ---------- 2) 校验关键字段 ----------
ok=1
if printf '%s' "$cookie" | grep -qE '(^|[;[:space:]])uin=[0-9]+'; then
	log "含数字形式 uin（Meting.php 用它取 vkey）"
elif printf '%s' "$cookie" | grep -qE '(^|[;[:space:]])uin=o[0-9]+'; then
	warn "只找到 uin=o…（带 o 前缀），Meting.php 的正则匹配不到纯数字 uin"
	warn "  解决：在 Cookie 末尾追加「; uin=你的QQ号」（纯数字）后重跑本脚本"
	ok=0
else
	warn "未找到 uin 字段"
	ok=0
fi
if printf '%s' "$cookie" | grep -q 'qm_keyst='; then
	log "含 qm_keyst（登录凭证）"
else
	warn "未找到 qm_keyst —— QQ 音乐 VIP 曲目会拿不到播放地址"
	ok=0
fi

# ---------- 3) 备份并写入 ----------
mkdir -p "$DEPLOY_DIR"
if [ -f "$COOKIE_FILE" ] && [ -s "$COOKIE_FILE" ]; then
	bak="$COOKIE_FILE.bak-$(date +%Y%m%d-%H%M%S)"
	cp "$COOKIE_FILE" "$bak"
	chmod 600 "$bak"
	info "旧 Cookie 已备份：$bak"
fi
printf '%s\n' "$cookie" > "$COOKIE_FILE"
chmod 600 "$COOKIE_FILE"
log "已写入 ${COOKIE_FILE}（权限 600，长度 $(wc -c < "$COOKIE_FILE" | tr -d ' ') 字节）"

# ---------- 4) 解析有效期（psrf_access_token_expiresAt 是 Unix 时间戳）----------
exp="$(printf '%s' "$cookie" | grep -oE 'psrf_access_token_expiresAt=[0-9]+' | head -1 | cut -d= -f2 || true)"
if [ -n "$exp" ]; then
	if date -r "$exp" '+%Y-%m-%d %H:%M' >/dev/null 2>&1; then
		info "由 psrf_access_token_expiresAt 推算：约在 $(date -r "$exp" '+%Y-%m-%d %H:%M') 过期（以实际服务端为准）"
	else
		info "由 psrf_access_token_expiresAt 推算：约在 $(date -d "@$exp" '+%Y-%m-%d %H:%M') 过期（以实际服务端为准）"
	fi
fi

# ---------- 5) 结论 ----------
echo
if [ "$ok" = "1" ]; then
	log "完成。**无需重启容器**，博客页面刷新一下即可生效。"
	info "验证：bash scripts/deploy-meting.sh test"
else
	warn "写入完成，但字段校验未全部通过，VIP 曲目可能仍然不可播（见上方提示）"
	info "验证：bash scripts/deploy-meting.sh test"
fi
