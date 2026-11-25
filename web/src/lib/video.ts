/** "m:ss" (or "h:mm:ss" from an hour up); fractions of a second are dropped. */
export function formatDuration(seconds: number): string {
	const total = Math.max(0, Math.floor(seconds));
	const h = Math.floor(total / 3600);
	const m = Math.floor((total % 3600) / 60);
	const s = String(total % 60).padStart(2, '0');
	return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
}

/** Large, range-requested media the service worker must leave to the browser (never stored, never wrapped). */
export function isStreamedMedia(pathname: string): boolean {
	return /^\/api\/assets\/[^/]+\/(video|motion|original)$/.test(pathname);
}
