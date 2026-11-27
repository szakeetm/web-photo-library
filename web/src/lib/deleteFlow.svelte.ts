// Deleting photos (to the Trash): a confirmation with "Don't ask again" (remembered on this device),
// and, once it isn't asked any more, an Undo overlay after each deletion. Deleting for good (uploads,
// from the Trash) always asks: it can't be undone.
import { deletePhotos, restoreFromTrash, reportError } from './state.svelte.ts';
import { onChangeGiven } from './changeQueue.svelte.ts';
import { hint } from './hint.svelte.ts';

const SKIP_KEY = 'skipDeleteConfirm';

class DeleteFlow {
	/** Don't ask before deleting (show Undo instead). */
	skip = $state(typeof localStorage !== 'undefined' && localStorage.getItem(SKIP_KEY) === '1');
	/** The open confirmation. */
	pending = $state<{ title: string; message: string; resolve: (ok: boolean) => void } | null>(null);
	dontAsk = $state(false);
	/** The Undo overlay after a deletion. */
	undo = $state<{ text: string; ids: string[] } | null>(null);
	undoing = $state(false);

	constructor() {
		// Undo stays until something else is done (another change, another photo, closing the viewer…)
		onChangeGiven(() => this.dismissUndo());
	}

	setSkip(v: boolean) {
		this.skip = v;
		if (v) localStorage.setItem(SKIP_KEY, '1');
		else localStorage.removeItem(SKIP_KEY);
	}

	/** Asks (unless asked not to); true to go ahead. */
	ask(title: string, message: string): Promise<boolean> {
		if (this.skip) return Promise.resolve(true);
		this.dontAsk = false;
		return new Promise((resolve) => (this.pending = { title, message, resolve }));
	}

	answer(ok: boolean) {
		const p = this.pending;
		if (!p) return;
		if (ok && this.dontAsk) this.setSkip(true);
		this.pending = null;
		p.resolve(ok);
	}

	/**
	 * Puts photos in the Trash after asking; `run` does the deleting (defaults to deletePhotos), e.g. one
	 * that also leaves the viewer (it may return false when it failed and said so itself). `immediate`
	 * (⌘⌫ / Ctrl+Delete): no question, Undo instead. Undo shows at once, while the deleting may still
	 * wait for earlier changes to these photos (an Undo then waits for the deleting). Returns whether
	 * they were deleted.
	 */
	async remove(
		ids: string[],
		title: string,
		message: string,
		run: () => Promise<unknown> = () => deletePhotos(ids),
		immediate = false
	) {
		if (!ids.length || (!immediate && !(await this.ask(title, message)))) return false;
		const undo = this.skip || immediate ? this.offerUndo(ids) : null;
		// a failed delete takes its Undo away (unless another delete's is shown by now)
		const withdraw = () => undo && this.undo === undo && this.dismissUndo();
		try {
			if ((await run()) === false) {
				withdraw();
				return false;
			}
		} catch (e) {
			withdraw();
			throw e;
		}
		return true;
	}

	offerUndo(ids: string[]) {
		const undo = { text: `Deleted ${ids.length === 1 ? 'the photo' : `${ids.length} photos`}`, ids };
		this.undo = undo;
		return this.undo;
	}

	async undoLast() {
		const u = this.undo;
		if (!u) return;
		if (this.undoing) return hint.show('Still undoing…');
		this.undoing = true;
		try {
			await restoreFromTrash(u.ids);
			this.undo = null;
		} catch (e) {
			reportError(e, "Couldn't undo: ");
		} finally {
			this.undoing = false;
		}
	}

	dismissUndo() {
		this.undo = null;
	}
}

export const deleteFlow = new DeleteFlow();

/**
 * The delete key of a keyboard event, the same on a Mac and on Windows/Linux: Backspace or Delete
 * asks first ('ask'); with ⌘ (Mac) or Ctrl (Windows/Linux) it deletes at once with Undo ('now').
 * Not while typing in a field.
 */
export function deleteKey(e: KeyboardEvent): 'ask' | 'now' | null {
	if (e.key !== 'Backspace' && e.key !== 'Delete') return null;
	if (e.altKey || e.shiftKey) return null;
	if ((e.target as HTMLElement | null)?.closest?.('input, select, textarea, [contenteditable]')) return null;
	return e.metaKey || e.ctrlKey ? 'now' : 'ask';
}

/** The question for deleting photos: uploads go to the Trash, other photos are only hidden. */
export function deleteQuestion(ids: string[], isUpload: (id: string) => boolean) {
	const n = ids.length;
	const uploads = ids.filter(isUpload).length;
	const others = n - uploads;
	const parts = [
		uploads &&
			`${uploads === 1 ? 'The upload stays' : `${uploads} uploads stay`} in the Trash until you delete ${uploads === 1 ? 'it' : 'them'} there (then ${uploads === 1 ? "it's" : "they're"} deleted from disk).`,
		others &&
			`${others === 1 ? (n === 1 ? 'The photo is' : 'The other photo is') : `${others} photos are`} only hidden: ${others === 1 ? 'its file stays' : 'their files stay'} where they are (local folders, Photos libraries, pCloud…) and can be restored from the Trash any time.`
	].filter(Boolean);
	return { title: `Delete ${n === 1 ? 'this photo' : `${n} photos`}?`, message: parts.join('\n\n') };
}
