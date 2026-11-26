// Typed wrappers for the PhotoServer HTTP API.
import { playsHevc } from './platform';

export type ImageFmt = 'heic' | 'jpeg';

/** API contract version this client was built against. Must equal the server's `apiVersion`; otherwise the app must update. */
export const CLIENT_API_VERSION = 8;
/** Catalog payload format this client understands. */
export const CATALOG_FORMAT = 9;

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
	/** only hidden: its files (not uploads) are where they were */
	virtual: boolean;
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
	/** the user changed the date (kept on the server, applied on export) */
	md?: boolean;
	/** media flags: 1 screenshot, 2 selfie, 4 portrait */
	mf?: number;
	/** date added (seconds since 1970) */
	ad?: number;
	/** video trim [start, end] in seconds (applied when playing and exporting) */
	tr?: [number, number];
}

/** A date change for several photos: the instant moves by `shift` seconds; with `tzOffset` they get
 * that time zone, keeping their wall-clock time (`keepWallClock`) or their instant. */
/** Copies of the same picture (re-saved, resized, converted). */
export interface DuplicateGroup {
	key: string;
	kind: 'same';
	items: DuplicateItem[];
}

export interface DuplicateItem {
	id: string;
	w: number;
	h: number;
	t: string;
	tz: number | null;
	bytes: number;
	mime: string;
	path: string;
	root: RootName;
	fav: boolean;
	albums: number;
}

/** What to export (see the server's ExportOptions). */
export interface ExportOptions {
	ids?: string[];
	albums?: number[];
	library?: boolean;
	content: 'original' | 'edited' | 'both';
	editFormat: ImageFmt;
	livePhotoVideo: boolean;
	sidecar: 'none' | 'google' | 'xmp';
	organize: 'flat' | 'albums' | 'years' | 'months';
}

export interface ExportStatus {
	id: string;
	name: string;
	state: 'ready' | 'running' | 'done' | 'failed' | 'cancelled';
	done: number;
	total: number;
	error: string | null;
	folder: string | null;
	/** estimated size (edited files counted at their original's size) */
	bytes: number;
	/** files that weren't available (the first 100), and how many */
	skipped: string[];
	skippedCount: number;
}

/** How big an export would be, and whether this device may have it as a ZIP. */
export interface ExportEstimate {
	files: number;
	/** photos and videos */
	items: number;
	bytes: number;
	zip: boolean;
	zipLimitItems: number;
	zipLimitBytes: number;
}

/** One file of an export the browser writes into a folder itself. */
export interface ExportEntryInfo {
	path: string;
	bytes: number;
	modified: number;
	/** `bytes` is exact (copied as it is), not an estimate */
	exact: boolean;
}

/** The streamed ZIP of an export (downloadable once). */
export const exportDownloadUrl = (id: string) => `/api/exports/${id}/download`;
/** One file of a "files" export (410: not available, skip it). */
export const exportEntryUrl = (id: string, n: number) => `/api/exports/${id}/entries/${n}`;

/** The trim editor's filmstrip (frames side by side in one image). */
export const framesUrl = (id: string, n = 12) => `/api/assets/${id}/frames?n=${n}`;

export interface DateChange {
	shift: number;
	/** ISO instant: all photos get this time (instead of a shift) */
	setTo?: string;
	tzOffset?: number | null;
	keepWallClock?: boolean;
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
	/** This browser runs on the server's own Mac. */
	local?: boolean;
	commit: string | null;
	commitDate: string | null;
	dirty: boolean;
}

/** Where files are: the library folder on the Mac, the uploads folder, or a source on an rclone remote. */
export type RootName = 'library' | 'uploads' | `remote-${number}` | `photos-${number}` | `folder-${number}`;
/** A source shown under its own name (another folder on the Mac, a Photos library, an rclone folder). */
export const isNamedRoot = (r: string) => r !== 'library' && r !== 'uploads';
export const isRemoteRoot = (r: string): r is `remote-${number}` => r.startsWith('remote-');
/** An Apple Photos library: its folders (originals/0…F) mean nothing, so it's shown as one. */
export const isPhotosRoot = (r: string): r is `photos-${number}` => r.startsWith('photos-');

export interface FolderNode {
	id: number;
	root: RootName;
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
	hashes: ListHashes;
}

