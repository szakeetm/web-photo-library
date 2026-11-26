import { describe, expect, it } from 'vitest';
import { layoutGrid, visibleRange, columnsFor, idAt, neighbour } from './gridLayout.ts';

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

describe('idAt', () => {
	const layout = layoutGrid(
		[
			{ key: 's1', label: 'One', items: ['a', 'b', 'c', 'd', 'e'] },
			{ key: 's2', label: 'Two', items: ['f'] }
		],
		{ width: 300, columns: 3, gap: 2, headerHeight: 40 }
	);
	it('finds tiles by position', () => {
		const t = layout.tile;
		expect(idAt(layout, 1, 41)).toBe('a');
		expect(idAt(layout, t + 3, 41)).toBe('b');
		expect(idAt(layout, 1, 40 + t + 3)).toBe('d');
		expect(idAt(layout, 2 * (t + 2) + 1, 40 + t + 3)).toBeNull(); // past the last tile of the row
		expect(idAt(layout, 1, 5)).toBeNull(); // header
		expect(idAt(layout, 1, layout.height + 50)).toBeNull();
	});
});

describe('neighbour', () => {
	// two sections, 3 columns: [a b c] [d] | [e f g] [h i]
	const layout = layoutGrid(
		[
			{ key: 's1', label: 'One', items: ['a', 'b', 'c', 'd'] },
			{ key: 's2', label: 'Two', items: ['e', 'f', 'g', 'h', 'i'] }
		],
		{ width: 300, columns: 3, gap: 0, headerHeight: 40 }
	);
	const n = (from: string, dir: 'left' | 'right' | 'up' | 'down') => neighbour(layout.blocks, from, dir);

	it('steps left and right through the photos in order, across rows and sections', () => {
		expect(n('a', 'right')).toBe('b');
		expect(n('c', 'right')).toBe('d');
		expect(n('d', 'right')).toBe('e');
		expect(n('e', 'left')).toBe('d');
		expect(n('a', 'left')).toBeNull();
		expect(n('i', 'right')).toBeNull();
	});

	it('goes up and down a row at the same column, or the shorter row’s last photo', () => {
		expect(n('b', 'down')).toBe('d');
		expect(n('d', 'down')).toBe('e');
		expect(n('f', 'up')).toBe('d');
		expect(n('g', 'down')).toBe('i');
		expect(n('a', 'up')).toBeNull();
		expect(n('h', 'down')).toBeNull();
		expect(n('zz', 'down')).toBeNull();
	});
});
