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

/**
 * The selected photos. Selecting is "active" (the action bar shows, clicks and taps add and remove)
 * when the user asked for it (Select, a long press, select all, a drag) or when two or more photos are
 * selected. On a desktop a click selects just that photo (the blue frame, Photos on the Mac): one
 * selected photo is not selecting yet; it is opened (Space, double-click) to do something with it.
 */
export class Selection {
	/** Select was pressed (or a long press, select all, a drag) */
	explicit = $state(false);
	ids = $state(new Set<string>());
	/** the photo clicked last: ranges start here, arrow keys move from here */
	anchor = $state<string | null>(null);
	count = $derived(this.ids.size);
	active = $derived(this.explicit || this.ids.size >= 2);

	start(id?: string) {
		this.explicit = true;
		if (id) this.toggle(id);
	}

	/** Just this photo (a desktop click, the arrow keys, the photo last open). */
	only(id: string) {
		this.ids = new Set([id]);
		this.anchor = id;
	}

	/** The single selected photo, else the last clicked one still selected (where the arrow keys start). */
	get cursor(): string | null {
		if (this.anchor && this.ids.has(this.anchor)) return this.anchor;
		return this.ids.size ? this.ids.values().next().value! : null;
	}

	toggle(id: string) {
		const next = new Set(this.ids);
		if (next.has(id)) next.delete(id);
		else next.add(id);
		this.ids = next;
		this.anchor = id;
	}

	extendTo(order: string[], id: string) {
		const range = selectRange(order, this.anchor ?? id, id);
		this.ids = new Set([...this.ids, ...range]);
		this.anchor = id;
	}

	/** Replaces the selection (drag-select). */
	set(ids: Set<string>, anchor?: string) {
		this.explicit = true;
		this.ids = ids;
		if (anchor) this.anchor = anchor;
	}

	selectAll(order: string[]) {
		this.explicit = true;
		this.ids = new Set(order);
	}

	clear() {
		this.explicit = false;
		this.ids = new Set();
		this.anchor = null;
	}
}
