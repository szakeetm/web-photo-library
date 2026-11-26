// Lookups over the whole library, built in one pass whenever the catalog changes (once per sync),
// so views don't each filter 100k photos again.
import type { CatalogAsset } from './api';

export interface AssetIndex {
	favorites: CatalogAsset[];
	edited: CatalogAsset[];
	videos: CatalogAsset[];
	live: CatalogAsset[];
	located: CatalogAsset[];
	/** Photos of each place, folder and person (in library order). */
	byPlace: Map<number, CatalogAsset[]>;
	byFolder: Map<number, CatalogAsset[]>;
	byPerson: Map<number, CatalogAsset[]>;
	/** Position of each photo in the library order. */
	pos: Map<string, number>;
}

function push<K>(map: Map<K, CatalogAsset[]>, key: K, a: CatalogAsset) {
	const list = map.get(key);
	if (list) list.push(a);
	else map.set(key, [a]);
}

export function buildIndex(assets: CatalogAsset[]): AssetIndex {
	const ix: AssetIndex = {
		favorites: [],
		edited: [],
		videos: [],
		live: [],
		located: [],
		byPlace: new Map(),
		byFolder: new Map(),
		byPerson: new Map(),
		pos: new Map()
	};
	for (const a of assets) {
		ix.pos.set(a.id, ix.pos.size);
		if (a.fav) ix.favorites.push(a);
		if (a.ev > 0) ix.edited.push(a);
		if (a.dur != null) ix.videos.push(a);
		if (a.live === true) ix.live.push(a);
		if (a.loc) ix.located.push(a);
		if (a.pl != null) push(ix.byPlace, a.pl, a);
		for (const f of a.folders) push(ix.byFolder, f, a);
		for (const p of a.pp ?? []) push(ix.byPerson, p, a);
	}
	return ix;
}

/** Photos in any of these folders, each once, in library order. */
export function inFolders(ix: AssetIndex, folderIds: Iterable<number>): CatalogAsset[] {
	const lists = [...folderIds].map((f) => ix.byFolder.get(f) ?? []).filter((l) => l.length);
	if (lists.length <= 1) return lists[0] ?? [];
	const seen = new Set<string>();
	const out: CatalogAsset[] = [];
	for (const l of lists) for (const a of l) if (!seen.has(a.id)) (seen.add(a.id), out.push(a));
	return out.sort((x, y) => ix.pos.get(x.id)! - ix.pos.get(y.id)!);
}
