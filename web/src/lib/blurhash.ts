import { decode } from 'blurhash';

const cache = new Map<string, string>();

/** Tiny data-URL placeholder decoded from a BlurHash (memoised). */
export function blurhashUrl(hash: string | null): string | undefined {
	if (!hash || typeof document === 'undefined') return undefined;
	let url = cache.get(hash);
	if (url) return url;
	try {
		const size = 8;
		const pixels = decode(hash, size, size);
		const canvas = document.createElement('canvas');
		canvas.width = canvas.height = size;
		const ctx = canvas.getContext('2d')!;
		const img = ctx.createImageData(size, size);
		img.data.set(pixels);
		ctx.putImageData(img, 0, 0);
		url = canvas.toDataURL();
	} catch {
		return undefined;
	}
	if (cache.size > 5000) cache.clear();
	cache.set(hash, url);
	return url;
}
