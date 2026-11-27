// The marker for "where this photo was taken" (Places when opened from a photo, the info panel's
// small map): a red map pin, so it can't be taken for the blue "you are here" dot of map apps.
// Place it with MapLibre's `anchor: 'bottom'` so the pin's tip is on the spot.

const SVG = `<svg width="28" height="40" viewBox="0 0 28 40" aria-hidden="true">
	<path d="M14 39C14 39 2 23.5 2 14a12 12 0 0 1 24 0c0 9.5-12 25-12 25z" fill="#ea4335" stroke="#a52714" stroke-width="1.5"/>
	<circle cx="14" cy="14" r="4.5" fill="#fff"/>
</svg>`;

export function mapPinElement(): HTMLElement {
	const el = document.createElement('div');
	el.innerHTML = SVG;
	el.setAttribute('aria-hidden', 'true');
	// over the photo pins, never catching taps meant for the map
	Object.assign(el.style, { pointerEvents: 'none', filter: 'drop-shadow(0 2px 3px rgba(0,0,0,0.35))', lineHeight: '0' });
	return el;
}
