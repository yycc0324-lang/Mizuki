/**
 * 图片重压脚本（把仓库里的图片统一压到合理规格）
 *
 * 背景（实测）：
 *   - public/assets/desktop-banner/3.webp 是 6400×3396（6K）874KB —— 显示区最多 2560 宽，
 *     解码后约 87MB 位图，低端机上代价极高
 *   - src/content/posts/guide/cover.webp 是 4096×2891 / 1.3MB，卡片实际显示宽 ≤ 700px
 *   - logo.png 772×254 / 267KB（bpp 11.1，典型未优化 PNG）
 *   - src/assets/images/avatar.webp 其实是 PNG 编码的 1025² / 497KB
 *
 * 用法：
 *   node scripts/optimize-images.mjs --dry-run   # 只报告，不改文件
 *   node scripts/optimize-images.mjs             # 执行（自动备份原图到 .image-backup/）
 *
 * 说明：
 *   - 保持原文件名/扩展名（WebP 仍是 WebP），避免改动 siteConfig / backgroundWallpaper /
 *     album-scanner 里的引用路径
 *   - 只有"变小了"才覆盖；变大的跳过
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { glob } from "glob";
import sharp from "sharp";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, "..");
const backupDir = path.join(root, ".image-backup");
const dryRun = process.argv.includes("--dry-run");

/** 规则：glob → 目标最大宽度 + 编码参数（顺序即优先级，先匹配者生效） */
const RULES = [
	// 桌面横幅：统一 ≤2560 宽
	{ glob: "public/assets/desktop-banner/*.webp", maxWidth: 2560, quality: 78 },
	// 移动横幅：保持 1000 宽
	{ glob: "public/assets/mobile-banner/*.webp", maxWidth: 1000, quality: 78 },
	// 相册/日记/图集：≤1600 宽
	{ glob: "public/images/**/*.{webp,jpg,jpeg,png}", maxWidth: 1600, quality: 78 },
	// 文章封面：≤1600 宽
	{ glob: "src/content/**/cover.{webp,jpg,jpeg,png}", maxWidth: 1600, quality: 78 },
	// 主题用图（头像等）：≤512
	{ glob: "src/assets/**/*.{webp,jpg,jpeg,png}", maxWidth: 512, quality: 82 },
	// 纯图形 PNG（logo 之类）：调色板量化 + 高压缩
	{ glob: "logo.png", maxWidth: 512, quality: 70, palette: true },
];

function fmt(bytes) {
	return `${(bytes / 1024).toFixed(0)}KB`;
}

async function encode(file, rule) {
	const meta = await sharp(file).metadata();
	const needResize = (meta.width ?? 0) > rule.maxWidth;
	let img = sharp(file);
	if (needResize) {
		img = img.resize({ width: rule.maxWidth, withoutEnlargement: true });
	}
	const ext = path.extname(file).toLowerCase();
	if (ext === ".png") {
		return img
			.png({
				palette: rule.palette ?? true,
				quality: rule.quality,
				compressionLevel: 9,
				effort: 10,
			})
			.toBuffer();
	}
	if (ext === ".jpg" || ext === ".jpeg") {
		return img.jpeg({ quality: rule.quality + 4, mozjpeg: true }).toBuffer();
	}
	// WebP（默认）：照片用 smartSubsample 提升观感
	return img
		.webp({ quality: rule.quality, effort: 6, smartSubsample: true })
		.toBuffer();
}

async function main() {
	const seen = new Set();
	const tasks = [];
	for (const rule of RULES) {
		const files = await glob(rule.glob, { cwd: root, absolute: true, nodir: true });
		for (const f of files) {
			if (seen.has(f)) continue; // 先匹配的规则优先
			seen.add(f);
			tasks.push({ file: f, rule });
		}
	}

	console.log(`待处理 ${tasks.length} 个文件${dryRun ? "（dry-run，不会改动）" : ""}\n`);
	console.log(
		"文件".padEnd(56),
		"尺寸".padEnd(13),
		"现在".padEnd(9),
		"压后".padEnd(9),
		"省",
	);

	let savedTotal = 0;
	const changed = [];
	for (const { file, rule } of tasks) {
		const rel = path.relative(root, file);
		try {
			const before = fs.statSync(file).size;
			const meta = await sharp(file).metadata();
			const out = await encode(file, rule);
			const dims = `${meta.width}x${meta.height}`;
			const gain = before - out.length;
			const pct = ((gain / before) * 100).toFixed(0);
			const mark = gain > 0 ? `-${pct}%` : "跳过(未变小)";
			console.log(
				rel.slice(0, 55).padEnd(56),
				dims.padEnd(13),
				fmt(before).padEnd(9),
				fmt(out.length).padEnd(9),
				mark,
			);
			if (gain > 0) {
				savedTotal += gain;
				changed.push({ file, out });
			}
		} catch (err) {
			console.log(`${rel}  ❌ ${err.message}`);
		}
	}

	console.log(
		`\n合计可省 ${(savedTotal / 1024 / 1024).toFixed(2)} MB（${changed.length} 个文件）`,
	);
	if (dryRun || changed.length === 0) return;

	// 备份 + 覆盖
	fs.mkdirSync(backupDir, { recursive: true });
	for (const { file, out } of changed) {
		const rel = path.relative(root, file);
		const bak = path.join(backupDir, rel);
		fs.mkdirSync(path.dirname(bak), { recursive: true });
		if (!fs.existsSync(bak)) fs.copyFileSync(file, bak);
		fs.writeFileSync(file, out);
	}
	console.log(`原图已备份到 ${path.relative(root, backupDir)}/（已加入 .gitignore）`);
}

await main();
