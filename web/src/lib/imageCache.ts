// Device image cache: bytes live in Cache Storage, bookkeeping (size, last access, pins) in IndexedDB.
// Used by both the service worker (caching what the app views) and the page (downloads, eviction).
import type { IDBPTransaction } from 'idb';
import { db, type ImageEntry, type PhotosSchema } from './db';

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

export type CacheKind = 'thumb' | 'preview' | 'clip';
export const kindOf = (key: string): CacheKind =>
	key.startsWith('/api/thumb/') || key.startsWith('/api/faces/') ? 'thumb' : key.endsWith('/motion') ? 'clip' : 'preview';

/** Bytes per kind, kept up to date with every change so checking the limit needs no full read. */
export type CacheTotals = Record<CacheKind, number>;
const TOTALS = 'cacheTotals';
const zero = (): CacheTotals => ({ thumb: 0, preview: 0, clip: 0 });

type ImagesTx = IDBPTransaction<PhotosSchema, ('images' | 'meta')[], 'readwrite'>;
/** The stored totals; read them before changing entries in the same transaction. */
async function loadTotals(tx: ImagesTx): Promise<CacheTotals> {
	return ((await tx.objectStore('meta').get(TOTALS)) as CacheTotals | undefined) ?? (await countTotals(tx));
}

async function saveTotals(tx: ImagesTx, t: CacheTotals, changes: [string, number][]) {
	for (const [key, delta] of changes) t[kindOf(key)] = Math.max(0, t[kindOf(key)] + delta);
	await tx.objectStore('meta').put(t, TOTALS);
}

/** Totals from scratch (first use after an update): one full read. */
async function countTotals(tx: ImagesTx): Promise<CacheTotals> {
	const t = zero();
	for (const e of await tx.objectStore('images').getAll()) t[kindOf(e.url)] += e.bytes;
	return t;
}

export async function cacheTotals(): Promise<CacheTotals> {
	const d = await db();
	const tx = d.transaction(['images', 'meta'], 'readwrite');
	const t = await loadTotals(tx);
	await tx.objectStore('meta').put(t, TOTALS);
	await tx.done;
	return t;
}

