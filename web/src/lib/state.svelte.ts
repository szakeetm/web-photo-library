import { version } from '$app/env';
import { api, onServerApiVersion, CLIENT_API_VERSION, CATALOG_FORMAT, type CatalogAsset, type FolderNode, type ImageFmt, type ServerInfo } from './api';
import { supportsHeic } from './heic';

class AppState {
	/** All photos, oldest first (Photos-style: newest at the bottom). */
	assets = $state.raw<CatalogAsset[]>([]);
	folders = $state.raw<FolderNode[]>([]);
	byId = $derived(new Map(this.assets.map((a) => [a.id, a])));
	fmt = $state<ImageFmt>('jpeg');
	loaded = $state(false);
	error = $state<string | null>(null);
	libraryConfigured = $state(true);
	server = $state<ServerInfo | null>(null);
	readonly clientVersion = version;
	/** 'required': server refuses this client; 'available': server is newer; 'older': server is older than this app. */
	compat = $state<'ok' | 'available' | 'required' | 'older'>('ok');

	constructor() {
		onServerApiVersion((serverApi, updateRequired) => {
			if (updateRequired) this.compat = 'required';
			else if (serverApi > CLIENT_API_VERSION) this.compat = 'available';
			else if (serverApi < CLIENT_API_VERSION) this.compat = 'older';
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
			if (health.minClientApiVersion > CLIENT_API_VERSION) this.compat = 'required';
			const snap = await api.catalog();
			if (snap.format !== CATALOG_FORMAT) this.compat = snap.format > CATALOG_FORMAT ? 'required' : 'older';
			this.assets = snap.assets.slice().reverse();
			this.folders = snap.folders;
			this.error = null;
		} catch (e) {
			this.error = e instanceof Error ? e.message : String(e);
		} finally {
			this.loaded = true;
		}
	}
}

export const app = new AppState();
