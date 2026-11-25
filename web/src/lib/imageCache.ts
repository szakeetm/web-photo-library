// Device image cache: bytes live in Cache Storage, bookkeeping (size, last access, pins) in IndexedDB.
// Used by both the service worker (caching what the app views) and the page (downloads, eviction).
import { db, type ImageEntry } from './db';

export const IMAGE_CACHE = 'images-v1';
export const DEFAULT_LIMIT = 2 * 1024 ** 3;

/** Thumbnails and previews are cacheable; originals and exports are not. */
export function isCacheableImage(pathname: string) {
	return pathname.startsWith('/api/thumb/') || pathname.startsWith('/api/preview/') || /^\/api\/faces\/\d+\/thumb$/.test(pathname);
}

/** Index key for a request URL: path + query, origin dropped. */
export function imageKey(url: string | URL) {
	const u = typeof url === 'string' ? new URL(url, 'http://x') : url;
	return u.pathname + u.search;
}

function absolute(key: string) {
	return new URL(key, self.location.origin).href;
}

/** The server couldn't be reached (as opposed to refusing one photo). */
export class NetworkError extends Error {
	constructor() {
		super('The server is unreachable.');
	}
}

/** Records a freshly cached image (keeps existing pins). */
export async function recordImage(key: string, bytes: number, pin?: number) {
	const d = await db();
	const tx = d.transaction('images', 'readwrite');
	const prev = await tx.store.get(key);
	const pins = new Set(prev?.pins ?? []);
	if (pin != null) pins.add(pin);
	await tx.store.put({ url: key, bytes, lastAccess: Date.now(), pins: [...pins] });
	await tx.done;
}

/** Marks images as just used. */
export async function touchImages(keys: Iterable<string>) {
	const d = await db();
	const tx = d.transaction('images', 'readwrite');
	const now = Date.now();
	for (const key of keys) {
		const e = await tx.store.get(key);
		if (e) tx.store.put({ ...e, lastAccess: now });
	}
	await tx.done;
}

/**
 * Fetches `key` into the cache (unless already there) and pins it to `albumId`.
 * Returns the image's size, or throws when the network fails.
 */
export async function cacheAndPin(key: string, albumId: number): Promise<number> {
	const d = await db();
	const cache = await caches.open(IMAGE_CACHE);
	const existing = await d.get('images', key);
	if (existing && (await cache.match(absolute(key)))) {
		if (!existing.pins.includes(albumId)) await d.put('images', { ...existing, pins: [...existing.pins, albumId] });
		return existing.bytes;
	}
	let res: Response;
	try {
		res = await fetch(key, { headers: { 'X-Client-Cache': 'pin' } });
	} catch {
		throw new NetworkError();
	}
	// 502–504 without our version header: Tailscale reached the Mac but not the server.
	if (res.status >= 502 && res.status <= 504 && !res.headers.get('X-API-Version')) throw new NetworkError();
	if (!res.ok) throw new Error(`HTTP ${res.status}`);
	const blob = await res.blob();
	await cache.put(absolute(key), new Response(blob, { headers: { 'content-type': res.headers.get('content-type') ?? '' } }));
	await recordImage(key, blob.size, albumId);
	return blob.size;
}

/** Removes `albumId` from every image except those in `keep`. */
export async function releasePins(albumId: number, keep: Set<string> = new Set()) {
	const d = await db();
	const tx = d.transaction('images', 'readwrite');
	let cursor = await tx.store.openCursor();
	while (cursor) {
		const e = cursor.value;
		if (e.pins.includes(albumId) && !keep.has(e.url)) cursor.update({ ...e, pins: e.pins.filter((p) => p !== albumId) });
		cursor = await cursor.continue();
	}
	await tx.done;
}

/** Which unpinned entries to drop (least recently used first) to get under `limit` bytes. */
export function chooseEvictions(entries: ImageEntry[], limit: number): string[] {
	let total = entries.reduce((s, e) => s + e.bytes, 0);
	if (total <= limit) return [];
	const out: string[] = [];
	const candidates = entries.filter((e) => e.pins.length === 0).sort((a, b) => a.lastAccess - b.lastAccess);
	for (const e of candidates) {
		if (total <= limit) break;
		out.push(e.url);
		total -= e.bytes;
	}
	return out;
}

/** Deletes unpinned entries among `keys` (pins are re-checked: an album may have pinned one meanwhile). */
async function deleteEntries(keys: string[]) {
	if (!keys.length) return;
	const cache = await caches.open(IMAGE_CACHE);
	const d = await db();
	const tx = d.transaction('images', 'readwrite');
	const deleted: string[] = [];
	for (const k of keys) {
		const e = await tx.store.get(k);
		if (e && e.pins.length === 0) {
			tx.store.delete(k);
			deleted.push(k);
		}
	}
	await tx.done;
	await Promise.all(deleted.map((k) => cache.delete(absolute(k))));
}

export async function evictToLimit(limit: number) {
	const d = await db();
	const victims = chooseEvictions(await d.getAll('images'), limit);
	await deleteEntries(victims);
	return victims.length;
}

export interface CacheUsage {
	total: number;
	thumbs: number;
	previews: number;
	pinned: number;
	count: number;
	byAlbum: Map<number, number>;
}

export function summarize(entries: ImageEntry[]): CacheUsage {
	const u: CacheUsage = { total: 0, thumbs: 0, previews: 0, pinned: 0, count: entries.length, byAlbum: new Map() };
	for (const e of entries) {
		u.total += e.bytes;
		if (e.url.startsWith('/api/thumb/')) u.thumbs += e.bytes;
		else u.previews += e.bytes;
		if (e.pins.length) u.pinned += e.bytes;
		for (const p of e.pins) u.byAlbum.set(p, (u.byAlbum.get(p) ?? 0) + e.bytes);
	}
	return u;
}

export async function usage(): Promise<CacheUsage> {
	return summarize(await (await db()).getAll('images'));
}

/** Empties the cache; with `keepPinned`, downloaded albums stay. */
export async function clearImages(keepPinned: boolean) {
	const d = await db();
	if (!keepPinned) {
		await d.clear('images');
		await caches.delete(IMAGE_CACHE);
		return;
	}
	await deleteEntries((await d.getAll('images')).filter((e) => e.pins.length === 0).map((e) => e.url));
}

export async function getLimit(): Promise<number> {
	return ((await (await db()).get('meta', 'cacheLimit')) as number | undefined) ?? DEFAULT_LIMIT;
}

export async function setLimit(bytes: number) {
	await (await db()).put('meta', bytes, 'cacheLimit');
}
