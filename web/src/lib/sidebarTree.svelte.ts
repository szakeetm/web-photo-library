// What's open in the desktop sidebar: the Filters, Albums and Folders groups, and the folders expanded in the
// Folders tree. Remembered on this device.
const KEY = 'sidebarTree';

interface Saved {
	filters: boolean;
	albums: boolean;
	folders: boolean;
	open: number[];
}

class SidebarTree {
	filters = $state(true);
	albums = $state(true);
	folders = $state(true);
	private open = $state(new Set<number>());

	constructor() {
		if (typeof localStorage === 'undefined') return;
		try {
			const s = JSON.parse(localStorage.getItem(KEY) ?? 'null') as Saved | null;
			if (s) {
				this.filters = s.filters ?? true;
				this.albums = s.albums ?? true;
				this.folders = s.folders ?? true;
				this.open = new Set(s.open ?? []);
			}
		} catch {
			/* start fresh */
		}
	}

	private save() {
		const s: Saved = { filters: this.filters, albums: this.albums, folders: this.folders, open: [...this.open] };
		localStorage.setItem(KEY, JSON.stringify(s));
	}

	isOpen(folderId: number) {
		return this.open.has(folderId);
	}

	toggle(folderId: number) {
		const next = new Set(this.open);
		if (next.has(folderId)) next.delete(folderId);
		else next.add(folderId);
		this.open = next;
		this.save();
	}

	toggleGroup(group: 'filters' | 'albums' | 'folders') {
		this[group] = !this[group];
		this.save();
	}
}

export const sidebarTree = new SidebarTree();
