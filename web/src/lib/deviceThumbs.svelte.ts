// Which thumbnails are in this device's image cache (kept by the service worker), so a thumbnail
// that isn't loaded yet can say where it is coming from: the device (blur), the server (cloud), or
// nowhere while offline (crossed-out cloud). Read once from the cache's index, then kept up to date
// by what loads; re-read now and then, since the service worker trims the cache on its own.
import { db } from './db';

const REFRESH_MS = 2 * 60_000;

class DeviceThumbs {
	private keys = new Set<string>();
	/** bumps when the set changes, so thumbnails re-check */
	version = $state(0);
	private started = false;

	start() {
		if (this.started || typeof window === 'undefined') return;
		this.started = true;
		this.refresh();
		setInterval(() => document.visibilityState === 'visible' && this.refresh(), REFRESH_MS);
		document.addEventListener('visibilitychange', () => document.visibilityState === 'visible' && this.refresh());
	}

	async refresh() {
		try {
			const all = (await (await db()).getAllKeys('images')) as string[];
			this.keys = new Set(all.filter((k) => k.startsWith('/api/thumb/')));
			this.version++;
		} catch {
			/* no IndexedDB: everything counts as not cached */
		}
	}

	/** `url`: a thumbnail URL as the page requests it (path + query). */
	has(url: string) {
		void this.version;
		return this.keys.has(url);
	}

	/** A thumbnail just loaded while online: the service worker has cached it. */
	add(url: string) {
		this.keys.add(url);
	}
}

export const deviceThumbs = new DeviceThumbs();
