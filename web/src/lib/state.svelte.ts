import { version } from '$app/env';
import { api, onServerApiVersion, CLIENT_API_VERSION, CATALOG_FORMAT, type CatalogAsset, type DateChange, type CatalogAlbum, type CatalogPerson, type CatalogPlace, type FolderNode, type ImageFmt, type ServerInfo, type TrashItem, type DownloadProgress } from './api';
import { supportsHeic } from './heic';
import { isFirefox } from './platform';
import { sortByLocalTime } from './dates';
import { buildIndex } from './assetIndex';
import { net } from './net.svelte';
import { loadReplica, mergeAlbums, mergeAssets, saveDelta, saveSnapshot } from './replica';
import { db, type CatalogMeta } from './db';

/** Listeners run after every successful sync (e.g. downloaded albums re-check their photos). */
const afterSync = new Set<() => void>();
export function onSynced(fn: () => void) {
	afterSync.add(fn);
	return () => afterSync.delete(fn);
}

class AppState {
	/** All photos, oldest first (Photos-style: newest at the bottom). */
	assets = $state.raw<CatalogAsset[]>([]);
	folders = $state.raw<FolderNode[]>([]);
	albums = $state.raw<CatalogAlbum[]>([]);
	/** People with at least one photo (named first); hidden ones included (flag). */
	people = $state.raw<CatalogPerson[]>([]);
	places = $state.raw<CatalogPlace[]>([]);
	placeById = $derived(new Map(this.places.map((p) => [p.id, p])));
	personById = $derived(new Map(this.people.map((p) => [p.id, p])));
	uploadsConfigured = $state(false);
	byId = $derived(new Map(this.assets.map((a) => [a.id, a])));
	/** Favourites, videos, photos per folder/place/person…: built once per catalog change. */
	index = $derived(buildIndex(this.assets));
	folderById = $derived(new Map(this.folders.map((f) => [f.id, f])));
	/** Deleted uploads (most recent first); loaded from the server, not kept offline. */
	trash = $state.raw<TrashItem[]>([]);
	trashById = $derived(new Map(this.trash.map((t) => [t.asset.id, t.asset])));

	/** A photo in the library or in the Trash (thumbnails and the viewer show both). */
	lookup(id: string): CatalogAsset | undefined {
		return this.byId.get(id) ?? this.trashById.get(id);
	}

	async loadTrash() {
		if (!net.online) return;
		try {
			this.trash = await api.trash();
		} catch {
			// keep the last list
		}
	}

	/** An uploaded photo: every copy of it is in the uploads folder (only those can be deleted). */
	isUpload(id: string): boolean {
		const a = this.byId.get(id);
		return !!a && a.folders.length > 0 && a.folders.every((f) => this.folderById.get(f)?.root === 'uploads');
	}
	fmt = $state<ImageFmt>('jpeg');
	loaded = $state(false);
	/** The server says this browser runs on its own Mac. */
	serverLocal = $state(false);
	/** Settings switch for testing: behave like a remote device even on the server's Mac. */
	forceRemote = $state(typeof localStorage !== 'undefined' && localStorage.getItem('photos.forceRemote') === '1');
	/**
	 * Local mode (on the server's Mac): photos and videos come straight from its disk, so the app keeps no
	 * cache or offline downloads of its own, plays videos from the original and offers Reveal in Finder.
	 */
	local = $derived(this.serverLocal && !this.forceRemote);

	setForceRemote(on: boolean) {
		this.forceRemote = on;
		if (on) localStorage.setItem('photos.forceRemote', '1');
		else localStorage.removeItem('photos.forceRemote');
		syncLocalMode(this.local);
	}
	/** The full catalog download in progress (first install, or after a reset), else null. */
	download = $state<DownloadProgress | null>(null);
	error = $state<string | null>(null);
	libraryConfigured = $state(true);
	server = $state<ServerInfo | null>(null);
	readonly clientVersion = version;
	/** True when this app doesn't match the server (API or payload format): the user must update. */
	updateRequired = $state(false);
	/** The server has a newer web app than this one (found by the sync check, so it is noticed when
	 *  the app comes back on screen instead of only by SvelteKit's 5-minute check). */
	newWebVersion = $state(false);