export interface CatalogDelta {
	format: number;
	catalogId: string;
	seq: number;
	/** The replica can't be updated: download the snapshot instead. */
	reset: boolean;
	assets: CatalogAsset[];
	deleted: string[];
	/** Left out when unchanged (the client's hashes match). */
	folders?: FolderNode[];
	/** Albums created or changed since `since`. */
	albums?: CatalogAlbum[];
	deletedAlbums?: number[];
	people?: CatalogPerson[];
	places?: CatalogPlace[];
	hashes?: ListHashes;
}

export interface ListHashes {
	folders: string;
	people: string;
	places: string;
}

/** Bytes of a download so far (total from Content-Length, 0 when unknown). */
export interface DownloadProgress {
	received: number;
	total: number;
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
	/** the date read from the file (takenAt is the user's date when dateSource is 'user') */
	fileTakenAt?: string | null;
	fileTzOffset?: number | null;
	fileDateSource?: string | null;
}

export interface AssetDetail {
	asset: Asset;
	files: string[];
	faces: FaceInfo[];
	place: CatalogPlace | null;
	/** Things recognised in the photo, most confident first. */
	objects?: ObjectTag[];
	/** Text recognised in the photo. */
	text?: string | null;
}

export interface ObjectTag {
	id: number;
	/** Vision's identifier, e.g. "sea_lion": show with objectName(). */
	name: string;
}

export interface ObjectLabel extends ObjectTag {
	count: number;
	coverId: string | null;
}

/** "sea_lion" → "Sea lion" */
export const objectName = (name: string) => {
	const s = name.replace(/_/g, ' ');
	return s.charAt(0).toUpperCase() + s.slice(1);
};

export interface Settings {
	libraryPath: string | null;
	uploadsPath: string | null;
	ownerLogin: string | null;
	dataDir: string;
	cacheBytes: number;
	/** Cache size by kind (thumb, preview, video, faces, exports…), largest first. */
	cacheParts?: { name: string; bytes: number }[];
	databaseBytes: number;
	dataLocationMissing: boolean;
	facesEnabled: boolean;
	/** objects, text and duplicate fingerprints */
	objectsEnabled: boolean;
	faceModelInstalled: boolean;
	faceModelPath: string;
	mapStyleURL: string | null;
	defaultMapStyleURL: string;
	/** Photos and videos still waiting for Analyse photos (objects, text, duplicates), out of all of them. */
	analysisPending: number;
	analysisTotal: number;
	/** rclone on the server (backups, remote sources); null when it isn't installed */
	rclone: RcloneInfo | null;
	/** library folders on rclone remotes */
	remoteSources: RemoteSourceInfo[];
	/** Apple Photos libraries on the Mac */
	photosLibraries: PhotosLibraryInfo[];
	/** more library folders on the Mac */
	localFolders: { id: number; path: string; root: `folder-${number}`; title: string; files: number; bytes: number; lastScan: SourceScan | null }[];
	libraryFiles: number;
	libraryLastScan: SourceScan | null;
	/** the uploads folder, a source of its own when set */
	uploadsFiles: number;
	uploadsBytes: number;
	uploadsLastScan: SourceScan | null;
	/** remote originals kept on the Mac: the limit (GB), and what they take now */
	originalsCacheGB: number;
	originalsCacheBytes: number;
}

export interface PhotosLibraryInfo {
	id: number;
	/** the .photoslibrary */
	path: string;
	root: `photos-${number}`;
	title: string;
	files: number;
	bytes: number;
	/** what the last scan found: own photos (not deleted or hidden), how many have their original on the Mac, albums */
	stats: { items: number; onDisk: number; albums: number; scannedAt: string } | null;
	lastScan: SourceScan | null;
}

/** How the last scan of a source went. */
export interface SourceScan {
	root: string;
	at: string;
	ok: boolean;
	added: number;
	updated: number;
	removed: number;
	unchanged: number;
	problems: number;
	note: string | null;
}

export interface RemoteSourceInfo {
	id: number;
	/** rclone path, "remote:folder" */
	path: string;
	root: `remote-${number}`;
	title: string;
	/** photo and video files indexed from it */
	files: number;
	bytes: number;
	lastScan: SourceScan | null;
}

export interface RcloneInfo {
	path: string;
	version: string;
}

