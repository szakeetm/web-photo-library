/**
 * Links in a fixed bar (the phone's tab bar) follow on the finger's lift, not on the click: while the
 * page is still coasting from a flick, iOS spends the first tap on stopping the scroll and sends no
 * click, so the tab needed a second tap. A short tap that stayed in place goes to its link; the
 * click that may still follow is cancelled (preventDefault on touchend), so it never runs twice.
 */
export function tapNav(nav: HTMLElement) {
	let start: { x: number; y: number; t: number; link: HTMLAnchorElement } | null = null;

	const onStart = (e: TouchEvent) => {
		const link = (e.target as Element).closest?.('a[href]') as HTMLAnchorElement | null;
		start = e.touches.length === 1 && link ? { x: e.touches[0].clientX, y: e.touches[0].clientY, t: e.timeStamp, link } : null;
	};
	const onEnd = (e: TouchEvent) => {
		const s = start;
		start = null;
		if (!s || e.changedTouches.length !== 1) return;
		const p = e.changedTouches[0];
		if (Math.hypot(p.clientX - s.x, p.clientY - s.y) > 10 || e.timeStamp - s.t > 600) return;
		e.preventDefault(); // no click of its own after this
		s.link.click(); // the link's handler (a Library filter) and the router, as for a click
	};
	const onCancel = () => (start = null);

	nav.addEventListener('touchstart', onStart, { passive: true });
	nav.addEventListener('touchend', onEnd, { passive: false });
	nav.addEventListener('touchcancel', onCancel);
	return {
		destroy() {
			nav.removeEventListener('touchstart', onStart);
			nav.removeEventListener('touchend', onEnd);
			nav.removeEventListener('touchcancel', onCancel);
		}
	};
}
