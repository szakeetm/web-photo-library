import { describe, expect, it } from 'vitest';
import { localParts, groupByMonth, monthLabel } from './dates';

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
