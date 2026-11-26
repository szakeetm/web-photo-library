// Pure layout for the virtualised photo grid: square tiles in rows, optional section headers.

export interface Section {
	key: string;
	label: string | null;
	items: string[]; // asset ids
}

export type Block =
	| { kind: 'header'; key: string; label: string; y: number; h: number }
	| { kind: 'row'; key: string; section: string; items: string[]; y: number; h: number };

export interface GridLayout {
	blocks: Block[];
	height: number;
	tile: number;
	columns: number;
	gap: number;
	/** asset id → its row block index and column */
	indexOf: Map<string, { block: number; col: number }>;
}

export function columnsFor(width: number, target: number): number {
	return Math.max(1, Math.round(width / target));
}

export function layoutGrid(
	sections: Section[],
	opts: { width: number; columns: number; gap: number; headerHeight: number }
): GridLayout {
	const { width, columns, gap, headerHeight } = opts;
	const tile = Math.max(1, (width - gap * (columns - 1)) / columns);
	const blocks: Block[] = [];
	const indexOf = new Map<string, { block: number; col: number }>();
	let y = 0;
	for (const s of sections) {
		if (s.label != null) {
			blocks.push({ kind: 'header', key: `h:${s.key}`, label: s.label, y, h: headerHeight });
			y += headerHeight;
		}
		for (let i = 0; i < s.items.length; i += columns) {
			const items = s.items.slice(i, i + columns);
			items.forEach((id, col) => indexOf.set(id, { block: blocks.length, col }));
			blocks.push({ kind: 'row', key: `r:${s.key}:${i}`, section: s.key, items, y, h: tile });
			y += tile + gap;
		}
		if (s.items.length) y -= gap; // gaps only between rows of a section
	}
	const height = y;
	return { blocks, height, tile, columns, gap, indexOf };
}

/** Inclusive [first, last] block indices intersecting [top, top + viewport] ± overscan. */
export function visibleRange(blocks: Block[], top: number, viewport: number, overscan: number): [number, number] {
	if (!blocks.length) return [0, -1];
	const lo = top - overscan;
	const hi = top + viewport + overscan;
	// first block whose bottom is below lo
	let a = 0,
		b = blocks.length - 1;
	while (a < b) {
		const m = (a + b) >> 1;
		if (blocks[m].y + blocks[m].h <= lo) a = m + 1;
		else b = m;
	}
	const first = a;
	let last = first;
	while (last + 1 < blocks.length && blocks[last + 1].y < hi) last++;
	return [first, last];
}

/** The photo at grid-local (x, y), or null (headers, past the end); a gap counts as the row above it. */
export function idAt(layout: GridLayout, x: number, y: number): string | null {
	const { blocks, tile, gap } = layout;
	// last block starting at or above y
	let lo = 0;
	let hi = blocks.length - 1;
	let found = -1;
	while (lo <= hi) {
		const mid = (lo + hi) >> 1;
		if (blocks[mid].y <= y) {
			found = mid;
			lo = mid + 1;
		} else hi = mid - 1;
	}
	const b = blocks[found];
	if (!b || b.kind !== 'row' || y >= b.y + b.h + gap) return null;
	const col = Math.floor(x / (tile + gap));
	return col >= 0 && col < b.items.length ? b.items[col] : null;
}

export type Direction = 'left' | 'right' | 'up' | 'down';

/**
 * The photo next to `from` in `dir`, as laid out (Photos on the Mac): left/right step through the photos
 * in order (across rows and sections), up/down go to the row above/below at the same column, or that
 * row's last photo when it is shorter. Null at the edges or when `from` isn't laid out.
 */
export function neighbour(blocks: Block[], from: string, dir: Direction): string | null {
	const rows = blocks.filter((b): b is Extract<Block, { kind: 'row' }> => b.kind === 'row');
	let r = -1;
	let c = -1;
	for (let i = 0; i < rows.length && r < 0; i++) {
		const j = rows[i].items.indexOf(from);
		if (j >= 0) [r, c] = [i, j];
	}
	if (r < 0) return null;
	if (dir === 'left') return c > 0 ? rows[r].items[c - 1] : r > 0 ? rows[r - 1].items.at(-1)! : null;
	if (dir === 'right') return c < rows[r].items.length - 1 ? rows[r].items[c + 1] : r < rows.length - 1 ? rows[r + 1].items[0] : null;
	const target = rows[dir === 'up' ? r - 1 : r + 1];
	return target ? target.items[Math.min(c, target.items.length - 1)] : null;
}
