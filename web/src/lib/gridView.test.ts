import { describe, expect, it } from 'vitest';
import type { CatalogAsset } from './api';
import { applyView, matches, naturalOrder } from './gridView.svelte';

const mk = (id: string, t: string, extra: Partial<CatalogAsset> = {}): CatalogAsset => ({
	id,
	w: 1,
	h: 1,
	t,
	tz: 0,
	fav: false,
	bh: null,
	ev: 0,
	folders: [],
	name: id,
	...extra
});

const a = mk('a', '2024-01-05T10:00:00Z', { fav: true, ad: Date.parse('2024-06-01T00:00:00Z') / 1000 });
const b = mk('b', '2024-02-05T10:00:00Z', { dur: 3, ad: Date.parse('2024-03-01T00:00:00Z') / 1000 });
const c = mk('c', '2024-02-07T10:00:00Z', { mf: 1, md: true, ad: Date.parse('2024-06-02T00:00:00Z') / 1000 });
const byId = new Map([a, b, c].map((x) => [x.id, x]));
// newest first, like the Library
const sections = [
	{ key: '2024-02', label: 'February 2024', items: ['c', 'b'] },
	{ key: '2024-01', label: 'January 2024', items: ['a'] }
];

describe('grid view', () => {
	it('matches filters', () => {
		expect(matches(a, 'favorites')).toBe(true);
		expect(matches(b, 'photos')).toBe(false);
		expect(matches(b, 'videos')).toBe(true);
		expect(matches(c, 'screenshots')).toBe(true);
		expect(matches(c, 'selfies')).toBe(false);
		expect(matches(c, 'edited')).toBe(true); // date adjusted counts as edited
	});
	it('detects the page order', () => {
		expect(naturalOrder(sections, byId)).toBe('newest');
		expect(naturalOrder([{ key: 'x', label: null, items: ['a', 'c'] }], byId)).toBe('oldest');
	});
	it('filters within sections and drops empty ones', () => {
		expect(applyView(sections, byId, 'videos', null)).toEqual([{ key: '2024-02', label: 'February 2024', items: ['b'] }]);
		expect(applyView(sections, byId, 'all', 'newest')).toBe(sections);
	});
	it('re-sorts oldest first by month', () => {
		const v = applyView(sections, byId, 'all', 'oldest');
		expect(v.map((s) => s.items)).toEqual([['a'], ['b', 'c']]);
	});
	it('groups by date added, most recent first', () => {
		const v = applyView(sections, byId, 'photos', 'added');
		expect(v.map((s) => s.items)).toEqual([['c', 'a']]);
		expect(v[0].label).toMatch(/^Added /);
	});
});
