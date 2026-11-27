import { beforeEach, describe, expect, it } from 'vitest';
import type { CatalogAsset } from './api';
import { applyView, GridView, matches, naturalOrder } from './gridView.svelte';

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

describe('page orders', () => {
	const storage = () => {
		const m = new Map<string, string>();
		return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) };
	};
	beforeEach(() => {
		Object.assign(globalThis, { localStorage: storage(), sessionStorage: storage() });
	});

	it('turns a grid without headings around as one grid', () => {
		const album = [{ key: 'album-1', label: null, items: ['a', 'b', 'c'] }];
		expect(applyView(album, byId, 'all', 'newest')).toEqual([{ key: 'album-1', label: null, items: ['c', 'b', 'a'] }]);
	});

	it('albums open oldest first and remember a change on this device', () => {
		const v = new GridView();
		v.natural = 'oldest';
		v.attach('/albums/1', true, { initial: 'oldest', remember: 'albums' })();
		expect(v.sort).toBe('oldest');
		expect(v.active).toBe(false);
		v.set('all', 'newest');
		// another album, later
		const w = new GridView();
		w.natural = 'oldest';
		w.attach('/albums/2', true, { initial: 'oldest', remember: 'albums' });
		expect(w.sort).toBe('newest');
		expect(w.active).toBe(true);
	});

	it('folders, people and places open in their own order every time', () => {
		const v = new GridView();
		v.natural = 'oldest';
		v.attach('/people/1', true, { initial: 'newest' })();
		expect(v.sort).toBe('newest');
		expect(v.active).toBe(false); // newest first is this page's normal order
		v.set('all', null); // oldest first (the photos' own order)
		const again = new GridView();
		again.natural = 'oldest';
		again.attach('/people/1', true, { initial: 'newest' });
		expect(again.sort).toBe('newest');

		const f = new GridView();
		f.natural = 'oldest';
		f.attach('/folders/x', true, { initial: 'oldest' })();
		f.set('all', 'newest');
		const f2 = new GridView();
		f2.attach('/folders/x', true, { initial: 'oldest' });
		expect(f2.sort).toBe('oldest');
	});

	it('other pages keep the choice for the session', () => {
		const v = new GridView();
		v.attach('/favorites', true)();
		v.set('all', 'oldest');
		const w = new GridView();
		w.attach('/favorites', true);
		expect(w.sort).toBe('oldest');
	});
});