/** How a backup went. */
export interface BackupReport {
	startedAt: string;
	finishedAt: string;
	ok: boolean;
	error?: string | null;
	destination: string;
	databaseBytes: number;
	assets: number;
	albums: number;
	uploadsFiles: number;
	uploadsBytes: number;
	/** uploads copied this time (new or changed) */
	uploadsCopied: number;
	/** uploads removed from the backup this time (deleted here) */
	uploadsDeleted: number;
}

export interface BackupActivity {
	kind: 'backup' | 'restore';
	phase: string;
	startedAt: string;
	files: number;
}

export interface BackupStatus {
	rclone: RcloneInfo | null;
	enabled: boolean;
	/** an rclone path: "remote:folder" */
	destination: string;
	defaultDestination: string;
	intervalHours: number;
	last: BackupReport | null;
	activity: BackupActivity | null;
	nextAt: string | null;
	/** what there is to back up now */
	local: { databaseBytes: number; assets: number; albums: number; uploadsFiles: number; uploadsBytes: number };
	restoreError: string | null;
}

export interface BackupSource {
	root: string;
	kind: 'local' | 'rclone';
	path: string;
	files: number;
}

export interface BackupManifest {
	createdAt: string;
	serverVersion: string;
	databaseBytes: number;
	assets: number;
	albums: number;
	sources: BackupSource[];
	uploadsFiles: number;
	uploadsBytes: number;
}

/** A backup looked at before restoring it. */
export interface BackupInspection {
	location: string;
	manifest: BackupManifest | null;
	databaseBytes: number;
	uploadsFiles: number;
	uploadsBytes: number;
	uploadsTarget: string | null;
	checks: { title: string; ok: boolean; detail: string }[];
	canRestore: boolean;
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
	/** what it is doing right now, in words (e.g. which folder is downloading) */
	detail?: string | null;
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

export type JobKind = 'detect-changes' | 'reindex' | 'rebuild-caches' | 'purge-missing' | 'import-takeout-albums' | 'faces' | 'recluster' | 'objects';

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
/** A Google Takeout album folder, for choosing which become albums. */
export interface TakeoutAlbum {
	/** "<root>:<relPath>" */
	key: string;
	title: string;
	/** the source's path, then the folder within it */
	path: string;
	/** photos and videos in the folder */
	count: number;
	/** the album made from it earlier */
	albumId: number | null;
	/** photos the album doesn't have yet (all of them when not imported) */
	missing: number;
}

export const faceThumbUrl = (faceId: number) => `/api/faces/${faceId}/thumb`;
/** `h264=1`: this browser can't decode HEVC, so the server sends H.264 (originals or copies it makes). */
const h264 = (sep: '?' | '&') => (playsHevc ? '' : `${sep}h264=1`);
export const videoUrl = (id: string, original = false) =>
	`/api/assets/${id}/video${original ? `?original=1${h264('&')}` : h264('?')}`;
export const videoStatusUrl = (id: string) => `/api/assets/${id}/video/status${h264('?')}`;
/** The converted copy of a video that needed one, as a download. */
export const videoDownloadUrl = (id: string) => `/api/assets/${id}/video/download`;
export const motionUrl = (id: string) => `/api/assets/${id}/motion${h264('?')}`;
export const exportUrl = (id: string, fmt: ImageFmt) => `/api/assets/${id}/export?fmt=${fmt}`;
/** A Live Photo's motion clip as a file (the original MOV, named like the still). */
export const motionDownloadUrl = (id: string) => `/api/assets/${id}/motion/download`;

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
	/** converted files not played for this many days are deleted (null = kept) */
	keepDays?: number | null;
}

