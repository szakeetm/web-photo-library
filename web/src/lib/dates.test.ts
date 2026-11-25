import { describe, expect, it } from 'vitest';
import { localParts, groupByMonth, monthLabel, sortByLocalTime } from './dates';

const a = (id: string, t: string, tz: number | null) => ({ id, w: 1, h: 1, t, tz, fav: false, bh: null, ev: 0, folders: [], name: id });

describe('local capture time', () => {
	it('applies the capture offset', () => {
		expect(localParts('2021-07-31T23:30:00Z', 7200)).toMatchObject({ year: 2021, month: 8, day: 1, hour: 1 });
	});
	it('null offset means UTC fields', () => {
		expect(localParts('2021-07-31T23:30:00Z', null)).toMatchObject({ year: 2021, month: 7, day: 31 });
	});
});

describe('groupByMonth', () => {
	it('groups by local month in the given order', () => {
		const groups = groupByMonth([
			a('1', '2021-07-01T10:00:00Z', 0),
			a('2', '2021-07-31T23:30:00Z', 7200),
			a('3', '2021-08-02T10:00:00Z', 0)
		]);
		expect(groups.map((g) => [g.key, g.items.map((i) => i.id)])).toEqual([
			['2021-07', ['1']],
			['2021-08', ['2', '3']]
		]);
	});
	it('labels months', () => {
		expect(monthLabel('2021-08', 'en-US')).toBe('August 2021');
	});
});

describe('travellers across month boundaries', () => {
	// Tokyo photo: Aug 1 01:00 local = Jul 31 16:00 UTC; home photo: Jul 31 23:00 local (+2) = 21:00 UTC
	const tokyo = a('tokyo', '2021-07-31T16:00:00Z', 9 * 3600);
	const home = a('home', '2021-07-31T21:00:00Z', 2 * 3600);
	const july = a('july', '2021-07-30T10:00:00Z', 0);

	it('sorts by local wall-clock time', () => {
		expect(sortByLocalTime([tokyo, home, july]).map((x) => x.id)).toEqual(['july', 'home', 'tokyo']);
	});

	it('never produces duplicate month keys, even for unsorted input', () => {
		const keys = groupByMonth([july, tokyo, home]).map((g) => g.key);
		expect(new Set(keys).size).toBe(keys.length);
	});
});
