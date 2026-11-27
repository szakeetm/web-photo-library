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

/** One cached image (thumbnail, preview or Live Photo clip); its bytes are in the `blobs` store. */
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
	folder?: { root: import('./api.ts').RootName; relPath: string };
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
	/** The bytes of the cached images, by the same key as `images` (kept apart so listing entries doesn't read them). */
	blobs: { key: string; value: Blob };
	pins: { key: number; value: PinRecord };
}

export type DB = IDBPDatabase<PhotosSchema>;

let dbPromise: Promise<DB> | undefined;

export function db(): Promise<DB> {
	dbPromise ??= openDB<PhotosSchema>('photos', 2, {
		upgrade(d, oldVersion, _newVersion, tx) {
			if (oldVersion < 1) {
				d.createObjectStore('meta');
				d.createObjectStore('assets', { keyPath: 'id' });
				d.createObjectStore('images', { keyPath: 'url' }).createIndex('lastAccess', 'lastAccess');
				d.createObjectStore('pins', { keyPath: 'albumId' });
			}
			if (oldVersion < 2) {
				// Version 2: image bytes moved from Cache Storage (whose index iOS loads whole before a cold
				// launch can draw) to IndexedDB. The old ones aren't copied: they download again as needed,
				// and downloaded albums and folders fill up again on their next check.
				d.createObjectStore('blobs');
				if (oldVersion >= 1) {
					tx.objectStore('images').clear();
					tx.objectStore('meta').delete('cacheTotals');
				}
			}
		},
		// A newer app version wants to upgrade the database: let it (this one reloads on "Update now").
		blocking() {
			const open = dbPromise;
			dbPromise = undefined;
			open?.then((d) => d.close());
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
