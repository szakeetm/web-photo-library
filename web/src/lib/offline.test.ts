import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import type { CatalogAsset, CatalogSnapshot } from './api';
import { db, resetDbForTests } from './db';
import { cacheTotals, chooseEvictions, imageKey, isCacheableImage, recordImage, releasePins, summarize } from './imageCache';
import { loadReplica, mergeAlbums, mergeAssets, saveDelta, saveSnapshot } from './replica';

const asset = (id: string, ev = 0, fav = false): CatalogAsset => ({
	id,
	w: 4,
	h: 3,
	t: '2024-01-01T00:00:00Z',
	tz: 0,
	fav,
	bh: null,
	ev,
	folders: [1],
	name: `${id}.jpg`
});

beforeEach(async () => {
	await resetDbForTests();
	await new Promise((r) => {
		const req = indexedDB.deleteDatabase('photos');
		req.onsuccess = req.onerror = r;
	});
});

describe('replica', () => {
	const snap: CatalogSnapshot = {
		format: 3,
		catalogId: 'c1',
		seq: 10,
		assets: [asset('a'), asset('b')],
		folders: [],
		albums: [{ id: 1, title: 'Trip', coverId: null, source: 'user', assetIds: ['a'] }],
		people: [{ id: 5, name: 'Anna', coverFaceId: 9, count: 1, hidden: false }],
		places: [],
		hashes: { folders: 'f', people: 'p', places: 'pl' }
	};

	it('round-trips a snapshot and ignores other formats', async () => {
		await saveSnapshot(snap);
		const r = await loadReplica(3);
		expect(r?.meta).toEqual({ format: 3, catalogId: 'c1', seq: 10, hashes: { folders: 'f', people: 'p', places: 'pl' } });
		expect(r?.assets.map((a) => a.id).sort()).toEqual(['a', 'b']);
		expect(r?.albums[0].title).toBe('Trip');
		expect(r?.people[0].name).toBe('Anna');
		expect(await loadReplica(4)).toBeNull();
	});

	it('applies deltas: upserts, deletes, lists, seq', async () => {
		await saveSnapshot(snap);
		const delta = { format: 3, catalogId: 'c1', seq: 12, reset: false, assets: [asset('a', 1), asset('c')], deleted: ['b'], albums: [], deletedAlbums: [1] };
		await saveDelta(delta, mergeAlbums(snap.albums, delta));
		const r = await loadReplica(3);
		expect(r?.meta.seq).toBe(12);
		expect(r?.assets.map((a) => [a.id, a.ev]).sort()).toEqual([['a', 1], ['c', 0]]);
		expect(r?.albums).toEqual([]);
		expect(r?.people[0].name).toBe('Anna'); // lists left out of a delta are kept
	});

	it('merges changed and deleted albums', () => {
		const al = (id: number, title: string) => ({ id, title, coverId: null, source: 'user' as const, assetIds: [] });
		const cur = [al(1, 'A'), al(2, 'B'), al(3, 'C')];
		const out = mergeAlbums(cur, { albums: [al(2, 'B2'), al(4, 'D')], deletedAlbums: [1] });
		expect(out.map((a) => a.title)).toEqual(['B2', 'C', 'D']);
		expect(mergeAlbums(cur, { albums: [], deletedAlbums: [] })).toBe(cur);
	});

	it('merges deltas in memory', () => {
		const out = mergeAssets([asset('a'), asset('b')], { assets: [asset('b', 2)], deleted: ['a'] });
		expect(out.map((a) => [a.id, a.ev])).toEqual([['b', 2]]);
		const same = [asset('a')];
		expect(mergeAssets(same, { assets: [], deleted: [] })).toBe(same);
	});
});

describe('image cache bookkeeping', () => {
	it('evicts least recently used unpinned images until under the limit', () => {
		const e = (url: string, bytes: number, lastAccess: number, pins: number[] = []) => ({ url, bytes, lastAccess, pins });
		const entries = [e('old', 40, 1), e('pinned', 50, 0, [7]), e('mid', 30, 2), e('new', 20, 3)];
		expect(chooseEvictions(entries, 200)).toEqual([]);
		expect(chooseEvictions(entries, 90)).toEqual(['old', 'mid']);
		// pinned images are never chosen, even if the limit can't be met
		expect(chooseEvictions(entries, 10)).toEqual(['old', 'mid', 'new']);
	});

	it('summarizes by kind and album', () => {
		const u = summarize([
			{ url: '/api/thumb/a?e=0&fmt=heic', bytes: 10, lastAccess: 0, pins: [1] },
			{ url: '/api/preview/a?e=0&fmt=heic', bytes: 100, lastAccess: 0, pins: [1, 2] },
			{ url: '/api/preview/b?e=0&fmt=heic', bytes: 50, lastAccess: 0, pins: [] }
		]);
		expect(u).toMatchObject({ total: 160, thumbs: 10, previews: 150, clips: 0, pinned: 110, count: 3 });
		expect([...u.byAlbum]).toEqual([[1, 110], [2, 100]]);
	});

	it('keys and cacheability', () => {
		expect(imageKey('https://mac.ts.net/api/thumb/x?e=1&fmt=jpeg')).toBe('/api/thumb/x?e=1&fmt=jpeg');
		expect(isCacheableImage('/api/preview/x')).toBe(true);
		expect(isCacheableImage('/api/assets/x/original')).toBe(false);
	});

	it('records images and releases pins except the ones still wanted', async () => {
		await recordImage('/api/thumb/a?e=0', 5, 1);
		await recordImage('/api/thumb/a?e=0', 5, 2);
		await recordImage('/api/thumb/b?e=0', 7, 1);
		await recordImage('/api/thumb/c?e=0', 9);
		await releasePins(1, new Set(['/api/thumb/b?e=0']));
		const all = await (await db()).getAll('images');
		const pinsOf = Object.fromEntries(all.map((e) => [e.url, e.pins]));
		expect(pinsOf).toEqual({ '/api/thumb/a?e=0': [2], '/api/thumb/b?e=0': [1], '/api/thumb/c?e=0': [] });
	});
});

describe('cache budgets', () => {
	const e = (url: string, bytes: number, lastAccess: number) => ({ url, bytes, lastAccess, pins: [] as number[] });
	it('caps Live Photo clips and protects thumbnails', () => {
		const entries = [
			e('/api/assets/a/motion', 30, 1),
			e('/api/thumb/t1', 40, 0),
			e('/api/preview/p1', 20, 2),
			e('/api/assets/b/motion', 10, 3)
		];
		// limit 100: total 100 fits, but clips (40) exceed 15 → oldest clips go first
		expect(chooseEvictions(entries, 100)).toEqual(['/api/assets/a/motion']);
		// the oldest entry is a thumbnail, but within half the limit it is kept: a newer preview goes
		const mixed = [e('/api/thumb/t', 30, 0), e('/api/preview/p', 30, 1), e('/api/preview/q', 30, 2)];
		expect(chooseEvictions(mixed, 80)).toEqual(['/api/preview/p']);
		// limit 20: nothing else left, so thumbnails go too
		expect(chooseEvictions(entries, 20)).toContain('/api/thumb/t1');
	});

	it('keeps running totals in step with records and deletions', async () => {
		await recordImage('/api/thumb/a', 5);
		await recordImage('/api/preview/a', 50);
		await recordImage('/api/preview/a', 40); // re-recorded smaller
		await recordImage('/api/assets/x/motion', 30);
		expect(await cacheTotals()).toEqual({ thumb: 5, preview: 40, clip: 30 });
	});
});
