// Multi-select state shared by grids and the action bar.

/** Inclusive range between anchor and target in display order. */
export function selectRange(ids: string[], anchor: string, target: string): string[] {
	const a = ids.indexOf(anchor);
	const b = ids.indexOf(target);
	if (a < 0 || b < 0) return [target];
	const [lo, hi] = a < b ? [a, b] : [b, a];
	return ids.slice(lo, hi + 1);
}

/** Favourite the selection unless all of it already is (then unfavourite). */
export function nextFavoriteValue(current: boolean[]): boolean {
	return current.length === 0 || !current.every(Boolean);
}

export class Selection {
	active = $state(false);
	ids = $state(new Set<string>());
	anchor: string | null = null;
	count = $derived(this.ids.size);

	start(id?: string) {
		this.active = true;
		if (id) this.toggle(id);
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

	selectAll(order: string[]) {
		this.active = true;
		this.ids = new Set(order);
	}

	clear() {
		this.active = false;
		this.ids = new Set();
		this.anchor = null;
	}
}
