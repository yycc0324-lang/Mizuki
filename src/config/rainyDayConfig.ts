import type { RainyDayConfig } from "../types/config";

/**
 * 横幅「雨滴窗口」特效配置（雨滴落在窗户玻璃上的 WebGL 效果）
 *
 * 实现说明：
 *   - 由 src/components/common/RainyDay.astro 渲染容器与客户端脚本
 *   - 由 src/components/layout/Banner.astro 在首页横幅内挂载（Banner 在 <main> 之外，
 *     而 Swup 只替换 <main>，所以切页不会重建、无需处理 swup 生命周期）
 *   - 背景图直接复用横幅图片（见 Banner 传入的 images），无需额外素材
 *   - Three.js 通过动态 import 懒加载，不进首屏
 *
 * 关闭方式：把 enable 改为 false 即可完全恢复原样（水波纹会自动回来）
 */
export const rainyDayConfig: RainyDayConfig = {
	enable: true, // 总开关
	// 首次访问时的雨滴偏好（用户可在导航栏「雨滴」按钮的面板里随时切换，选择会记进浏览器 localStorage）
	// 横幅模式下雨："off" 无雨 | "banner" 仅横幅内 | "fullscreen" 横幅内 + 征文区都下雨
	//   "fullscreen" 会挂两层：横幅区 = 横幅图 + 雨；征文区 = 页面背景色 + 雨
	//   （征文区底层不铺图片、卡片文字不受影响；两层互不干扰，横幅图片与水波纹都完好）
	defaultInBannerMode: "banner",
	defaultInFullscreenMode: "on", // 全屏壁纸模式下雨："off" 无雨 | "on" 有雨
	showSwitch: true, // 是否在导航栏显示「雨滴」按钮
	bgFadeMs: 500, // 轮播换图时雨层淡出→换图→淡入的时长（毫秒；0 = 直接切换）
	lazyMount: true, // 延后到 load + 浏览器空闲再挂载（首屏少下 117KB gzip 的 Three.js；雨约 1 秒后淡入）
	idleDelayMs: 2500, // idle 兜底超时（毫秒）：最迟这么久一定挂载
	fadeInMs: 600, // 挂载完成后的淡入时长（毫秒；0 = 不淡入）
	skipOnSlowNetwork: true, // 弱网/省流（saveData / 2G）不加载雨特效

	// 效果参数（可自行微调）
	intensity: 0.2, // 雨滴密度：0.3 稀疏、0.5 适中、0.8 密集
	speed: 1, // 下落速度：0.2 缓慢、0.5 中速
	brightness: 0.9, // 亮度
	normal: 1.0, // 法线强度（雨滴立体感）
	zoom: 2, // 缩放（背景图放大比例）
	blurIntensity: 0.2, // 玻璃模糊（建议 0-1，太大会糊掉背景）
	blurIterations: 12, // 模糊迭代（越小越快）
	lightning: false, // 闪电（想要戏剧性可开）
	panning: false, // 镜头平移
	postProcessing: true, // 后处理
	fps: 30, // 限帧，省电关键

	// 行为开关
	disableOnMobile: true, // 移动端默认不启用
	respectReducedMotion: true, // 系统开了「减少动态效果」就不渲染
	autoDisableWaves: false, // 雨窗开启时是否关闭横幅水波纹（false = 两者叠加共存）
	pauseWhenHidden: true, // 切到别的标签页时暂停渲染
	lazy: true, // 懒加载 Three.js

	// 调试接口：开启后可在浏览器控制台实时调参（调好后请把数值写回本文件，并把此项改为 false）
	//   setRainyOptions({ intensity: 0.8 })                  // 改单个/多个参数，立即生效
	//   setRainyOptions({ speed: 0.4, blurIntensity: 0.6 })  // 批量
	//   setRainyOptions({ lightning: true })                 // 开闪电
	//   setRainyOptions({ backgroundImage: "/assets/desktop-banner/2.webp" }) // 换背景（视频会自动走 loadVideo）
	//   getRainyOptions()                                    // 查看当前全部参数
	//   getRainyDebug()                                      // 查看当前挂了哪些雨层、各自用什么背景
	//   __rainyDay.pause() / __rainyDay.resume() / __rainyDay.destroy()
	//   参数范围：intensity 0-1、speed 0-10、brightness 0-1、normal 0-3、zoom 0.1-3、
	//            blurIntensity 0-10、blurIterations 1-64、fps 15-120（越界会被自动裁剪并提示）
	debug: true,
};
