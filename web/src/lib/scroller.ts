/**
 * What the pages scroll in. Touch devices (the phone and tablet app): <main>, not the document. On
 * iOS a tap while the document still coasts from a flick only stops it, wherever it lands, so the tab
 * bar needed a second tap. With the content in its own scroller the bars are outside the coasting
 * scroll view and take the first tap. Desktops keep the document scrolling (Space, Page Down and the
 * arrow keys scroll it without having to focus anything).
 *
 * <main> is fixed to the window (see +layout.svelte), so its top is the window's top and its height
 * the window's height: only where the scroll position is read and set changes.
 */
export const innerScroll = typeof matchMedia !== 'undefined' && matchMedia('(hover: none) and (pointer: coarse)').matches;

/** the layout's <main> (looked up when needed: a page's grid mounts before the layout's actions run) */
const inner = (): HTMLElement | null => (innerScroll ? document.querySelector('main') : null);

export const scroller = {
	get top(): number {
		return inner()?.scrollTop ?? window.scrollY;
	},
	get scrollHeight(): number {
		return (inner() ?? document.documentElement).scrollHeight;
	},
	to(y: number) {
		(inner() ?? window).scrollTo(0, y);
	},
	by(dy: number) {
		(inner() ?? window).scrollBy(0, dy);
	},
	/** Listens to scrolling; returns the remover. */
	onScroll(fn: () => void): () => void {
		const target: EventTarget = inner() ?? window;
		target.addEventListener('scroll', fn, { passive: true });
		return () => target.removeEventListener('scroll', fn);
	}
};
