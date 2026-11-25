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

/** Display name of a probed codec ("h264" → "H.264"). */
export function codecLabel(codec: string): string {
	const names: Record<string, string> = { h264: 'H.264', hevc: 'HEVC', vp8: 'VP8', vp9: 'VP9', av1: 'AV1', mpeg4: 'MPEG-4', prores: 'ProRes' };
	return names[codec.toLowerCase()] ?? codec.toUpperCase();
}

/** The total length from a `Content-Range: bytes 0-0/12345` header; null when absent or unknown ("*"). */
export function contentRangeTotal(header: string | null): number | null {
	const m = header?.match(/\/(\d+)\s*$/);
	return m ? Number(m[1]) : null;
}

/** "840 KB", "12.4 MB", "1.27 GB". */
export function formatBytes(n: number): string {
	if (n < 1e6) return `${Math.max(1, Math.round(n / 1e3))} KB`;
	if (n < 1e9) return `${(n / 1e6).toFixed(n < 1e8 ? 1 : 0)} MB`;
	return `${(n / 1e9).toFixed(2)} GB`;
}
