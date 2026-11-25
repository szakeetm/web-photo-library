import { describe, expect, it } from 'vitest';
import { selectRange, nextFavoriteValue } from './selection.svelte.ts';

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