/** Records a freshly cached image (keeps existing pins). */
export async function recordImage(key: string, bytes: number, pin?: number) {
	const d = await db();
	const tx = d.transaction(['images', 'meta'], 'readwrite');
	const store = tx.objectStore('images');
	const totals = await loadTotals(tx);
	const prev = await store.get(key);
	const pins = new Set(prev?.pins ?? []);
	if (pin != null) pins.add(pin);
	await store.put({ url: key, bytes, lastAccess: Date.now(), pins: [...pins] });
	await saveTotals(tx, totals, [[key, bytes - (prev?.bytes ?? 0)]]);
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

// Eviction budgets, as parts of the limit. Live Photo clips may use at most CLIP_SHARE (a few clips
// mustn't push out thousands of thumbnails); thumbnails, which make scrolling fast, are only evicted
// once previews and clips are gone or thumbnails use more than THUMB_SHARE. Trimming goes a little
// below the limit (SLACK) so it doesn't run again on every new image.
const CLIP_SHARE = 0.15;
const THUMB_SHARE = 0.5;
const SLACK = 0.9;

/** Decides, entry by entry from the least recently used, what to drop to fit `limit`. */
export class EvictionPlan {
	private clipNeed: number;
	private need: number;
	private thumbs: number;
	readonly protectedThumbs: number;
	constructor(totals: CacheTotals, private limit: number) {
		const total = totals.thumb + totals.preview + totals.clip;
		this.clipNeed = totals.clip > CLIP_SHARE * limit ? totals.clip - CLIP_SHARE * SLACK * limit : 0;
		this.need = total > limit ? total - SLACK * limit : 0;
		this.thumbs = totals.thumb;
		this.protectedThumbs = THUMB_SHARE * limit;
	}
	get done() {
		return this.clipNeed <= 0 && this.need <= 0;
	}
	/** Whether to drop this entry; `thumbsToo` lifts the thumbnail protection (second pass). */
	take(e: ImageEntry, thumbsToo = false): boolean {
		if (e.pins.length) return false;
		const kind = kindOf(e.url);
		const drop =
			(kind === 'clip' && this.clipNeed > 0) ||
			(this.need > 0 && (kind !== 'thumb' || thumbsToo || this.thumbs > this.protectedThumbs));
		if (!drop) return false;
		this.need -= e.bytes;
		if (kind === 'clip') this.clipNeed -= e.bytes;
		if (kind === 'thumb') this.thumbs -= e.bytes;
		return true;
	}
	/** Something is still over budget after a pass that kept thumbnails. */
	get needsThumbs() {
		return this.need > 0;
	}
}

/** Which entries to drop to fit `limit` (pure version of evictToLimit, for tests). */
export function chooseEvictions(entries: ImageEntry[], limit: number): string[] {
	const totals = zero();
	for (const e of entries) totals[kindOf(e.url)] += e.bytes;
	const plan = new EvictionPlan(totals, limit);
	const lru = entries.slice().sort((a, b) => a.lastAccess - b.lastAccess);
	const out = new Set<string>();
	for (const e of lru) {
		if (plan.done) break;
		if (plan.take(e)) out.add(e.url);
	}
	for (const e of lru) {
		if (!plan.needsThumbs) break;
		if (!out.has(e.url) && plan.take(e, true)) out.add(e.url);
	}
	return [...out];
}

/** Deletes unpinned entries among `keys` (pins are re-checked: an album may have pinned one meanwhile). */
async function deleteEntries(keys: string[]) {
	if (!keys.length) return;
	const cache = await caches.open(IMAGE_CACHE);
	const d = await db();
	const tx = d.transaction(['images', 'meta'], 'readwrite');
	const store = tx.objectStore('images');
	const totals = await loadTotals(tx);
	const deleted: string[] = [];
	const changes: [string, number][] = [];
	for (const k of keys) {
		const e = await store.get(k);
		if (e && e.pins.length === 0) {
			store.delete(k);
			deleted.push(k);
			changes.push([k, -e.bytes]);
		}
	}
	await saveTotals(tx, totals, changes);
	await tx.done;
	await Promise.all(deleted.map((k) => cache.delete(absolute(k))));
}

/** Trims the cache to `limit`: O(1) when under it, else walks entries from the least recently used. */
export async function evictToLimit(limit: number) {
	const plan = new EvictionPlan(await cacheTotals(), limit);
	if (plan.done) return 0;
	const d = await db();
	const victims = new Set<string>();
	for (const thumbsToo of [false, true]) {
		if (thumbsToo ? !plan.needsThumbs : plan.done) continue;
		let cursor = await d.transaction('images').store.index('lastAccess').openCursor();
		while (cursor && !(thumbsToo ? !plan.needsThumbs : plan.done)) {
			if (!victims.has(cursor.value.url) && plan.take(cursor.value, thumbsToo)) victims.add(cursor.value.url);
			cursor = await cursor.continue();
		}
	}
	// in batches, so other cache users aren't blocked for long
	const list = [...victims];
	for (let i = 0; i < list.length; i += 500) await deleteEntries(list.slice(i, i + 500));
	return list.length;
}

// ---- Live Photo motion clips ----------------------------------------------------------------------
// Kept in the same cache, under the same size limit and eviction, as thumbnails and previews. Fetched
// only when the user holds a Live Photo (LiveOverlay), so replays and offline plays need no network.

/** Cache key of a Live Photo's motion clip (asset ids are content hashes, so it never goes stale). */
export const motionKey = (id: string) => `/api/assets/${id}/motion`;

/** Whether the clip is cached (doesn't read it). */
export async function hasClip(key: string): Promise<boolean> {
	return !!(await (await caches.open(IMAGE_CACHE)).match(absolute(key)));
}

/** The cached clip, or null (marks it as just used). */
export async function cachedClip(key: string): Promise<Blob | null> {
	const hit = await (await caches.open(IMAGE_CACHE)).match(absolute(key));
	if (!hit) return null;
	touchImages([key]).catch(() => {});
	return hit.blob();
}

/** Keeps a downloaded clip on the device, then trims the cache to its limit. */
export async function storeClip(key: string, blob: Blob) {
	const cache = await caches.open(IMAGE_CACHE);
	await cache.put(absolute(key), new Response(blob, { headers: { 'content-type': blob.type || 'video/quicktime' } }));
	await recordImage(key, blob.size);
	await evictToLimit(await getLimit());
}

export interface CacheUsage {
	total: number;
	thumbs: number;
	previews: number;
	/** Live Photo motion clips */
	clips: number;
	pinned: number;
	count: number;
	byAlbum: Map<number, number>;
}

export function summarize(entries: ImageEntry[]): CacheUsage {
	const u: CacheUsage = { total: 0, thumbs: 0, previews: 0, clips: 0, pinned: 0, count: entries.length, byAlbum: new Map() };
	for (const e of entries) {
		u.total += e.bytes;
		if (e.url.startsWith('/api/thumb/')) u.thumbs += e.bytes;
		else if (e.url.endsWith('/motion')) u.clips += e.bytes;
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
		await d.put('meta', zero(), TOTALS);
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
