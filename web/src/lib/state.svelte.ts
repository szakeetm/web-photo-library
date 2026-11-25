import { version } from '$app/env';
import { api, onServerApiVersion, CLIENT_API_VERSION, CATALOG_FORMAT, type CatalogAsset, type FolderNode, type ImageFmt, type ServerInfo } from './api';
import { supportsHeic } from './heic';
import { sortByLocalTime } from './dates';

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
			if (health.apiVersion !== CLIENT_API_VERSION) this.updateRequired = true;
			const snap = await api.catalog();
			if (snap.format !== CATALOG_FORMAT) this.updateRequired = true;
			this.assets = sortByLocalTime(snap.assets);
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
