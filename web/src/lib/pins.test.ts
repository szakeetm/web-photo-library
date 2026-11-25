import { describe, expect, it, vi } from 'vitest';
vi.mock('$app/env', () => ({ version: 'test' }));
import { albumImageUrls } from './pins.svelte';
import type { CatalogAsset } from './api';

describe('albumImageUrls', () => {
	it('lists thumb + preview at the current edit version, skipping missing photos', () => {
		const a = { id: 'a', ev: 2 } as CatalogAsset;
		const byId = new Map([['a', a]]);
		const urls = albumImageUrls({ id: 1, title: 'T', coverId: null, source: 'user', assetIds: ['a', 'gone'] }, byId, 'heic');
		expect(urls).toEqual(['/api/thumb/a?e=2&fmt=heic', '/api/preview/a?e=2&fmt=heic']);
	});
});
