/**
 * 配置统一导出入口
 *
 * ================================================================
 * 配置文件索引
 * ================================================================
 *
 * 导出名称                      | 文件                       | 说明
 * ------------------------------+----------------------------+------------------------------
 * siteConfig                    | siteConfig.ts              | 站点核心配置
 * SITE_LANG                     | siteConfig.ts              | 站点语言常量
 * fullscreenWallpaperConfig     | backgroundWallpaper.ts     | 全屏壁纸模式配置
 * navBarConfig                  | navBarConfig.ts            | 导航栏菜单配置
 * profileConfig                 | profileConfig.ts           | 个人资料
 * licenseConfig                 | licenseConfig.ts           | 文章许可协议
 * permalinkConfig               | permalinkConfig.ts         | 固定链接配置
 * expressiveCodeConfig          | expressiveCodeConfig.ts    | 代码块样式
 * commentConfig                 | commentConfig.ts           | 评论系统
 * shareConfig                   | shareConfig.ts             | 分享功能开关
 * announcementConfig            | announcementConfig.ts      | 公告栏
 * musicPlayerConfig             | musicConfig.ts             | 音乐播放器
 * footerConfig                  | footerConfig.ts            | 页脚自定义 HTML
 * sidebarLayoutConfig           | sidebarConfig.ts           | 侧边栏组件布局
 * relatedPostsConfig            | relatedPostsConfig.ts      | 相关文章推荐
 * randomPostsConfig             | randomPostsConfig.ts       | 随机文章推荐
 * widgetConfigs                 | (聚合)                     | 侧边栏 Widget 配置聚合对象
 */

export { announcementConfig } from "./announcementConfig";
export { fullscreenWallpaperConfig } from "./backgroundWallpaper";
export { commentConfig } from "./commentConfig";
export { expressiveCodeConfig } from "./expressiveCodeConfig";
export { footerConfig } from "./footerConfig";
export { licenseConfig } from "./licenseConfig";
export { musicPlayerConfig } from "./musicConfig";
export { navBarConfig } from "./navBarConfig";
export { permalinkConfig } from "./permalinkConfig";
export { profileConfig } from "./profileConfig";
export { randomPostsConfig } from "./randomPostsConfig";
export { relatedPostsConfig } from "./relatedPostsConfig";
export { shareConfig } from "./shareConfig";
export { sidebarLayoutConfig } from "./sidebarConfig";
export { SITE_LANG, siteConfig } from "./siteConfig";

import { announcementConfig } from "./announcementConfig";
import { fullscreenWallpaperConfig } from "./backgroundWallpaper";
import { musicPlayerConfig } from "./musicConfig";
import { profileConfig } from "./profileConfig";
import { randomPostsConfig } from "./randomPostsConfig";
import { relatedPostsConfig } from "./relatedPostsConfig";
import { shareConfig } from "./shareConfig";
import { sidebarLayoutConfig } from "./sidebarConfig";

export const widgetConfigs = {
	profile: profileConfig,
	announcement: announcementConfig,
	music: musicPlayerConfig,
	layout: sidebarLayoutConfig,
	fullscreenWallpaper: fullscreenWallpaperConfig,
	share: shareConfig,
	relatedPosts: relatedPostsConfig,
	randomPosts: randomPostsConfig,
} as const;
