// Downloaded albums and folders: their thumbnails and previews (current edit version, this device's
// format) are pinned in the image cache so they work offline. A folder download covers its subfolders.
// Downloads continue only while the app is open and resume on the next launch; a re-edited photo gets
// its new images pinned and the old ones released. Pin ids: an album's id, −id for a folder.
import { inFolders, type AssetIndex } from './assetIndex';
import { previewUrl, thumbUrl, type CatalogAlbum, type CatalogAsset, type FolderNode, type ImageFmt } from './api';
import { db, type PinRecord } from './db';
import { cacheAndPin, evictToLimit, getLimit, NetworkError, releasePins } from './imageCache';
import { net } from './net.svelte';
import { app, onSynced } from './state.svelte';

/** Every image a downloaded album needs on this device. */
export function albumImageUrls(album: CatalogAlbum, byId: Map<string, CatalogAsset>, fmt: ImageFmt): string[] {
	return imageUrls(album.assetIds, byId, fmt);
}

function imageUrls(ids: Iterable<string>, byId: Map<string, CatalogAsset>, fmt: ImageFmt): string[] {
	const out: string[] = [];
	for (const id of ids) {
		const a = byId.get(id);
		if (!a) continue;
		out.push(thumbUrl(a.id, a.ev, fmt), previewUrl(a.id, a.ev, fmt));
	}
	return out;
}

/** `folder` and all folders below it. */
export function folderSubtree(folder: FolderNode, folders: FolderNode[]): Set<number> {
	const children = new Map<number, number[]>();
	for (const f of folders) if (f.parentId != null) children.set(f.parentId, [...(children.get(f.parentId) ?? []), f.id]);
	const out = new Set<number>();
	const stack = [folder.id];
	while (stack.length) {
		const id = stack.pop()!;
		if (out.has(id)) continue;
		out.add(id);
		stack.push(...(children.get(id) ?? []));
	}
	return out;
}

/** Ids of the photos in `folder` and its subfolders. */
export function folderAssetIds(folder: FolderNode, folders: FolderNode[], ix: AssetIndex): string[] {
	return inFolders(ix, folderSubtree(folder, folders)).map((a) => a.id);
}

/** Downloads above this many photos ask first. */
export const LARGE_DOWNLOAD = 500;
/** Rough device space per photo (thumbnail + 2048 px preview). */
const BYTES_PER_PHOTO = 0.45e6;

/** Asks before a large download; true to go ahead. */
export function confirmDownload(title: string, photos: number, nested = false): boolean {
	if (photos <= LARGE_DOWNLOAD) return true;
	const size = photos * BYTES_PER_PHOTO;
	const approx = size < 1e9 ? `${Math.round(size / 1e7) * 10} MB` : `${(size / 1e9).toFixed(1)} GB`;
	return confirm(
		`“${title}” has ${photos.toLocaleString()} photos${nested ? ' (including subfolders)' : ''}.\n` +
			`Downloading keeps about ${approx} on this device, and takes a while: keep the app open until it finishes.\n\nDownload?`
	);
}

export const folderPinId = (folder: FolderNode) => -folder.id;

/** Share of a download done, 0…1 (images, i.e. thumbnails and previews). */
export const pinProgress = (p: PinRecord) => (p.state === 'done' ? 1 : p.total ? Math.min(1, p.done / p.total) : 0);

const fmtBytes = (n: number) => (n < 1e9 ? `${(n / 1e6).toFixed(0)} MB` : `${(n / 1e9).toFixed(1)} GB`);

/** "Downloading 42%", "Download paused 42%" (offline) or "Downloaded (120 MB)". */
export function pinStatus(p: PinRecord, online: boolean): string {
	if (p.state === 'downloading') return `${online ? 'Downloading' : 'Download paused'} ${Math.floor(pinProgress(p) * 100)}%`;
	return `Downloaded${p.bytes ? ` (${fmtBytes(p.bytes)})` : ''}`;
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
		await this.begin(album.id, album.title);
	}

	async downloadFolder(folder: FolderNode, title: string) {
		await this.begin(folderPinId(folder), title, { root: folder.root, relPath: folder.relPath });
	}

	private async begin(pinId: number, title: string, folder?: PinRecord['folder']) {
		// Ask the browser not to evict our storage (best effort).
		navigator.storage?.persist?.().catch(() => {});
		await this.save({ albumId: pinId, folder, title, state: 'downloading', total: 0, done: 0, bytes: 0, updatedAt: Date.now() });
		this.reconcile();
	}

	/** The download covering `folder`: its own, or a parent folder's (which includes subfolders). */
	folderPin(folder: FolderNode): PinRecord | undefined {
		const own = this.records[folderPinId(folder)];
		if (own) return own;
		return Object.values(this.records).find(
			(r) =>
				r.folder &&
				r.folder.root === folder.root &&
				(r.folder.relPath === '' || folder.relPath.startsWith(r.folder.relPath + '/'))
		);
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
		for (let rec of Object.values(this.records)) {
			const target = this.resolve(rec);
			if (!target) {
				// The album or folder is gone on the server.
				await this.remove(rec.albumId);
				continue;
			}
			if (target.pinId !== rec.albumId) {
				// The folder was re-created by a scan (new id, same path): move the download over.
				await this.remove(rec.albumId);
				rec = { ...rec, albumId: target.pinId };
				await this.save(rec);
			}
			const album = { id: target.pinId, title: target.title };
			const urls = target.urls;
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

	/** What a download currently covers; null when its album or folder no longer exists. */
	private resolve(rec: PinRecord): { pinId: number; title: string; urls: string[] } | null {
		if (rec.folder) {
			const { root, relPath } = rec.folder;
			const folder =
				app.folders.find((f) => -f.id === rec.albumId && f.root === root && f.relPath === relPath) ??
				app.folders.find((f) => f.root === root && f.relPath === relPath);
			if (!folder) return null;
			return { pinId: folderPinId(folder), title: rec.title, urls: imageUrls(folderAssetIds(folder, app.folders, app.index), app.byId, app.fmt) };
		}
		const album = app.albums.find((a) => a.id === rec.albumId);
		return album ? { pinId: album.id, title: album.title, urls: albumImageUrls(album, app.byId, app.fmt) } : null;
	}
}

export const pins = new Pins();
