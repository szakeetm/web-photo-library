import { version } from '$app/env';
import { api, onServerApiVersion, CLIENT_API_VERSION, CATALOG_FORMAT, type CatalogAsset, type CatalogAlbum, type CatalogPerson, type CatalogPlace, type FolderNode, type ImageFmt, type ServerInfo } from './api';
import { supportsHeic } from './heic';
import { sortByLocalTime } from './dates';
import { net } from './net.svelte';
import { loadReplica, mergeAssets, saveDelta, saveSnapshot } from './replica';
import type { CatalogMeta } from './db';

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
	folderById = $derived(new Map(this.folders.map((f) => [f.id, f])));

	/** An uploaded photo: every copy of it is in the uploads folder (only those can be deleted). */
	isUpload(id: string): boolean {
		const a = this.byId.get(id);
		return !!a && a.folders.length > 0 && a.folders.every((f) => this.folderById.get(f)?.root === 'uploads');
	}
	fmt = $state<ImageFmt>('jpeg');
	loaded = $state(false);
	error = $state<string | null>(null);
	libraryConfigured = $state(true);
	server = $state<ServerInfo | null>(null);
	readonly clientVersion = version;
	/** True when this app doesn't match the server (API or payload format): the user must update. */
	updateRequired = $state(false);

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
		net.onReconnect(() => this.reload());
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
			this.libraryConfigured = health.libraryConfigured;
			this.uploadsConfigured = health.uploadsConfigured;
			if (health.apiVersion !== CLIENT_API_VERSION) {
				this.updateRequired = true;
				return;
			}
			const delta = this.meta ? await api.changes(this.meta.seq, this.meta.catalogId) : null;
			if (delta && !delta.reset) {
				if (delta.format !== CATALOG_FORMAT) {
					this.updateRequired = true;
					return;
				}
				if (delta.seq !== this.meta!.seq || delta.assets.length || delta.deleted.length) {
					if (delta.assets.length || delta.deleted.length) this.assets = sortByLocalTime(mergeAssets(this.assets, delta));
					if (delta.folders) this.folders = delta.folders;
					if (delta.albums) this.albums = delta.albums;
					if (delta.people) this.people = delta.people;
					if (delta.places) this.places = delta.places;
					this.meta = { format: delta.format, catalogId: delta.catalogId, seq: delta.seq };
					await saveDelta(delta).catch(() => {});
				}
			} else {
				const snap = await api.catalog();
				if (snap.format !== CATALOG_FORMAT) {
					this.updateRequired = true;
					return;
				}
				this.assets = sortByLocalTime(snap.assets);
				this.folders = snap.folders;
				this.albums = snap.albums;
				this.people = snap.people;
				this.places = snap.places;
				this.meta = { format: snap.format, catalogId: snap.catalogId, seq: snap.seq };
				await saveSnapshot(snap).catch(() => {});
			}
			this.error = null;
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

/** Deletes uploaded photos; the server moves their files to its Trash. */
export async function deleteUploads(ids: string[]) {
	if (!ids.every((id) => app.isUpload(id))) throw new Error('Only uploaded photos can be deleted.');
	const set = new Set(ids);
	const before = app.assets;
	app.assets = app.assets.filter((a) => !set.has(a.id));
	try {
		await api.deleteUploads(ids);
	} catch (e) {
		app.assets = before;
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

export const app = new AppState();
