/// <reference types="@sveltejs/kit" />
/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />
/// <reference lib="webworker" />
// Offline support: the app shell is precached so the app launches without a network; thumbnails and
// previews are cached as they are viewed (and by downloaded albums). Everything else under /api goes
// to the network. A new worker waits until the app's "Update now" activates it.
import { immutable, assets } from '$app/manifest';
import { version } from '$app/env';
import { IMAGE_CACHE, imageKey, isCacheableImage, recordImage, touchImages, evictToLimit, getLimit } from '#lib/imageCache.ts';
import { isStreamedMedia } from '#lib/video.ts';
import { db } from '#lib/db.ts';

const sw = self as unknown as ServiceWorkerGlobalScope;
const SHELL = `shell-${version}`;
const SHELL_FILES = ['/', ...immutable.map((f) => `/${f.path}`), ...assets.map((f) => `/${f.path}`)];
const shellSet = new Set(SHELL_FILES);
const NAV_TIMEOUT_MS = 2500;
/** Map tiles/styles/fonts already seen stay available offline (capped). */
const TILES = 'tiles-v1';
// the map styles offered in Settings → Map (a custom style's tiles aren't kept offline)
const TILE_HOSTS = [
	'tiles.openfreemap.org',
	'tiles.versatiles.org',
	'basemaps.cartocdn.com',
	'tiles.basemaps.cartocdn.com',
	...['a', 'b', 'c', 'd'].map((x) => `tiles-${x}.basemaps.cartocdn.com`)
];
const MAX_TILES = 4000;

sw.addEventListener('install', (event) => {
	event.waitUntil(caches.open(SHELL).then((c) => c.addAll(SHELL_FILES)));
});

sw.addEventListener('activate', (event) => {
	event.waitUntil(
		(async () => {
			for (const key of await caches.keys()) {
				if (key.startsWith('shell-') && key !== SHELL) await caches.delete(key);
			}
			await sw.clients.claim();
		})()
	);
});

// Local mode (the app runs on the server's Mac): images come straight from the server's disk, so
// none are cached here. The page sends changes; the last value is kept in IndexedDB for restarts.
let localMode = false;
db()
	.then((d) => d.get('meta', 'localMode'))
	.then((v) => (localMode = v === true))
	.catch(() => {});

sw.addEventListener('message', (event) => {
	if (event.data === 'skipWaiting') sw.skipWaiting();
	else if (event.data?.type === 'localMode') localMode = event.data.on === true;
});

// Last-access updates are batched: grids request hundreds of thumbnails at once.
const touched = new Set<string>();
let flushTimer: ReturnType<typeof setTimeout> | undefined;
function touch(key: string) {
	touched.add(key);
	flushTimer ??= setTimeout(() => {
		flushTimer = undefined;
		const keys = [...touched];
		touched.clear();
		touchImages(keys).catch(() => {});
	}, 2000);
}

// Browsing fills the cache: trim it to the limit a few seconds after images stop arriving.
let trimTimer: ReturnType<typeof setTimeout> | undefined;
function scheduleTrim() {
	clearTimeout(trimTimer);
	trimTimer = setTimeout(() => {
		getLimit()
			.then(evictToLimit)
			.catch(() => {});
	}, 5000);
}

async function image(request: Request): Promise<Response> {
	const key = imageKey(request.url);
	const cache = await caches.open(IMAGE_CACHE);
	const hit = await cache.match(request.url);
	if (hit) {
		touch(key);
		return hit;
	}
	try {
		const res = await fetch(request);
		if (res.ok) {
			const blob = await res.clone().blob();
			await cache.put(request.url, res.clone());
			await recordImage(key, blob.size);
			scheduleTrim();
		}
		return res;
	} catch {
		return new Response(null, { status: 504, statusText: 'Offline' });
	}
}

/** Pages: the network first (so a reload picks up a new build), the cached shell when it is slow or down. */
async function navigate(request: Request): Promise<Response> {
	const shell = await caches.open(SHELL);
	try {
		const res = await Promise.race([
			fetch(request),
			new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), NAV_TIMEOUT_MS))
		]);
		if (res.ok) return res;
		return (await shell.match('/')) ?? res;
	} catch {
		const cached = await shell.match('/');
		if (cached) return cached;
		throw new Error('offline and no cached app');
	}
}

let tileWrites = 0;
async function tile(request: Request): Promise<Response> {
	const cache = await caches.open(TILES);
	try {
		const res = await fetch(request);
		if (res.ok) {
			await cache.put(request, res.clone());
			// trim now and then: oldest entries first (Cache Storage keeps insertion order)
			if (++tileWrites % 200 === 0) {
				const keys = await cache.keys();
				for (const k of keys.slice(0, Math.max(0, keys.length - MAX_TILES))) await cache.delete(k);
			}
		}
		return res;
	} catch {
		return (await cache.match(request)) ?? new Response(null, { status: 504, statusText: 'Offline' });
	}
}

sw.addEventListener('fetch', (event) => {
	const { request } = event;
	if (request.method !== 'GET') return;
	const url = new URL(request.url);
	if (isStreamedMedia(url.pathname)) return;
	if (TILE_HOSTS.includes(url.hostname)) {
		event.respondWith(tile(request));
		return;
	}
	if (url.origin !== sw.location.origin) return;

	if (request.mode === 'navigate') {
		event.respondWith(navigate(request));
	} else if (isCacheableImage(url.pathname)) {
		// Downloads made by the page manage the cache themselves.
		if (request.headers.has('X-Client-Cache') || localMode) return;
		event.respondWith(image(request));
	} else if (shellSet.has(url.pathname) && url.pathname !== '/') {
		event.respondWith(caches.match(request).then((hit) => hit ?? fetch(request)));
	}
	// Everything else (API, version.json) goes straight to the network.
});