	constructor() {
		onServerApiVersion((serverApi, refused) => {
			if (refused || serverApi !== CLIENT_API_VERSION) this.updateRequired = true;
		});
	}
	private started = false;
	private meta: CatalogMeta | null = null;
	private syncing: Promise<void> | null = null;
	private again = false;

	async init() {
		if (this.started) return;
		this.started = true;
		net.start();
		// Ask the browser not to clear the device copy and image cache under storage pressure. Safari and
		// Chrome decide on their own; Firefox would ask the user, unprompted, so there it waits for a
		// download for offline use or Settings → Keep on this device.
		if (!isFirefox) navigator.storage?.persist?.()?.catch(() => {});
		net.onReconnect(() => this.reload());
		// Changes made on another device: the server is asked for what changed (a small delta) when
		// the app comes back to the screen (iOS resumes a Home Screen app instead of restarting it)
		// and every half minute while it is on screen.
		let lastSync = Date.now();
		const refresh = (minAge: number) => {
			if (document.visibilityState !== 'visible' || !net.online || Date.now() - lastSync < minAge) return;
			lastSync = Date.now();
			this.reload();
		};
		document.addEventListener('visibilitychange', () => refresh(2_000));
		window.addEventListener('focus', () => refresh(2_000));
		window.addEventListener('pageshow', () => refresh(2_000));
		setInterval(() => refresh(25_000), 30_000);
		this.fmt = (await supportsHeic()) ? 'heic' : 'jpeg';
		// Show the device copy immediately (works offline), then bring it up to date.
		try {
			const replica = await loadReplica(CATALOG_FORMAT);
			if (replica) {
				this.meta = replica.meta;
				this.assets = sortByLocalTime(replica.assets);
				this.folders = replica.folders;
				this.albums = replica.albums;
				this.people = replica.people;
				this.places = replica.places;
				this.loaded = true;
			}
		} catch {
			/* no IndexedDB (private mode): online only */
		}
		await this.reload();
	}

	/** Brings the catalog up to date with the server (delta when possible). Concurrent calls coalesce. */
	reload(): Promise<void> {
		if (this.syncing) {
			this.again = true;
			return this.syncing;
		}
		this.syncing = (async () => {
			do {
				this.again = false;
				await this.syncOnce();
			} while (this.again);
		})().finally(() => (this.syncing = null));
		return this.syncing;
	}

	private async syncOnce() {
		try {
			const health = await net.check();
			if (!health) {
				// Offline: keep showing the device copy.
				this.error = this.meta ? null : "Can't reach the server.";
				return;
			}
			this.server = health;
			if (health.webVersion && health.webVersion !== this.clientVersion) this.newWebVersion = true;
			this.libraryConfigured = health.libraryConfigured;
			this.uploadsConfigured = health.uploadsConfigured;
			if (this.serverLocal !== (health.local === true)) {
				this.serverLocal = health.local === true;
				syncLocalMode(this.local);
			}
			if (health.apiVersion !== CLIENT_API_VERSION) {
				this.updateRequired = true;
				return;
			}
			const delta = this.meta ? await api.changes(this.meta.seq, this.meta.catalogId, this.meta.hashes) : null;
			if (delta && !delta.reset) {
				if (delta.format !== CATALOG_FORMAT) {
					this.updateRequired = true;
					return;
				}
				if (delta.seq !== this.meta!.seq || delta.assets.length || delta.deleted.length) {
					if (delta.assets.length || delta.deleted.length) this.assets = sortByLocalTime(mergeAssets(this.assets, delta));
					if (delta.folders) this.folders = delta.folders;
					const albums = mergeAlbums(this.albums, delta);
					this.albums = albums;
					if (delta.people) this.people = delta.people;
					if (delta.places) this.places = delta.places;
					this.meta = { format: delta.format, catalogId: delta.catalogId, seq: delta.seq, hashes: delta.hashes ?? this.meta!.hashes };
					await saveDelta(delta, albums).catch(() => {});
				}
			} else {
				this.download = { received: 0, total: 0 };
				let snap;
				try {
					snap = await api.catalog((p) => (this.download = p));
				} finally {
					this.download = null;
				}
				if (snap.format !== CATALOG_FORMAT) {
					this.updateRequired = true;
					return;
				}
				this.assets = sortByLocalTime(snap.assets);
				this.folders = snap.folders;
				this.albums = snap.albums;
				this.people = snap.people;
				this.places = snap.places;
				this.meta = { format: snap.format, catalogId: snap.catalogId, seq: snap.seq, hashes: snap.hashes };
				await saveSnapshot(snap).catch(() => {});
			}
			this.error = null;
			this.loadTrash();
			for (const fn of afterSync) fn();
		} catch (e) {
			if (net.online) this.error = e instanceof Error ? e.message : String(e);
		} finally {
			this.loaded = true;
		}
	}

