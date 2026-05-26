export interface PioConfig {
	enable: boolean;
	mode?: string;
	hiddenOnMobile?: boolean;
	hideAboutMenu?: boolean;
	position?: "left" | "right";
	width?: number;
	height?: number;
	dialog?: Record<string, string>;
	models?: string[];
	tips?: {
		welcomeMessage?: string[];
		messages?: string[];
		duration?: number;
		interval?: number;
	};
	menus?: {
		items?: {
			icon?: string;
			label: string;
			action: string;
		}[];
		align?: "left" | "right";
	};
}

export interface PioProps {
	config?: Partial<PioConfig>;
}
