import { describe, expect, it } from 'vitest';
import { markAt, monthMarks, yearGroups, yearTicks } from './timeline';

const sections = [
	{ key: '2023-11', label: 'November 2023', items: ['a', 'b'] },
	{ key: '2024-01', label: 'January 2024', items: ['c'] },
	{ key: '2024-03', label: 'March 2024', items: ['d', 'e', 'f'] },
	{ key: '2025-02', label: 'February 2025', items: ['g'] }
];
const ys = new Map([['2023-11', 0], ['2024-01', 300], ['2024-03', 500], ['2025-02', 1200]]);

describe('timeline', () => {
	it('builds month marks, or none when sections are not months', () => {
		const m = monthMarks(sections, ys);
		expect(m.map((x) => [x.year, x.month, x.count, x.y])).toEqual([[2023, 11, 2, 0], [2024, 1, 1, 300], [2024, 3, 3, 500], [2025, 2, 1, 1200]]);
		expect(monthMarks([{ key: 'album-3', label: null, items: ['a'] }], new Map())).toEqual([]);
		expect(monthMarks([{ key: 'x', label: 'Something', items: ['a'] }], new Map([['x', 0]]))).toEqual([]);
		// prefixed keys (person/place pages) still work
		expect(monthMarks([{ key: '12-2024-05', label: 'May 2024', items: ['a'] }], new Map([['12-2024-05', 0]]))[0].month).toBe(5);
	});

	it('groups years newest first with totals', () => {
		const g = yearGroups(monthMarks(sections, ys));
		expect(g.map((y) => [y.year, y.count, y.months.map((m) => m.month)])).toEqual([[2025, 1, [2]], [2024, 4, [1, 3]], [2023, 2, [11]]]);
	});

	it('finds the month at a scroll position', () => {
		const m = monthMarks(sections, ys);
		expect(markAt(m, -10)?.key).toBe('2023-11');
		expect(markAt(m, 299)?.key).toBe('2023-11');
		expect(markAt(m, 300)?.key).toBe('2024-01');
		expect(markAt(m, 5000)?.key).toBe('2025-02');
		expect(markAt([], 0)).toBeNull();
	});

	it('places year ticks and thins crowded ones', () => {
		const m = monthMarks(sections, ys);
		expect(yearTicks(m, 1200, 600)).toEqual([{ year: 2023, px: 0 }, { year: 2024, px: 150 }, { year: 2025, px: 600 }]);
		expect(yearTicks(m, 1200, 60).map((t) => t.year)).toEqual([2023, 2025]);
	});
});
