import { describe, expect, it, vi } from 'vitest';
vi.mock('$app/env', () => ({ version: 'test' }));
import { albumImageUrls, confirmDownload, folderAssetIds, folderSubtree, LARGE_DOWNLOAD, pinStatus } from './pins.svelte';
import type { CatalogAsset, FolderNode } from './api';
import type { PinRecord } from './db';

describe('albumImageUrls', () => {
	it('lists thumb + preview at the current edit version, skipping missing photos', () => {
		const a = { id: 'a', ev: 2 } as CatalogAsset;
		const byId = new Map([['a', a]]);
		const urls = albumImageUrls({ id: 1, title: 'T', coverId: null, source: 'user', assetIds: ['a', 'gone'] }, byId, 'heic');
		expect(urls).toEqual(['/api/thumb/a?e=2&fmt=heic&r=2', '/api/preview/a?e=2&fmt=heic&r=2']);
	});
});

describe('video assets', () => {
	it('pin only the thumb and preview images, never the video', () => {
		const v = { id: 'v', ev: 0, dur: 12.3 } as CatalogAsset;
		const urls = albumImageUrls({ id: 1, title: 'T', coverId: null, source: 'user', assetIds: ['v'] }, new Map([['v', v]]), 'jpeg');
		expect(urls).toEqual(['/api/thumb/v?e=0&fmt=jpeg&r=2', '/api/preview/v?e=0&fmt=jpeg&r=2']);
	});
});

describe('folder downloads', () => {
	const f = (id: number, parentId: number | null, relPath: string) =>
		({ id, parentId, relPath, root: 'library', name: relPath.split('/').pop(), count: 0, coverId: null }) as unknown as FolderNode;
	const folders = [f(1, null, ''), f(2, 1, 'Trips'), f(3, 2, 'Trips/Paris'), f(4, 3, 'Trips/Paris/Day 1'), f(5, 1, 'Food')];
	const asset = (id: string, ...fs: number[]) => ({ id, ev: 0, folders: fs }) as unknown as CatalogAsset;
	const assets = [asset('a', 2), asset('b', 3), asset('c', 4), asset('d', 5), asset('e', 4, 5)];

	it('covers the folder and every folder below it', () => {
		expect([...folderSubtree(folders[1], folders)].sort()).toEqual([2, 3, 4]);
		expect([...folderSubtree(folders[3], folders)]).toEqual([4]);
		expect(folderAssetIds(folders[1], folders, assets)).toEqual(['a', 'b', 'c', 'e']);
		expect(folderAssetIds(folders[0], folders, assets)).toHaveLength(5);
	});

	it(`asks before downloading more than ${LARGE_DOWNLOAD} photos`, () => {
		const ask = vi.fn(() => false);
		vi.stubGlobal('confirm', ask);
		expect(confirmDownload('Small', LARGE_DOWNLOAD)).toBe(true);
		expect(ask).not.toHaveBeenCalled();
		expect(confirmDownload('Trips', 1234, true)).toBe(false);
		expect(ask).toHaveBeenCalledOnce();
		expect(ask.mock.calls[0]).toEqual([expect.stringContaining('1,234 photos (including subfolders)')]);
		vi.unstubAllGlobals();
	});

	it('reports progress as a percentage', () => {
		const p = { albumId: -2, title: 'Trips', state: 'downloading', total: 400, done: 100, bytes: 0, updatedAt: 0 } as PinRecord;
		expect(pinStatus(p, true)).toBe('Downloading 25%');
		expect(pinStatus(p, false)).toBe('Download paused 25%');
		expect(pinStatus({ ...p, state: 'done', bytes: 120e6 }, true)).toBe('Downloaded (120 MB)');
	});
});
