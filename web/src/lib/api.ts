// Typed wrappers for the PhotoServer HTTP API.

export type ImageFmt = 'heic' | 'jpeg';

/** API contract version this client was built against. Must equal the server's `apiVersion`; otherwise the app must update. */
export const CLIENT_API_VERSION = 2;
/** Catalog payload format this client understands. */
export const CATALOG_FORMAT = 2;

/** Called with the server's API version from every response. */
let versionListener: ((serverApi: number, updateRequired: boolean) => void) | undefined;
export function onServerApiVersion(fn: typeof versionListener) {
	versionListener = fn;
}

export interface CatalogAsset {
	id: string;
	w: number;
	h: number;
	t: string; // capture instant, ISO-8601 UTC
	tz: number | null; // seconds east of UTC
	fav: boolean;
	bh: string | null; // BlurHash
	ev: number; // edit version
	folders: number[];
	name: string;
}

export interface ServerInfo {
	ok: boolean;
	version: string;
	apiVersion: number;
	webVersion: string | null;
	libraryConfigured: boolean;
}

export interface FolderNode {
	id: number;
	root: 'library' | 'uploads';
	parentId: number | null;
	name: string;
	relPath: string;
	count: number;
	coverId: string | null;
}

export interface CatalogAlbum {
	id: number;
	title: string;
	coverId: string | null;
	source: 'user' | 'takeout';
	assetIds: string[];
}

export interface CatalogSnapshot {
	format: number;
	seq: number;
	assets: CatalogAsset[];
	folders: FolderNode[];
	albums: CatalogAlbum[];
}

export interface AlbumSummary {
	id: number;
	title: string;
	count: number;
	coverId: string | null;
	source: string;
}

export interface Asset {
	id: string;
	width: number;
	height: number;
	mime: string;
	takenAt: string;
	tzOffset: number | null;
	dateSource: string;
	lat: number | null;
	lon: number | null;
	locationSource: string | null;
	cameraMake: string | null;
	cameraModel: string | null;
	lens: string | null;
	iso: number | null;
	aperture: number | null;
	shutter: number | null;
	focal: number | null;
	description: string | null;
	favorite: boolean;
	editVersion: number;
}

export interface AssetDetail {
	asset: Asset;
	files: string[];
}

export interface Settings {
	libraryPath: string | null;
	uploadsPath: string | null;
	ownerLogin: string | null;
	dataDir: string;
	cacheBytes: number;
	databaseBytes: number;
	dataLocationMissing: boolean;
}

export interface Job {
	id: number;
	kind: string;
	state: 'queued' | 'running' | 'done' | 'failed' | 'cancelled';
	phase: string | null;
	progress: number;
	total: number;
	message: string | null;
	error: string | null;
	startedAt: string | null;
	endedAt: string | null;
}

export interface DirListing {
	path: string;
	parent: string | null;
	entries: { name: string; path: string; readable: boolean }[];
}

export type JobKind = 'detect-changes' | 'reindex' | 'rebuild-caches' | 'purge-missing' | 'import-takeout-albums';

export class ApiError extends Error {
	constructor(
		public status: number,
		message: string
	) {
		super(message);
	}
}

async function call<T>(path: string, init?: RequestInit): Promise<T> {
	const res = await fetch(path, {
		...init,
		headers: {
			'X-Client-API-Version': String(CLIENT_API_VERSION),
			...(init?.body ? { 'content-type': 'application/json' } : {}),
			...init?.headers
		}
	});
	const serverApi = Number(res.headers.get('X-API-Version'));
	if (serverApi) versionListener?.(serverApi, res.status === 426);
	if (!res.ok) {
		let message = res.statusText;
		try {
			message = (await res.json()).error ?? message;
		} catch {
			/* not json */
		}
		throw new ApiError(res.status, message);
	}
	if (res.status === 204) return undefined as T;
	return res.json() as Promise<T>;
}

export const thumbUrl = (id: string, ev: number, fmt: ImageFmt) => `/api/thumb/${id}?e=${ev}&fmt=${fmt}`;
export const previewUrl = (id: string, ev: number, fmt: ImageFmt) => `/api/preview/${id}?e=${ev}&fmt=${fmt}`;
export const originalUrl = (id: string) => `/api/assets/${id}/original`;

export const api = {
	health: (signal?: AbortSignal) =>
		call<ServerInfo>('/api/health', { signal }),
	catalog: () => call<CatalogSnapshot>('/api/catalog'),
	asset: (id: string) => call<AssetDetail>(`/api/assets/${id}`),
	settings: () => call<Settings>('/api/settings'),
	saveSettings: (s: { libraryPath?: string; uploadsPath?: string; ownerLogin?: string }) =>
		call<Settings>('/api/settings', { method: 'PUT', body: JSON.stringify(s) }),
	moveData: (path: string) =>
		call<{ dataDir: string; restarting: boolean }>('/api/data/move', { method: 'POST', body: JSON.stringify({ path }) }),
	resetDataLocation: () => call<{ dataDir: string; restarting: boolean }>('/api/data/reset', { method: 'POST' }),
	listDir: (path?: string) => call<DirListing>(`/api/fs/list${path ? `?path=${encodeURIComponent(path)}` : ''}`),
	jobs: () => call<{ current: Job | null; recent: Job[] }>('/api/jobs'),
	startJob: (kind: JobKind) => call<{ id: number }>(`/api/jobs/${kind}`, { method: 'POST' }),
	cancelJob: (id: number) => call<void>(`/api/jobs/${id}`, { method: 'DELETE' }),
	createAlbum: (title: string, assetIds: string[] = []) =>
		call<AlbumSummary>('/api/albums', { method: 'POST', body: JSON.stringify({ title, assetIds }) }),
	updateAlbum: (id: number, patch: { title?: string; coverAssetId?: string }) =>
		call<AlbumSummary>(`/api/albums/${id}`, { method: 'PATCH', body: JSON.stringify(patch) }),
	deleteAlbum: (id: number) => call<void>(`/api/albums/${id}`, { method: 'DELETE' }),
	albumAssets: (id: number, change: { add?: string[]; remove?: string[]; order?: string[] }) =>
		call<AlbumSummary>(`/api/albums/${id}/assets`, { method: 'POST', body: JSON.stringify(change) }),
	setFavorite: (ids: string[], favorite: boolean) =>
		call<void>('/api/assets', { method: 'PATCH', body: JSON.stringify({ ids, favorite }) }),
	search: (q: string, signal?: AbortSignal) =>
		call<{ ids: string[] }>(`/api/search?q=${encodeURIComponent(q)}`, { signal })
};
