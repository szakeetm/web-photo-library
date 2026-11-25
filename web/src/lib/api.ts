// Typed wrappers for the PhotoServer HTTP API.

export type ImageFmt = 'heic' | 'jpeg';

/** API contract version this client was built against. Must equal the server's `apiVersion`; otherwise the app must update. */
export const CLIENT_API_VERSION = 5;
/** Catalog payload format this client understands. */
export const CATALOG_FORMAT = 5;

/** Called with the server's API version from every response. */
let versionListener: ((serverApi: number, updateRequired: boolean) => void) | undefined;
export function onServerApiVersion(fn: typeof versionListener) {
	versionListener = fn;
}

/** Called when a request fails without reaching the server (offline, server down). */
let networkListener: (() => void) | undefined;
export function onNetworkError(fn: typeof networkListener) {
	networkListener = fn;
}

/** A deleted upload waiting in the Trash. */
export interface TrashItem {
	asset: CatalogAsset;
	/** ISO-8601 UTC */
	trashedAt: string;
}

/** Days a deleted upload stays in the Trash before it is deleted for good (server UploadTrash.keepDays). */
export const TRASH_KEEP_DAYS = 30;

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
	/** [lat, lon] */
	loc?: [number, number] | null;
	/** place id */
	pl?: number | null;
	/** person ids */
	pp?: number[] | null;
	/** video duration in seconds (videos only) */
	dur?: number;
	/** the photo has a Live Photo motion clip */
	live?: boolean;
}

export interface CatalogPerson {
	id: number;
	name: string | null;
	coverFaceId: number | null;
	count: number;
	hidden: boolean;
}

export interface CatalogPlace {
	id: number;
	name: string;
	region: string | null;
	country: string;
	cc: string;
	lat: number;
	lon: number;
}

export interface FaceInfo {
	id: number;
	assetId: string;
	personId: number | null;
	x: number;
	y: number;
	w: number;
	h: number;
}

export interface ServerInfo {
	ok: boolean;
	version: string;
	apiVersion: number;
	webVersion: string | null;
	libraryConfigured: boolean;
	uploadsConfigured: boolean;
	mapStyleURL: string;
	commit: string | null;
	commitDate: string | null;
	dirty: boolean;
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
	catalogId: string;
	seq: number;
	assets: CatalogAsset[];
	folders: FolderNode[];
	albums: CatalogAlbum[];
	people: CatalogPerson[];
	places: CatalogPlace[];
}

export interface CatalogDelta {
	format: number;
	catalogId: string;
	seq: number;
	/** The replica can't be updated: download the snapshot instead. */
	reset: boolean;
	assets: CatalogAsset[];
	deleted: string[];
	folders?: FolderNode[];
	albums?: CatalogAlbum[];
	people?: CatalogPerson[];
	places?: CatalogPlace[];
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
	kind: 'photo' | 'video';
	/** seconds (videos only) */
	duration: number | null;
	videoCodec: string | null;
}

export interface AssetDetail {
	asset: Asset;
	files: string[];
	faces: FaceInfo[];
	place: CatalogPlace | null;
}

