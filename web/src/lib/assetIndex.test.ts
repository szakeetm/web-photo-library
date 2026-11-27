import { describe, expect, it } from 'vitest';
import type { CatalogAsset } from './api';
import { buildIndex, inFolders } from './assetIndex';

const a = (id: string, extra: Partial<CatalogAsset> = {}): CatalogAsset => ({
	id, w: 1, h: 1, t: '2020-01-01T00:00:00Z', tz: null, fav: false, bh: null, ev: 0, folders: [], name: id, ...(extra as object)
});

describe('asset index', () => {
	it('groups the library in one pass', () => {
		const ix = buildIndex([
			a('1', { fav: true, folders: [10], pl: 5, pp: [7] }),
			a('2', { dur: 3, folders: [11], pl: 5 }),
			a('3', { live: true, ev: 1, folders: [10, 11], loc: [1, 2], pp: [7, 8] })
		]);
		expect(ix.favorites.map((x) => x.id)).toEqual(['1']);
		expect(ix.edited.map((x) => x.id)).toEqual(['3']);
		expect(ix.videos.map((x) => x.id)).toEqual(['2']);
		expect(ix.live.map((x) => x.id)).toEqual(['3']);
		expect(ix.located.map((x) => x.id)).toEqual(['3']);
		expect(ix.byPlace.get(5)!.map((x) => x.id)).toEqual(['1', '2']);
		expect(ix.byPerson.get(7)!.map((x) => x.id)).toEqual(['1', '3']);
		expect(inFolders(ix, [11, 10]).map((x) => x.id)).toEqual(['1', '2', '3']);
		expect(inFolders(ix, [10]).map((x) => x.id)).toEqual(['1', '3']);
		expect(inFolders(ix, [99])).toEqual([]);
	});

	it('keeps archived photos out of the Library, not out of the other lists', () => {
		const ix = buildIndex([a('1'), a('2', { arc: true, fav: true, folders: [10] }), a('3')]);
		expect(ix.library.map((x) => x.id)).toEqual(['1', '3']);
		expect(ix.archived.map((x) => x.id)).toEqual(['2']);
		expect(ix.favorites.map((x) => x.id)).toEqual(['2']);
		expect(inFolders(ix, [10]).map((x) => x.id)).toEqual(['2']);
	});
});
