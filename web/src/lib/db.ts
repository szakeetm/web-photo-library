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
	pins: { key: number; value: PinRecord };
}

export type DB = IDBPDatabase<PhotosSchema>;

/** The image cache: a database of its own. In WebKit a database is one SQLite file, and with a gigabyte
 *  of images beside it the catalog's 80,000 small records took a minute to read on a cold launch. */
export interface ImagesSchema extends DBSchema {
	/** what is cached, its size, last use and pins (small: eviction and usage read all of it) */
	images: { key: string; value: ImageEntry; indexes: { lastAccess: number } };
	/** the bytes, by the same key (apart, so listing entries doesn't read them) */
	blobs: { key: string; value: Blob };
	/** bytes per kind (`cacheTotals`) */
	meta: { key: string; value: unknown };
}

export type ImagesDB = IDBPDatabase<ImagesSchema>;

let dbPromise: Promise<DB> | undefined;

export function db(): Promise<DB> {
	dbPromise ??= openDB<PhotosSchema>('photos', 3, {
		upgrade(d, oldVersion, _newVersion, tx) {
			if (oldVersion < 1) {
				d.createObjectStore('meta');
				d.createObjectStore('assets', { keyPath: 'id' });
				d.createObjectStore('pins', { keyPath: 'albumId' });
			}
			// Version 3: the image cache moved to its own database (imagesDb), and its bytes from Cache
			// Storage (whose index WebKit loads whole before a cold launch can draw) into it. The old ones
			// aren't copied: they download again as needed, downloaded albums and folders on their next check.
			// (Version 2 had them in this database.)
			const untyped = d as unknown as IDBPDatabase;
			for (const store of ['images', 'blobs']) if (untyped.objectStoreNames.contains(store)) untyped.deleteObjectStore(store);
			if (oldVersion >= 1) void tx.objectStore('meta').delete('cacheTotals');
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

let imagesPromise: Promise<ImagesDB> | undefined;

export function imagesDb(): Promise<ImagesDB> {
	imagesPromise ??= openDB<ImagesSchema>('photos-images', 1, {
		upgrade(d) {
			d.createObjectStore('images', { keyPath: 'url' }).createIndex('lastAccess', 'lastAccess');
			d.createObjectStore('blobs');
			d.createObjectStore('meta');
		},
		blocking() {
			const open = imagesPromise;
			imagesPromise = undefined;
			open?.then((d) => d.close());
		}
	});
	return imagesPromise;
}

/** Tests: forget the open connections (fake-indexeddb is reset between tests). */
export async function resetDbForTests() {
	const open = [dbPromise, imagesPromise];
	dbPromise = imagesPromise = undefined;
	for (const p of open) (await p)?.close();
}

export type { CatalogAsset, CatalogAlbum, FolderNode };
