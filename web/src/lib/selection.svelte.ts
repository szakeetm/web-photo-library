// Multi-select state shared by grids and the action bar.

/** Inclusive range between anchor and target in display order. */
export function selectRange(ids: string[], anchor: string, target: string): string[] {
	const a = ids.indexOf(anchor);
	const b = ids.indexOf(target);
	if (a < 0 || b < 0) return [target];
	const [lo, hi] = a < b ? [a, b] : [b, a];
	return ids.slice(lo, hi + 1);
}

/** Drag-select (Photos on iPhone): everything between the first photo and the one under the
 * finger is selected — or unselected, when the first photo was already selected. */
export function dragSelect(base: Set<string>, order: string[], from: string, to: string): Set<string> {
	const range = selectRange(order, from, to);
	const next = new Set(base);
	const adding = !base.has(from);
	for (const id of range) {
		if (adding) next.add(id);
		else next.delete(id);
	}
	return next;
}

/** Favourite the selection unless all of it already is (then unfavourite). */
export function nextFavoriteValue(current: boolean[]): boolean {
	return current.length === 0 || !current.every(Boolean);
}

/** Archive the selection unless all of it already is (then unarchive). */
export const nextArchiveValue = nextFavoriteValue;

/**
 * The selected photos. Selecting is "active" (the action bar shows, clicks and taps add and remove)
 * when the user asked for it (Select, a long press, select all, a drag) or when two or more photos are
 * selected. On a desktop a click selects just that photo (the blue frame, Photos on the Mac): one
 * selected photo is not selecting yet (a click also opens it; Space opens it again).
 */
/** Views with more photos than this can't be selected all at once (⌘A, the All button). */
export const SELECT_ALL_MAX = 500;

/** Why select all did nothing in a view of `n` photos. */
export const selectAllRefused = (n: number) =>
	`Select all works in views of up to ${SELECT_ALL_MAX} photos (this one has ${n.toLocaleString()}). Select them by hand, or narrow the view down.`;

export class Selection {
	/** Select was pressed (or a long press, select all, a drag) */
	explicit = $state(false);
	ids = $state(new Set<string>());
	/** the photo clicked last: ranges start here */
	anchor = $state<string | null>(null);
	/** the moving end of a shift+arrow range (the arrow keys move from here) */
	lead = $state<string | null>(null);
	/** what was selected when the current shift+arrow range started: kept while the range changes */
	private rangeBase: Set<string> | null = null;
	count = $derived(this.ids.size);
	active = $derived(this.explicit || this.ids.size >= 2);

	start(id?: string) {
		this.explicit = true;
		if (id) this.toggle(id);
	}

	/** Just this photo (a desktop click, the arrow keys, the photo last open). */
	only(id: string) {
		this.rangeBase = null;
		this.ids = new Set([id]);
		this.anchor = id;
		this.lead = id;
	}

	/** Shift+arrows: the photos from the anchor to `to` (in `order`) become the range, `to` its moving
	 *  end; photos selected apart from it (⌘-click) stay selected. */
	rangeTo(order: string[], to: string) {
		this.rangeBase ??= new Set(this.ids);
		this.ids = new Set([...this.rangeBase, ...selectRange(order, this.anchor ?? to, to)]);
		this.anchor ??= to;
		this.lead = to;
	}

	/** Where the arrow keys move from: the moving end of a range, else the last clicked photo still selected. */
	get cursor(): string | null {
		if (this.lead && this.ids.has(this.lead)) return this.lead;
		if (this.anchor && this.ids.has(this.anchor)) return this.anchor;
		return this.ids.size ? this.ids.values().next().value! : null;
	}

	toggle(id: string) {
		this.rangeBase = null;
		const next = new Set(this.ids);
		if (next.has(id)) next.delete(id);
		else next.add(id);
		this.ids = next;
		this.anchor = id;
		this.lead = id;
	}

	extendTo(order: string[], id: string) {
		this.rangeBase = null;
		const range = selectRange(order, this.anchor ?? id, id);
		this.ids = new Set([...this.ids, ...range]);
		this.anchor = id;
		this.lead = id;
	}

	/** Replaces the selection (drag-select). */
	set(ids: Set<string>, anchor?: string) {
		this.rangeBase = null;
		this.explicit = true;
		this.ids = ids;
		if (anchor) this.anchor = anchor;
	}

	selectAll(order: string[]) {
		this.rangeBase = null;
		this.explicit = true;
		this.ids = new Set(order);
	}

	clear() {
		this.rangeBase = null;
		this.explicit = false;
		this.ids = new Set();
		this.anchor = null;
		this.lead = null;
	}
}