	/** Replaces one asset in memory (e.g. right after an edit), ahead of the next sync. */
	patchAsset(a: CatalogAsset) {
		this.assets = this.assets.map((x) => (x.id === a.id ? a : x));
	}
}

/** Favourite / unfavourite with an optimistic update. */
export async function setFavorite(ids: string[], favorite: boolean) {
	const set = new Set(ids);
	const before = app.assets;
	app.assets = app.assets.map((a) => (set.has(a.id) ? { ...a, fav: favorite } : a));
	try {
		await api.setFavorite(ids, favorite);
	} catch (e) {
		app.assets = before;
		throw e;
	}
	app.reload(); // persist to the device copy
}

/** Changes the dates of photos (database only; exports write them into the copies). */
export async function changeDates(ids: string[], change: DateChange) {
	applyAssets(await api.changeDates(ids, change));
}

/** Back to the dates read from the files. */
export async function revertDates(ids: string[]) {
	applyAssets(await api.revertDates(ids));
}

function applyAssets(list: CatalogAsset[]) {
	const byId = new Map(list.map((a) => [a.id, a]));
	app.assets = sortByLocalTime(app.assets.map((a) => byId.get(a.id) ?? a));
	app.reload(); // persist to the device copy
}

/** The Trash: deleted uploads (deleted from disk only by hand) and hidden photos (restorable). */
/** Puts photos in the Trash: uploads are moved there, the others only hidden (their files stay). */
export async function deletePhotos(ids: string[]) {
	const set = new Set(ids);
	const before = app.assets;
	app.assets = app.assets.filter((a) => !set.has(a.id));
	try {
		await api.deletePhotos(ids);
	} catch (e) {
		app.assets = before;
		throw e;
	}
	await app.reload();
}

export async function restoreFromTrash(ids: string[]) {
	const set = new Set(ids);
	const before = app.trash;
	app.trash = app.trash.filter((t) => !set.has(t.asset.id));
	try {
		await api.restoreTrash(ids);
	} catch (e) {
		app.trash = before;
		throw e;
	}
	await app.reload();
}

/** Deletes Trash uploads for good (all of them without ids); hidden photos stay in the Trash. */
export async function deleteForever(ids?: string[]) {
	const set = ids && new Set(ids);
	const before = app.trash;
	// only uploads are deleted for good; hidden photos stay in the Trash
	app.trash = app.trash.filter((t) => t.virtual || (set ? !set.has(t.asset.id) : false));
	try {
		await api.deleteForever(ids);
	} catch (e) {
		app.trash = before;
		throw e;
	}
	await app.reload();
}

export async function addToAlbum(albumId: number, ids: string[]) {
	await api.albumAssets(albumId, { add: ids });
	await app.reload();
}

export async function removeFromAlbum(albumId: number, ids: string[]) {
	const set = new Set(ids);
	app.albums = app.albums.map((al) => (al.id === albumId ? { ...al, assetIds: al.assetIds.filter((i) => !set.has(i)) } : al));
	await api.albumAssets(albumId, { remove: ids });
	await app.reload();
}

export async function createAlbum(title: string, ids: string[] = []) {
	const album = await api.createAlbum(title, ids);
	await app.reload();
	return album;
}

/** Tells the service worker (which caches images) whether local mode is on; it remembers it in IndexedDB. */
function syncLocalMode(on: boolean) {
	db()
		.then((d) => d.put('meta', on, 'localMode'))
		.catch(() => {});
	navigator.serviceWorker?.controller?.postMessage({ type: 'localMode', on });
}

export const app = new AppState();
