import { describe, expect, it } from 'vitest';
import { groupPlaces } from './places.svelte';
import type { CatalogAsset, CatalogPlace } from './api';

const place = (id: number, name: string, cc: string, country: string): CatalogPlace => ({ id, name, cc, country, region: null, lat: 0, lon: 0 });
const asset = (id: string, pl: number | null) => ({ id, pl }) as CatalogAsset;

describe('groupPlaces', () => {
	it('groups by country, biggest first, newest photo as cover', () => {
		const places = [place(1, 'Paris', 'FR', 'France'), place(2, 'Lyon', 'FR', 'France'), place(3, 'Vienna', 'AT', 'Austria'), place(4, 'Nowhere', 'XX', 'X')];
		const g = groupPlaces([asset('a', 1), asset('b', 3), asset('c', 1), asset('d', 2), asset('e', null)], places);
		expect(g.map((c) => [c.cc, c.count])).toEqual([['FR', 3], ['AT', 1]]);
		expect(g[0].cities.map((c) => [c.place.name, c.count, c.cover])).toEqual([['Paris', 2, 'c'], ['Lyon', 1, 'd']]);
		expect(g[0].cover).toBe('c');
	});
});
