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

/** Pages: the cached shell at once (the app opens without waiting for the server; a new build is
 *  noticed by the app's sync check and installed by "Update now"), the network only when none is cached. */
async function navigate(request: Request): Promise<Response> {
	const cached = await (await caches.open(SHELL)).match('/');
	if (cached) return cached;
	return fetch(request);
}

/** A file of the app shell (scripts, styles, icons): the cached copy, else the network. */
async function shellFile(request: Request): Promise<Response> {
	const hit = await (await caches.open(SHELL)).match(request);
	return hit ?? fetch(request);
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
		// From the shell's own cache: caches.match() would search the older caches first (tens of
		// thousands of thumbnails), which on a cold launch on iOS kept the app black for seconds.
		event.respondWith(shellFile(request));
	}
	// Everything else (API, version.json) goes straight to the network.
});
