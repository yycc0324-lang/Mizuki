<script lang="ts">
import I18nKey from "@i18n/i18nKey";
import { i18n } from "@i18n/translation";
import Icon from "@iconify/svelte";
import { panelManager } from "@utils/panel-manager.js";
import type {
	RainyBannerMode,
	RainyFullscreenMode,
	RainyPrefs,
} from "@utils/rainy-day-options";
import { getStoredRainyPrefs, setRainyPrefs } from "@utils/setting-utils";
import { onMount } from "svelte";

import { rainyDayConfig } from "@/config";

let prefs = $state<RainyPrefs>({
	banner: rainyDayConfig.defaultInBannerMode,
	fullscreen: rainyDayConfig.defaultInFullscreenMode,
});

const bannerOptions: { value: RainyBannerMode; label: I18nKey }[] = [
	{ value: "off", label: I18nKey.rainyOff },
	{ value: "banner", label: I18nKey.rainyBannerOnly },
	{ value: "fullscreen", label: I18nKey.rainyFullscreen },
];

const fullscreenOptions: { value: RainyFullscreenMode; label: I18nKey }[] = [
	{ value: "off", label: I18nKey.rainyOff },
	{ value: "on", label: I18nKey.rainyOn },
];

const bannerIndex = $derived(
	Math.max(
		bannerOptions.findIndex((o) => o.value === prefs.banner),
		0,
	),
);

const anyRainOn = $derived(
	prefs.banner !== "off" || prefs.fullscreen !== "off",
);

function update(patch: Partial<RainyPrefs>) {
	prefs = { ...prefs, ...patch };
	setRainyPrefs(patch);
}

async function togglePanel() {
	await panelManager.closeAllPanelsExcept("rainy-panel");
	await panelManager.togglePanel("rainy-panel");
}

onMount(() => {
	prefs = getStoredRainyPrefs();

	// 其他入口改动偏好时同步（例如控制台或以后新增的面板）
	const sync = () => {
		prefs = getStoredRainyPrefs();
	};
	window.addEventListener("rainy-prefs-change", sync);
	return () => window.removeEventListener("rainy-prefs-change", sync);
});
</script>

{#if rainyDayConfig.showSwitch}
	<div class="relative z-50" role="menu" tabindex="-1">
		<button
			aria-label={i18n(I18nKey.rainySwitch)}
			role="menuitem"
			class="relative btn-plain scale-animation rounded-lg h-11 w-11 active:scale-90 theme-switch-btn"
			id="rainy-switch"
			onclick={togglePanel}
		>
			<Icon icon="material-symbols:rainy" class="text-[1.25rem]"></Icon>
			{#if anyRainOn}
				<span
					class="absolute right-1.5 top-1.5 w-1.5 h-1.5 rounded-full bg-[var(--primary)]"
				></span>
			{/if}
		</button>

		<div
			id="rainy-panel"
			class="absolute transition float-panel-closed top-11 -right-2 pt-5"
		>
			<div class="card-base float-panel w-64 max-w-[80vw] p-4">
				<div
					class="text-sm font-bold text-neutral-900 dark:text-neutral-100 mb-3"
				>
					{i18n(I18nKey.rainySwitch)}
				</div>

				<!-- 横幅壁纸模式：三档滑动 -->
				<div class="mb-4">
					<div class="text-xs text-black/60 dark:text-white/60 mb-2">
						{i18n(I18nKey.rainyBannerMode)}
					</div>
					<div
						class="relative grid grid-cols-3 bg-[var(--btn-regular-bg)] rounded-lg p-1"
					>
						<div
							class="absolute top-1 bottom-1 rounded-md bg-[var(--primary)] transition-transform duration-300 ease-out"
							style={`width: calc((100% - 0.5rem) / 3); transform: translateX(${bannerIndex * 100}%)`}
						></div>
						{#each bannerOptions as option (option.value)}
							<button
								type="button"
								class="relative z-10 h-8 text-xs font-medium rounded-md transition-colors"
								class:text-white={prefs.banner === option.value}
								onclick={() => update({ banner: option.value })}
							>
								{i18n(option.label)}
							</button>
						{/each}
					</div>
				</div>

				<!-- 全屏壁纸模式：两档开关 -->
				<div>
					<div class="text-xs text-black/60 dark:text-white/60 mb-2">
						{i18n(I18nKey.rainyFullscreenMode)}
					</div>
					<button
						type="button"
						role="switch"
						aria-checked={prefs.fullscreen === "on"}
						class="relative w-full h-8 rounded-lg bg-[var(--btn-regular-bg)] p-1 flex items-center"
						onclick={() =>
							update({
								fullscreen: prefs.fullscreen === "on" ? "off" : "on",
							})}
					>
						<span
							class="absolute top-1 bottom-1 left-1 w-[calc(50%-0.25rem)] rounded-md bg-[var(--primary)] transition-transform duration-300 ease-out"
							class:translate-x-full={prefs.fullscreen === "on"}
						></span>
						{#each fullscreenOptions as option (option.value)}
							<span
								class="relative z-10 w-1/2 text-center text-xs font-medium transition-colors"
								class:text-white={prefs.fullscreen === option.value}
							>
								{i18n(option.label)}
							</span>
						{/each}
					</button>
				</div>
			</div>
		</div>
	</div>
{/if}

<style>
	.theme-switch-btn::before {
		transition:
			transform 75ms ease-out,
			background-color 0ms !important;
	}
</style>