export const api = {
	health: (signal?: AbortSignal) =>
		call<ServerInfo>('/api/health', { signal }),
	/** The whole catalog (tens of MB for a big library), reporting download progress. */
	catalog: async (onProgress?: (p: DownloadProgress) => void) => {
		let res: Response;
		try {
			res = await send('/api/catalog');
		} catch (e) {
			networkListener?.();
			throw e;
		}
		if (!res.ok || !res.body || !onProgress) return handle<CatalogSnapshot>(res);
		const total = Number(res.headers.get('content-length')) || 0;
		const reader = res.body.getReader();
		const chunks: Uint8Array[] = [];
		let received = 0;
		onProgress({ received, total });
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			chunks.push(value);
			received += value.length;
			onProgress({ received, total });
		}
		const body = new Uint8Array(received);
		let at = 0;
		for (const c of chunks) {
			body.set(c, at);
			at += c.length;
		}
		return handle<CatalogSnapshot>(new Response(body, { status: res.status, headers: res.headers }));
	},
	changes: (since: number, catalogId: string, have?: ListHashes) =>
		call<CatalogDelta>(
			`/api/catalog/changes?since=${since}&catalog=${encodeURIComponent(catalogId)}` +
				(have ? `&have=${have.folders},${have.people},${have.places}` : '')
		),
	videoStatus: (id: string) => call<{ status: VideoStatus }>(videoStatusUrl(id)).then((r) => r.status),
	/** Whether a converted copy of the video exists (to download beside the original). */
	videoConverted: (id: string) => call<{ converted?: boolean }>(videoStatusUrl(id)).then((r) => r.converted === true),
	videos: () => call<ConvertAllState>('/api/videos'),
	convertAll: () => call<ConvertAllState>('/api/videos/convert-all', { method: 'POST' }),
	pauseConversion: () => call<ConvertAllState>('/api/videos/pause', { method: 'POST' }),
	/** How long converted videos nobody plays are kept (1, 7 or 30 days; null = forever). */
	setVideoCache: (keepDays: number | null) =>
		call<ConvertAllState>('/api/videos/cache', { method: 'PUT', body: JSON.stringify({ keepDays }) }),
	asset: (id: string) => call<AssetDetail>(`/api/assets/${id}`),
	settings: () => call<Settings>('/api/settings'),
	addSource: (path: string) => call<Settings>('/api/sources', { method: 'POST', body: JSON.stringify({ path }) }),
	removeSource: (id: number) => call<Settings>(`/api/sources/${id}`, { method: 'DELETE' }),
	addLocalFolder: (path: string) => call<Settings>('/api/local-folders', { method: 'POST', body: JSON.stringify({ path }) }),
	removeLocalFolder: (id: number) => call<Settings>(`/api/local-folders/${id}`, { method: 'DELETE' }),
	relocateLocalFolder: (id: number, path: string) =>
		call<Settings>(`/api/local-folders/${id}`, { method: 'PUT', body: JSON.stringify({ path }) }),
	relocateLibraryFolder: (path: string) => call<Settings>('/api/library-folder', { method: 'PUT', body: JSON.stringify({ path }) }),
	relocateSource: (id: number, path: string) => call<Settings>(`/api/sources/${id}`, { method: 'PUT', body: JSON.stringify({ path }) }),
	removeLibraryFolder: () => call<Settings>('/api/library-folder', { method: 'DELETE' }),
	addPhotosLibrary: (path: string) => call<Settings>('/api/photos-libraries', { method: 'POST', body: JSON.stringify({ path }) }),
	removePhotosLibrary: (id: number) => call<Settings>(`/api/photos-libraries/${id}`, { method: 'DELETE' }),
	backup: () => call<BackupStatus>('/api/backup'),
	setBackup: (patch: { enabled?: boolean; destination?: string; intervalHours?: number }) =>
		call<BackupStatus>('/api/backup', { method: 'PUT', body: JSON.stringify(patch) }),
	runBackup: () => call<BackupStatus>('/api/backup/run', { method: 'POST' }),
	inspectBackup: (location: string) => call<BackupInspection>(`/api/backup/inspect?location=${encodeURIComponent(location)}`),
	restoreBackup: (location: string) =>
		call<BackupStatus>('/api/backup/restore', { method: 'POST', body: JSON.stringify({ location }) }),
	rcloneRemotes: () => call<string[]>('/api/rclone/remotes'),
	rcloneFolders: (path: string) => call<{ path: string; folders: string[] }>(`/api/rclone/folders?path=${encodeURIComponent(path)}`),
	rcloneMakeFolder: (path: string) =>
		call<{ path: string; folders: string[] }>('/api/rclone/folders', { method: 'POST', body: JSON.stringify({ path }) }),
	saveSettings: (s: {
		libraryPath?: string;
		uploadsPath?: string;
		ownerLogin?: string;
		facesEnabled?: boolean;
		objectsEnabled?: boolean;
		mapStyleURL?: string;
		originalsCacheGB?: number;
	}) =>
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
	/** Google Takeout album folders (with a metadata.json) in every source. */
	takeoutAlbums: () => call<TakeoutAlbum[]>('/api/takeout-albums'),
	/** Makes albums of the chosen Takeout folders (by key). */
	importTakeoutAlbums: (keys: string[]) =>
		call<{ created: number; updated: number }>('/api/takeout-albums/import', { method: 'POST', body: JSON.stringify({ keys }) }),
	deleteAlbum: (id: number) => call<void>(`/api/albums/${id}`, { method: 'DELETE' }),
	albumAssets: (id: number, change: { add?: string[]; remove?: string[]; order?: string[] }) =>
		call<AlbumSummary>(`/api/albums/${id}/assets`, { method: 'POST', body: JSON.stringify(change) }),
	changeDates: (ids: string[], change: DateChange) =>
		call<CatalogAsset[]>('/api/assets/meta', { method: 'PATCH', body: JSON.stringify({ ids, change }) }),
	revertDates: (ids: string[]) =>
		call<CatalogAsset[]>('/api/assets/meta/revert', { method: 'POST', body: JSON.stringify({ ids }) }),
	setFavorite: (ids: string[], favorite: boolean) =>
		call<void>('/api/assets', { method: 'PATCH', body: JSON.stringify({ ids, favorite }) }),
	/** Puts photos in the Trash: uploads are moved there, every other photo is only hidden (its files are never touched). */
	deletePhotos: (ids: string[]) =>
		call<{ deleted: string[] }>('/api/assets/delete', { method: 'POST', body: JSON.stringify({ ids }) }),
	trash: () => call<TrashItem[]>('/api/trash'),
	/** Recognised objects, most common first. */
	objects: () => call<ObjectLabel[]>('/api/objects'),
	setTrim: (id: string, start: number, end: number) =>
		call<{ asset: CatalogAsset }>(`/api/assets/${id}/trim`, { method: 'PUT', body: JSON.stringify({ start, end }) }),
	revertTrim: (id: string) => call<{ asset: CatalogAsset }>(`/api/assets/${id}/trim`, { method: 'DELETE' }),
	/** Save as New: a trimmed copy in the uploads folder, as a new video. */
	trimCopy: (id: string, start: number, end: number) =>
		call<{ asset: CatalogAsset }>(`/api/assets/${id}/trim/copy`, { method: 'POST', body: JSON.stringify({ start, end }) }),
	estimateExport: (options: ExportOptions) =>
		call<ExportEstimate>('/api/exports/estimate', { method: 'POST', body: JSON.stringify(options) }),
	exportEntries: (id: string) => call<ExportEntryInfo[]>(`/api/exports/${id}/entries`),
	startExport: (options: ExportOptions, target: 'zip' | 'folder' | 'files', folder?: string, name?: string) =>
		call<ExportStatus>('/api/exports', { method: 'POST', body: JSON.stringify({ options, target, folder, name }) }),
	exportStatus: (id: string) => call<ExportStatus>(`/api/exports/${id}`),
	cancelExport: (id: string) => call<void>(`/api/exports/${id}`, { method: 'DELETE' }),
	revealExport: (id: string) => call<void>(`/api/exports/${id}/reveal`, { method: 'POST' }),
	duplicates: () => call<DuplicateGroup[]>('/api/duplicates'),
	dismissDuplicates: (key: string) => call<void>('/api/duplicates/dismiss', { method: 'POST', body: JSON.stringify({ key }) }),
	/** The kept photo gets the others' albums and favourite (call before removing them). */
	mergeDuplicates: (keep: string, others: string[]) =>
		call<void>('/api/duplicates/merge', { method: 'POST', body: JSON.stringify({ keep, others }) }),
	objectAssets: (id: number) => call<{ label: ObjectTag; ids: string[] }>(`/api/objects/${id}`),
	/** Shows a photo/video (selected) or a folder in the Finder: only from a browser on the server's Mac. */
	reveal: (what: { asset: string } | { folder: number } | { place: 'uploads' | 'trash' }) =>
		call<void>('/api/reveal', { method: 'POST', body: JSON.stringify(what) }),
	restoreTrash: (ids: string[]) =>
		call<{ deleted: string[] }>('/api/trash/restore', { method: 'POST', body: JSON.stringify({ ids }) }),
	/** Deletes Trash items for good (their files are deleted from disk); all of them without ids. */
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
