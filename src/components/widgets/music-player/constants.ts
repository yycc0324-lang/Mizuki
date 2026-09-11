import type { Song } from "./types";

export const STORAGE_KEY_VOLUME = "music-player-volume";

export const DEFAULT_VOLUME = 0.7;

// 本地播放列表已清空：项目已改用自建 Meting 在线接口（配置见 src/config/musicConfig.ts）
// 若要回退到本地模式：把音频放到 public/assets/music/url/、封面放到 public/assets/music/cover/，
// 再按 Song 结构（id/title/artist/cover/url/duration）补回条目即可。
export const LOCAL_PLAYLIST: Song[] = [];

export const DEFAULT_SONG: Song = {
	title: "Sample Song",
	artist: "Sample Artist",
	cover: "/favicon/favicon.ico",
	url: "",
	duration: 0,
	id: 0,
};

export const DEFAULT_METING_API =
	"https://www.bilibili.uno/api?server=:server&type=:type&id=:id&auth=:auth&r=:r";
export const DEFAULT_METING_ID = "14164869977";
export const DEFAULT_METING_SERVER = "netease";
export const DEFAULT_METING_TYPE = "playlist";

export const ERROR_DISPLAY_DURATION = 3000;
export const SKIP_ERROR_DELAY = 1000;
