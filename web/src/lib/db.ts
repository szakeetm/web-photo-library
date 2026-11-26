// On-device database (IndexedDB), shared by the page and the service worker.
import type { ListHashes } from './api';
import { openDB, type DBSchema, type IDBPDatabase } from 'idb';
import type { CatalogAsset, CatalogAlbum, FolderNode } from './api';

export interface CatalogMeta {
	format: number;
	catalogId: string;
	seq: number;
	/** Digests of the stored folder/people/place lists (sent back so unchanged lists aren't resent). */
	hashes?: ListHashes;
}

/** One cached image (thumbnail or preview) in Cache Storage. */
export interface ImageEntry {
	/** Same-origin path + query, e.g. `/api/thumb/<id>?e=0&fmt=heic&r=2`. */
	url: string;
	bytes: number;
	lastAccess: number;
	/** Downloads that keep this image (never evicted while non-empty): album ids, and −folder id for folders. */
	pins: number[];
}

/** A downloaded album or folder (thumbnails and previews of its photos kept on the device). */
export interface PinRecord {
	/** The pin id (the store's key): an album's id, or −id of a folder. */
	albumId: number;
	/** Set for a folder download (photos of the folder and all its subfolders). */
	folder?: { root: 'library' | 'uploads'; relPath: string };
	title: string;
	state: 'downloading' | 'done';
	total: number;
	done: number;
	bytes: number;
	updatedAt: number;
}

export interface PhotosSchema extends DBSchema {
	meta: { key: string; value: unknown };
	assets: { key: string; value: CatalogAsset };
	images: { key: string; value: ImageEntry; indexes: { lastAccess: number } };
	pins: { key: number; value: PinRecord };
}

export type DB = IDBPDatabase<PhotosSchema>;

let dbPromise: Promise<DB> | undefined;

export function db(): Promise<DB> {
	dbPromise ??= openDB<PhotosSchema>('photos', 1, {
		upgrade(d) {
			d.createObjectStore('meta');
			d.createObjectStore('assets', { keyPath: 'id' });
			d.createObjectStore('images', { keyPath: 'url' }).createIndex('lastAccess', 'lastAccess');
			d.createObjectStore('pins', { keyPath: 'albumId' });
		}
	});
	return dbPromise;
}

/** Tests: forget the open connection (fake-indexeddb is reset between tests). */
export async function resetDbForTests() {
	const open = dbPromise;
	dbPromise = undefined;
	(await open)?.close();
}

export type { CatalogAsset, CatalogAlbum, FolderNode };
