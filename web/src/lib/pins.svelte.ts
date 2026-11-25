// Downloaded albums: their thumbnails and previews (current edit version, this device's format) are
// pinned in the image cache so the album works offline. Downloads continue only while the app is open
// and resume on the next launch; a re-edited photo gets its new images pinned and the old ones released.
import { previewUrl, thumbUrl, type CatalogAlbum, type CatalogAsset, type ImageFmt } from './api';
import { db, type PinRecord } from './db';
import { cacheAndPin, evictToLimit, getLimit, NetworkError, releasePins } from './imageCache';
import { net } from './net.svelte';
import { app, onSynced } from './state.svelte';

/** Every image a downloaded album needs on this device. */
export function albumImageUrls(album: CatalogAlbum, byId: Map<string, CatalogAsset>, fmt: ImageFmt): string[] {
	const out: string[] = [];
	for (const id of album.assetIds) {
		const a = byId.get(id);
		if (!a) continue;
		out.push(thumbUrl(a.id, a.ev, fmt), previewUrl(a.id, a.ev, fmt));
	}
	return out;
}

const CONCURRENCY = 4;

class Pins {
	/** Downloaded (or downloading) albums by id. */
	records = $state<Record<number, PinRecord>>({});
	private running: Promise<void> | null = null;
	private rerun = false;
	private started = false;

	async start() {
		if (this.started) return;
		this.started = true;
		try {
			const all = await (await db()).getAll('pins');
			this.records = Object.fromEntries(all.map((p) => [p.albumId, p]));
		} catch {
			return;
		}
		onSynced(() => this.reconcile());
		this.reconcile();
	}

	has(albumId: number) {
		return albumId in this.records;
	}

	async download(album: CatalogAlbum) {
		// Ask the browser not to evict our storage (best effort).
		navigator.storage?.persist?.().catch(() => {});
		await this.save({ albumId: album.id, title: album.title, state: 'downloading', total: 0, done: 0, bytes: 0, updatedAt: Date.now() });
		this.reconcile();
	}

	async remove(albumId: number) {
		const next = { ...this.records };
		delete next[albumId];
		this.records = next;
		await (await db()).delete('pins', albumId);
		await releasePins(albumId);
		// Downloads already in flight may pin a few more images: release again once they stop.
		if (this.running) {
			await this.running;
			await releasePins(albumId);
		}
		await evictToLimit(await getLimit());
	}

	private async save(p: PinRecord) {
		this.records = { ...this.records, [p.albumId]: p };
		await (await db()).put('pins', $state.snapshot(p) as PinRecord);
	}

	/** Brings every downloaded album in line with the catalog. Safe to call often. */
	async reconcile() {
		if (this.running) {
			this.rerun = true;
			return;
		}
		this.running = (async () => {
			try {
				do {
					this.rerun = false;
					await this.reconcileOnce();
				} while (this.rerun);
			} catch {
				/* storage full or similar; retried after the next sync */
			}
		})();
		await this.running;
		this.running = null;
		await evictToLimit(await getLimit()).catch(() => {});
	}

	private async reconcileOnce() {
		if (!app.loaded) return;
		for (const rec of Object.values(this.records)) {
			const album = app.albums.find((a) => a.id === rec.albumId);
			if (!album) {
				// The album was deleted on the server.
				await this.remove(rec.albumId);
				continue;
			}
			const urls = albumImageUrls(album, app.byId, app.fmt);
			await releasePins(album.id, new Set(urls));
			if (!net.online) continue;
			let done = 0;
			let bytes = 0;
			let failed = false;
			let next = 0;
			// A finished album is re-checked quietly (it only fetches what changed).
			if (rec.state !== 'done') await this.save({ ...rec, title: album.title, state: 'downloading', total: urls.length, done: 0 });
			const worker = async () => {
				while (next < urls.length && !failed && this.has(album.id)) {
					const url = urls[next++];
					try {
						const n = await cacheAndPin(url, album.id); // not `bytes += await …`: workers run concurrently
						bytes += n;
						done++;
						const rec = this.records[album.id];
						if (rec && (done % 10 === 0 || done === urls.length)) {
							this.records = { ...this.records, [album.id]: { ...rec, done, total: urls.length } };
						}
					} catch (e) {
						if (e instanceof NetworkError || !net.online) {
							// Stop and stay "downloading": resumes when the server is back.
							failed = true;
							if (e instanceof NetworkError) net.check();
						} else {
							done++; // a photo the server can't render must not block the album
						}
					}
				}
			};
			await Promise.all(Array.from({ length: CONCURRENCY }, worker));
			const current = this.records[album.id];
			if (!current) continue; // removed meanwhile
			await this.save({
				...current,
				title: album.title,
				state: failed ? 'downloading' : 'done',
				total: urls.length,
				done,
				bytes,
				updatedAt: Date.now()
			});
		}
	}
}

export const pins = new Pins();
