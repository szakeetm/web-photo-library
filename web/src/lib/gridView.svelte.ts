// Filter and sort for photo grids. One grid is shown at a time: its PhotoBrowser registers here and
// the title bar shows the menu. The filter is kept per page for the browser session; so is the order,
// unless the page has an order of its own (`SortPolicy`).
import type { CatalogAsset } from './api';
import { groupByMonth, localTime, monthLabel } from './dates';
import type { Section } from './gridLayout';

export type ViewFilter = 'all' | 'favorites' | 'photos' | 'videos' | 'live' | 'edited' | 'screenshots' | 'selfies' | 'portraits';
export type ViewSort = 'newest' | 'oldest' | 'added';

export const MF_SCREENSHOT = 1;
export const MF_SELFIE = 2;
export const MF_PORTRAIT = 4;

export const FILTERS: { key: ViewFilter; label: string }[] = [
	{ key: 'all', label: 'All Items' },
	{ key: 'favorites', label: 'Favourites' },
	{ key: 'photos', label: 'Photos' },
	{ key: 'videos', label: 'Videos' },
	{ key: 'live', label: 'Live Photos' },
	{ key: 'edited', label: 'Edited' },
	{ key: 'screenshots', label: 'Screenshots' },
	{ key: 'selfies', label: 'Selfies' },
	{ key: 'portraits', label: 'Portraits' }
];

export const SORTS: { key: ViewSort; label: string }[] = [
	{ key: 'newest', label: 'Newest First' },
	{ key: 'oldest', label: 'Oldest First' },
	{ key: 'added', label: 'Recently Added' }
];

/** Edited in any way: pixels, the date, or a video trim. */
export const isEdited = (a: CatalogAsset) => a.ev > 0 || a.md === true || a.tr != null;

export function matches(a: CatalogAsset, f: ViewFilter): boolean {
	switch (f) {
		case 'all':
			return true;
		case 'favorites':
			return a.fav;
		case 'photos':
			return a.dur == null;
		case 'videos':
			return a.dur != null;
		case 'live':
			return a.live === true;
		case 'edited':
			return isEdited(a);
		case 'screenshots':
			return ((a.mf ?? 0) & MF_SCREENSHOT) !== 0;
		case 'selfies':
			return ((a.mf ?? 0) & MF_SELFIE) !== 0;
		case 'portraits':
			return ((a.mf ?? 0) & MF_PORTRAIT) !== 0;
	}
}

/** The page's own order: newest or oldest first (from its first and last photos). */
export function naturalOrder(sections: Section[], byId: Map<string, CatalogAsset>): 'newest' | 'oldest' {
	const ids = sections.flatMap((s) => s.items);
	const first = byId.get(ids[0]);
	const last = byId.get(ids[ids.length - 1]);
	return first && last && localTime(first) < localTime(last) ? 'oldest' : 'newest';
}

/** Month key of the date added (in this device's time zone). */
function addedKey(a: CatalogAsset): string {
	const d = new Date((a.ad ?? Date.parse(a.t) / 1000) * 1000);
	return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

/** The sections to show: filtered, and regrouped when a sort other than the page's own is chosen. */
export function applyView(
	sections: Section[],
	byId: Map<string, CatalogAsset>,
	filter: ViewFilter,
	sort: ViewSort | null
): Section[] {
	const keep = (id: string) => {
		const a = byId.get(id);
		return a != null && matches(a, filter);
	};
	const natural = naturalOrder(sections, byId);
	if (sort == null || sort === natural) {
		if (filter === 'all') return sections;
		return sections.map((s) => ({ ...s, items: s.items.filter(keep) })).filter((s) => s.items.length > 0);
	}
	const assets = sections
		.flatMap((s) => s.items)
		.filter(keep)
		.map((id) => byId.get(id)!);
	// one grid without headings (an album, a folder) stays one, just turned around
	if (sort !== 'added' && sections.length === 1 && sections[0].label == null) {
		const sorted = assets.slice().sort((x, y) => localTime(x) - localTime(y));
		if (sort === 'newest') sorted.reverse();
		return [{ ...sections[0], items: sorted.map((a) => a.id) }];
	}
	if (sort === 'added') {
		const sorted = assets.slice().sort((x, y) => (y.ad ?? 0) - (x.ad ?? 0) || localTime(y) - localTime(x));
		const groups = new Map<string, string[]>();
		for (const a of sorted) {
			const k = addedKey(a);
			const g = groups.get(k);
			if (g) g.push(a.id);
			else groups.set(k, [a.id]);
		}
		return [...groups].map(([k, items]) => ({ key: `added-${k}`, label: `Added ${monthLabel(k)}`, items }));
	}
	const sorted = assets.slice().sort((x, y) => localTime(x) - localTime(y));
	if (sort === 'newest') sorted.reverse();
	return groupByMonth(sorted).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }));
}

interface Saved {
	filter: ViewFilter;
	sort: ViewSort | null;
}

/** A page's own order: what it opens with, and whether a change is remembered on this device (under
 *  `remember`, shared by every page given the same name) or forgotten when the page is left. */
export interface SortPolicy {
	initial: ViewSort;
	remember?: string;
}

export class GridView {
	/** A grid is on screen that can be filtered. */
	enabled = $state(false);
	/** Its order can be changed (not in albums: always oldest to newest). */
	sortable = $state(true);
	natural = $state<'newest' | 'oldest'>('newest');
	filter = $state<ViewFilter>('all');
	sort = $state<ViewSort | null>(null);
	/** The page's own order, when it has one. */
	policy = $state<SortPolicy | null>(null);
	private key = '';

	/** What the page shows without a choice: its own order, or the order its photos come in. */
	get baseline(): ViewSort {
		return this.policy?.initial ?? this.natural;
	}

	/** Called by the grid's PhotoBrowser; returns the cleanup. */
	attach(key: string, sortable: boolean, policy: SortPolicy | null = null): () => void {
		this.key = key;
		this.sortable = sortable;
		this.policy = sortable ? policy : null;
		let saved: Saved | null = null;
		try {
			saved = JSON.parse(sessionStorage.getItem(`view:${key}`) ?? 'null');
		} catch {
			/* ignore */
		}
		this.filter = saved?.filter ?? 'all';
		if (!sortable) this.sort = null;
		else if (policy?.remember) this.sort = rememberedSort(policy.remember) ?? policy.initial;
		else if (policy) this.sort = policy.initial;
		else this.sort = saved?.sort ?? null;
		this.enabled = true;
		return () => {
			if (this.key === key) this.enabled = false;
		};
	}

	set(filter: ViewFilter, sort: ViewSort | null) {
		this.filter = filter;
		this.sort = sort;
		try {
			// a page with an order of its own doesn't keep a choice for the session
			sessionStorage.setItem(`view:${this.key}`, JSON.stringify({ filter, sort: this.policy ? null : sort } satisfies Saved));
			if (this.policy?.remember) localStorage.setItem(`sort:${this.policy.remember}`, sort ?? this.natural);
		} catch {
			/* private mode */
		}
	}

	get active() {
		return this.filter !== 'all' || (this.sort ?? this.natural) !== this.baseline;
	}
}

function rememberedSort(name: string): ViewSort | null {
	try {
		const v = localStorage.getItem(`sort:${name}`);
		return SORTS.some((s) => s.key === v) ? (v as ViewSort) : null;
	} catch {
		return null;
	}
}

export const gridView = new GridView();

/** Thumbnail size of the grid on screen, for the title bar's zoom control (desktop). 0 = smallest. */
export const gridZoom = $state({
	enabled: false,
	level: 0,
	max: 0,
	set: (_level: number) => {}
});
