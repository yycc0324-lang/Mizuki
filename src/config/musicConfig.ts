import type { MusicPlayerConfig } from "../types/config";

// 音乐播放器配置
export const musicPlayerConfig: MusicPlayerConfig = {
	enable: true, // 启用音乐播放器功能
	showFloatingPlayer: true, // 显示悬浮播放器 UI
	floatingEntryMode: "fab", // 悬浮入口模式："default" 为独立悬浮播放器，"fab" 为集成到通用 FAB 组
	mode: "meting", // 音乐播放器模式，可选 "local" 或 "meting"
	meting_api:
		"http://127.0.0.1:8899/?server=:server&type=:type&id=:id&r=:r", // 本地自建 Meting 服务（见 docs/DEPLOYMENT_METING.md）
	id: "9777005268", // 歌单ID（QQ 音乐）
	server: "tencent", // 音乐源服务器。有的meting的api源支持更多平台,一般来说,netease=网易云音乐, tencent=QQ音乐, kugou=酷狗音乐, xiami=虾米音乐, baidu=百度音乐
	type: "playlist", // 播单类型
};