export interface Settings {
	libraryPath: string | null;
	uploadsPath: string | null;
	ownerLogin: string | null;
	dataDir: string;
	cacheBytes: number;
	databaseBytes: number;
	dataLocationMissing: boolean;
	facesEnabled: boolean;
	faceModelInstalled: boolean;
	faceModelPath: string;
	mapStyleURL: string | null;
	defaultMapStyleURL: string;
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

export interface EditVersion {
	version: number;
	recipe: import('./editor/recipe').Recipe;
	createdAt: string;
}

export interface EditHistory {
	current: number;
	versions: EditVersion[];
}

export type JobKind = 'detect-changes' | 'reindex' | 'rebuild-caches' | 'purge-missing' | 'import-takeout-albums' | 'faces' | 'recluster';

export class ApiError extends Error {
	constructor(
		public status: number,
		message: string
	) {
		super(message);
	}
}

async function call<T>(path: string, init?: RequestInit): Promise<T> {
	let res: Response;
	try {
		res = await send(path, init);
	} catch (e) {
		// A cancelled request says nothing about the server; a timeout or network failure does.
		if (!(e instanceof DOMException && e.name === 'AbortError')) networkListener?.();
		throw e;
	}
	return handle<T>(res);
}

function send(path: string, init?: RequestInit) {
	return fetch(path, {
		...init,
		headers: {
			'X-Client-API-Version': String(CLIENT_API_VERSION),
			...(init?.body ? { 'content-type': 'application/json' } : {}),
			...init?.headers
		}
	});
}

async function handle<T>(res: Response): Promise<T> {
	const serverApi = Number(res.headers.get('X-API-Version'));
	if (serverApi) versionListener?.(serverApi, res.status === 426);
	// Tailscale answers 502 when the Mac is reachable but the server isn't running.
	else if (res.status >= 502 && res.status <= 504) networkListener?.();
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

/** The server's derivative revision (DerivativeStore.revision): images are cached as immutable, so a new
 *  revision (2: HDR gain maps) needs new URLs. */
const REVISION = 2;
export const thumbUrl = (id: string, ev: number, fmt: ImageFmt) => `/api/thumb/${id}?e=${ev}&fmt=${fmt}&r=${REVISION}`;
export const previewUrl = (id: string, ev: number, fmt: ImageFmt) => `/api/preview/${id}?e=${ev}&fmt=${fmt}&r=${REVISION}`;
export const originalUrl = (id: string) => `/api/assets/${id}/original`;
/** The photo's HDR gain map for the editor (204 for SDR photos). */
export const gainMapUrl = (id: string) => `/api/gainmap/${id}?r=${REVISION}`;
/** Full-resolution render of the current edit (made on demand on the Mac). */
export const faceThumbUrl = (faceId: number) => `/api/faces/${faceId}/thumb`;
export const videoUrl = (id: string) => `/api/assets/${id}/video`;
export const videoStatusUrl = (id: string) => `/api/assets/${id}/video/status`;
/** The converted copy of a video that needed one, as a download. */
export const videoDownloadUrl = (id: string) => `/api/assets/${id}/video/download`;
export const motionUrl = (id: string) => `/api/assets/${id}/motion`;
export const exportUrl = (id: string, fmt: ImageFmt) => `/api/assets/${id}/export?fmt=${fmt}`;

/** Preview conversion of a video (or Live Photo clip), as the server reports it. */
export interface VideoStatus {
	state: 'ready' | 'converting' | 'queued' | 'failed' | 'unavailable';
	progress?: number;
	error?: string;
}

/** Library-wide "convert all videos" job. */
export interface ConvertAllState {
	state: 'idle' | 'running' | 'paused';
	done: number;
	total: number;
	current?: string | null;
	progress?: number | null;
	needed: number;
	converted: number;
	bytes: number;
	ffmpeg: boolean;
}

export const api = {
	health: (signal?: AbortSignal) =>
		call<ServerInfo>('/api/health', { signal }),
	catalog: () => call<CatalogSnapshot>('/api/catalog'),
	changes: (since: number, catalogId: string) =>
		call<CatalogDelta>(`/api/catalog/changes?since=${since}&catalog=${encodeURIComponent(catalogId)}`),
	videoStatus: (id: string) => call<{ status: VideoStatus }>(videoStatusUrl(id)).then((r) => r.status),
	/** Whether a converted copy of the video exists (to download beside the original). */
	videoConverted: (id: string) => call<{ converted?: boolean }>(videoStatusUrl(id)).then((r) => r.converted === true),
	videos: () => call<ConvertAllState>('/api/videos'),
	convertAll: () => call<ConvertAllState>('/api/videos/convert-all', { method: 'POST' }),
	pauseConversion: () => call<ConvertAllState>('/api/videos/pause', { method: 'POST' }),
	asset: (id: string) => call<AssetDetail>(`/api/assets/${id}`),
	settings: () => call<Settings>('/api/settings'),
	saveSettings: (s: { libraryPath?: string; uploadsPath?: string; ownerLogin?: string; facesEnabled?: boolean; mapStyleURL?: string }) =>
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
	/** Moves uploaded photos to the Trash; the server refuses anything in the library. */
	deleteUploads: (ids: string[]) =>
		call<{ deleted: string[] }>('/api/uploads/delete', { method: 'POST', body: JSON.stringify({ ids }) }),
	trash: () => call<TrashItem[]>('/api/trash'),
	restoreTrash: (ids: string[]) =>
		call<{ deleted: string[] }>('/api/trash/restore', { method: 'POST', body: JSON.stringify({ ids }) }),
	/** Deletes Trash items for good (their files go to the macOS Trash); all of them without ids. */
	deleteForever: (ids?: string[]) =>
		call<{ deleted: string[] }>('/api/trash/delete', { method: 'POST', body: JSON.stringify({ ids }) }),
	updatePerson: (id: number, patch: { name?: string | null; hidden?: boolean; coverFaceId?: number }) =>
		call<void>(`/api/people/${id}`, { method: 'PATCH', body: JSON.stringify(patch) }),
	mergePeople: (ids: number[], into: number) => call<void>('/api/people/merge', { method: 'POST', body: JSON.stringify({ ids, into }) }),
	createPerson: (name: string, faceIds: number[]) =>
		call<{ id: number }>('/api/people', { method: 'POST', body: JSON.stringify({ name, faceIds }) }),
	personFaces: (id: number) => call<FaceInfo[]>(`/api/people/${id}/faces`),
	assignFace: (faceId: number, personId: number | null) =>
		call<void>(`/api/faces/${faceId}`, { method: 'PATCH', body: JSON.stringify({ personId }) }),
	edits: (id: string) => call<EditHistory>(`/api/assets/${id}/edits`),
	saveEdit: (id: string, recipe: import('./editor/recipe').Recipe) =>
		call<{ asset: CatalogAsset }>(`/api/assets/${id}/edits`, { method: 'POST', body: JSON.stringify({ recipe }) }),
	revertEdit: (id: string) => call<{ asset: CatalogAsset }>(`/api/assets/${id}/revert`, { method: 'POST' }),
	autoEnhance: (id: string) =>
		call<{ recipe: import('./editor/recipe').Recipe }>(`/api/assets/${id}/auto-enhance`, { method: 'POST' }),
	search: (q: string, signal?: AbortSignal) =>
		call<{ ids: string[] }>(`/api/search?q=${encodeURIComponent(q)}`, { signal })
};
