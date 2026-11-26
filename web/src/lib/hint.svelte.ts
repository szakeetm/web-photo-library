// A short message at the bottom of the screen that goes away by itself (e.g. why a shortcut did nothing).
const SHOW_MS = 3500;

class Hint {
	text = $state<string | null>(null);
	private timer: ReturnType<typeof setTimeout> | undefined;

	show(text: string, ms = SHOW_MS) {
		clearTimeout(this.timer);
		this.text = text;
		this.timer = setTimeout(() => (this.text = null), ms);
	}

	dismiss() {
		clearTimeout(this.timer);
		this.text = null;
	}
}

export const hint = new Hint();
