// Offline copy of the catalog: a full snapshot once, then small deltas.
import type { CatalogAsset, CatalogAlbum, CatalogDelta, CatalogPerson, CatalogPlace, CatalogSnapshot, FolderNode } from './api';
import { db, type CatalogMeta } from './db';

export interface Replica {
	meta: CatalogMeta;
	assets: CatalogAsset[];
	folders: FolderNode[];
	albums: CatalogAlbum[];
	people: CatalogPerson[];
	places: CatalogPlace[];
}

/** The stored replica, or null when there is none (or it was made by another app format). */
export async function loadReplica(format: number): Promise<Replica | null> {
	const d = await db();
	const meta = (await d.get('meta', 'catalog')) as CatalogMeta | undefined;
	if (!meta || meta.format !== format) return null;
	const [assets, folders, albums, people, places] = await Promise.all([
		d.getAll('assets'),
		d.get('meta', 'folders') as Promise<FolderNode[] | undefined>,
		d.get('meta', 'albums') as Promise<CatalogAlbum[] | undefined>,
		d.get('meta', 'people') as Promise<CatalogPerson[] | undefined>,
		d.get('meta', 'places') as Promise<CatalogPlace[] | undefined>
	]);
	return { meta, assets, folders: folders ?? [], albums: albums ?? [], people: people ?? [], places: places ?? [] };
}

export async function saveSnapshot(snap: CatalogSnapshot) {
	const d = await db();
	const tx = d.transaction(['meta', 'assets'], 'readwrite');
	const assets = tx.objectStore('assets');
	await assets.clear();
	for (const a of snap.assets) assets.put(a);
	const meta = tx.objectStore('meta');
	meta.put(snap.folders, 'folders');
	meta.put(snap.albums, 'albums');
	meta.put(snap.people, 'people');
	meta.put(snap.places, 'places');
	meta.put({ format: snap.format, catalogId: snap.catalogId, seq: snap.seq, hashes: snap.hashes } satisfies CatalogMeta, 'catalog');
	await tx.done;
}

/** Stores a delta; `albums` is the merged album list (deltas only carry the changed albums). */
export async function saveDelta(delta: CatalogDelta, albums: CatalogAlbum[]) {
	const d = await db();
	const tx = d.transaction(['meta', 'assets'], 'readwrite');
	const assets = tx.objectStore('assets');
	for (const a of delta.assets) assets.put(a);
	for (const id of delta.deleted) assets.delete(id);
	const meta = tx.objectStore('meta');
	if (delta.folders) meta.put(delta.folders, 'folders');
	if (delta.albums?.length || delta.deletedAlbums?.length) meta.put(albums, 'albums');
	if (delta.people) meta.put(delta.people, 'people');
	if (delta.places) meta.put(delta.places, 'places');
	meta.put({ format: delta.format, catalogId: delta.catalogId, seq: delta.seq, hashes: delta.hashes } satisfies CatalogMeta, 'catalog');
	await tx.done;
}

/** Applies a delta to an in-memory asset list (order is restored by the caller). */
export function mergeAssets(current: CatalogAsset[], delta: Pick<CatalogDelta, 'assets' | 'deleted'>): CatalogAsset[] {
	if (!delta.assets.length && !delta.deleted.length) return current;
	const gone = new Set(delta.deleted);
	const byId = new Map(current.map((a) => [a.id, a]));
	for (const id of gone) byId.delete(id);
	for (const a of delta.assets) byId.set(a.id, a);
	return [...byId.values()];
}

/** Applies a delta's changed and deleted albums to the album list (order: as listed by the server). */
export function mergeAlbums(current: CatalogAlbum[], delta: Pick<CatalogDelta, 'albums' | 'deletedAlbums'>): CatalogAlbum[] {
	if (!delta.albums?.length && !delta.deletedAlbums?.length) return current;
	const gone = new Set(delta.deletedAlbums ?? []);
	const changed = new Map((delta.albums ?? []).map((a) => [a.id, a]));
	const out = current.filter((a) => !gone.has(a.id)).map((a) => changed.get(a.id) ?? a);
	const known = new Set(current.map((a) => a.id));
	for (const a of delta.albums ?? []) if (!known.has(a.id)) out.push(a);
	return out;
}

export async function clearReplica() {
	const d = await db();
	const tx = d.transaction(['meta', 'assets'], 'readwrite');
	await tx.objectStore('assets').clear();
	await tx.objectStore('meta').delete('catalog');
	await tx.done;
}
