import { describe, expect, it } from 'vitest';
import { selectRange, nextFavoriteValue, dragSelect } from './selection.svelte.ts';

describe('selectRange', () => {
	const ids = ['a', 'b', 'c', 'd', 'e'];
	it('selects inclusive range forwards and backwards', () => {
		expect(selectRange(ids, 'b', 'd')).toEqual(['b', 'c', 'd']);
		expect(selectRange(ids, 'd', 'b')).toEqual(['b', 'c', 'd']);
	});
	it('falls back to the target when the anchor is unknown', () => {
		expect(selectRange(ids, 'zzz', 'c')).toEqual(['c']);
	});
});

describe('nextFavoriteValue', () => {
	it('favourites unless every selected photo already is one', () => {
		expect(nextFavoriteValue([true, false])).toBe(true);
		expect(nextFavoriteValue([true, true])).toBe(false);
		expect(nextFavoriteValue([])).toBe(true);
	});
});

describe('dragSelect', () => {
	const order = ['a', 'b', 'c', 'd', 'e'];
	it('adds the range from an unselected start', () => {
		expect([...dragSelect(new Set(['e']), order, 'b', 'd')].sort()).toEqual(['b', 'c', 'd', 'e']);
	});
	it('works backwards', () => {
		expect([...dragSelect(new Set(), order, 'd', 'b')].sort()).toEqual(['b', 'c', 'd']);
	});
	it('removes the range from a selected start', () => {
		expect([...dragSelect(new Set(order), order, 'b', 'c')].sort()).toEqual(['a', 'd', 'e']);
	});
	it('shrinking the drag restores the base', () => {
		const base = new Set(['a']);
		dragSelect(base, order, 'b', 'e');
		expect([...dragSelect(base, order, 'b', 'b')].sort()).toEqual(['a', 'b']);
	});
});
