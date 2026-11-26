// Months and years of a month-grouped grid, for the jump-to-month panel.
import type { Section } from './gridLayout';

export interface MonthMark {
	key: string;
	year: number;
	month: number; // 1-12
	label: string;
	/** Top of the month's header within the grid (px). */
	y: number;
	count: number;
}

export interface YearGroup {
	year: number;
	count: number;
	months: MonthMark[];
}

const MONTH_KEY = /(\d{4})-(\d{2})$/;

/** One mark per labelled month section, in grid order; empty if the sections aren't months. */
export function monthMarks(sections: Section[], headerY: Map<string, number>): MonthMark[] {
	const marks: MonthMark[] = [];
	for (const s of sections) {
		if (s.label == null) continue;
		const m = MONTH_KEY.exec(s.key);
		const y = headerY.get(s.key);
		if (!m || y == null) return [];
		marks.push({ key: s.key, year: Number(m[1]), month: Number(m[2]), label: s.label, y, count: s.items.length });
	}
	return marks;
}

/** Years newest first; months in calendar order. */
export function yearGroups(marks: MonthMark[]): YearGroup[] {
	const years = new Map<number, YearGroup>();
	for (const m of marks) {
		const g = years.get(m.year) ?? { year: m.year, count: 0, months: [] };
		g.count += m.count;
		g.months.push(m);
		years.set(m.year, g);
	}
	const out = [...years.values()].sort((a, b) => b.year - a.year);
	for (const g of out) g.months.sort((a, b) => a.month - b.month);
	return out;
}

/** The month whose section contains grid position `y` (the last one starting at or above it). */
export function markAt(marks: MonthMark[], y: number): MonthMark | null {
	let lo = 0;
	let hi = marks.length - 1;
	let best: MonthMark | null = marks[0] ?? null;
	while (lo <= hi) {
		const mid = (lo + hi) >> 1;
		if (marks[mid].y <= y) {
			best = marks[mid];
			lo = mid + 1;
		} else hi = mid - 1;
	}
	return best;
}
