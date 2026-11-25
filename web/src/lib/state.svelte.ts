import { version } from '$app/env';
import { api, onServerApiVersion, CLIENT_API_VERSION, CATALOG_FORMAT, type CatalogAsset, type CatalogAlbum, type FolderNode, type ImageFmt, type ServerInfo } from './api';
import { supportsHeic } from './heic';
import { sortByLocalTime } from './dates';

class AppState {
	/** All photos, oldest first (Photos-style: newest at the bottom). */
	assets = $state.raw<CatalogAsset[]>([]);
	folders = $state.raw<FolderNode[]>([]);
	albums = $state.raw<CatalogAlbum[]>([]);
	uploadsConfigured = $state(false);
	byId = $derived(new Map(this.assets.map((a) => [a.id, a])));
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

	async init() {
		if (this.started) return;
		this.started = true;
		this.fmt = (await supportsHeic()) ? 'heic' : 'jpeg';
		await this.reload();
	}

	async reload() {
		try {
			const health = await api.health();
			this.server = health;
			this.libraryConfigured = health.libraryConfigured;
			this.uploadsConfigured = health.uploadsConfigured;
			if (health.apiVersion !== CLIENT_API_VERSION) this.updateRequired = true;
			const snap = await api.catalog();
			if (snap.format !== CATALOG_FORMAT) this.updateRequired = true;
			this.assets = sortByLocalTime(snap.assets);
			this.folders = snap.folders;
			this.albums = snap.albums;

			this.error = null;
		} catch (e) {
			this.error = e instanceof Error ? e.message : String(e);
		} finally {
			this.loaded = true;
		}
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
