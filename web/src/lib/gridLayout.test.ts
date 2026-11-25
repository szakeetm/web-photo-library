import { describe, expect, it } from 'vitest';
import { layoutGrid, visibleRange, columnsFor } from './gridLayout.ts';

const sections = [
	{ key: 'a', label: 'A', items: ['1', '2', '3', '4', '5'] },
	{ key: 'b', label: 'B', items: ['6'] }
];

describe('layoutGrid', () => {
	it('places headers and square rows', () => {
		const l = layoutGrid(sections, { width: 302, columns: 3, gap: 1, headerHeight: 40 });
		// tile = (302 - 2*1) / 3 = 100
		expect(l.tile).toBe(100);
		expect(l.blocks.map((b) => [b.kind, b.y, b.kind === 'row' ? b.items : b.label])).toEqual([
			['header', 0, 'A'],
			['row', 40, ['1', '2', '3']],
			['row', 141, ['4', '5']],
			['header', 241, 'B'],
			['row', 281, ['6']]
		]);
		expect(l.height).toBe(381);
	});

	it('omits headers when sections have no label', () => {
		const l = layoutGrid([{ key: 'x', label: null, items: ['1', '2'] }], { width: 200, columns: 2, gap: 0, headerHeight: 40 });
		expect(l.blocks.map((b) => b.kind)).toEqual(['row']);
		expect(l.indexOf.get('2')).toEqual({ block: 0, col: 1 });
	});
});

describe('visibleRange', () => {
	it('finds blocks intersecting the viewport with overscan', () => {
		const l = layoutGrid(sections, { width: 302, columns: 3, gap: 1, headerHeight: 40 });
		expect(visibleRange(l.blocks, 150, 100, 0)).toEqual([2, 3]);
		expect(visibleRange(l.blocks, 0, 10, 0)).toEqual([0, 0]);
		expect(visibleRange(l.blocks, 1000, 100, 0)).toEqual([4, 4]);
	});
});

describe('columnsFor', () => {
	it('derives columns from a target tile size', () => {
		expect(columnsFor(390, 120)).toBe(3);
		expect(columnsFor(1200, 160)).toBe(8);
		expect(columnsFor(100, 300)).toBe(1);
	});
});
