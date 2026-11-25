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
