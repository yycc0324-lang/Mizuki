import type { CommentConfig } from "../types/config";
import { SITE_LANG } from "./siteConfig";

// 评论系统配置
export const commentConfig: CommentConfig = {
	enable: true, // 启用评论功能。当设置为 false 时，评论组件将不会显示在文章区域。
	system: "giscus", // 评论系统选择: "twikoo" | "giscus"
	giscus: {
		repo: "yycc0324-lang/Mizuki", // 你的 GitHub 仓库地址，例如 "username/repo"
		repoId: "R_kgDOSoOzmA",
		category: "General",
		categoryId: "DIC_kwDOSoOzmM4C94B1",
		mapping: "pathname",
		strict: "0",
		reactionsEnabled: "1",
		emitMetadata: "1",
		inputPosition: "top",
		theme: "preferred_color_scheme",
		lang: SITE_LANG,
		loading: "lazy",
	},
};
