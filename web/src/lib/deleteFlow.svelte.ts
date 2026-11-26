// Deleting photos (to the Trash): a confirmation with "Don't ask again" (remembered on this device),
// and, once it isn't asked any more, an Undo overlay after each deletion. Deleting for good (uploads,
// from the Trash) always asks: it can't be undone.
import { deletePhotos, restoreFromTrash } from './state.svelte.ts';

const SKIP_KEY = 'skipDeleteConfirm';
const UNDO_MS = 8000;

class DeleteFlow {
	/** Don't ask before deleting (show Undo instead). */
	skip = $state(typeof localStorage !== 'undefined' && localStorage.getItem(SKIP_KEY) === '1');
	/** The open confirmation. */
	pending = $state<{ title: string; message: string; resolve: (ok: boolean) => void } | null>(null);
	dontAsk = $state(false);
	/** The Undo overlay after a deletion. */
	undo = $state<{ text: string; ids: string[] } | null>(null);
	undoing = $state(false);
	private timer: ReturnType<typeof setTimeout> | undefined;

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
	 * that also leaves the viewer. `immediate` (⌘⌫ / Ctrl+Delete): no question, Undo instead. Returns
	 * whether they were deleted.
	 */
	async remove(
		ids: string[],
		title: string,
		message: string,
		run: () => Promise<unknown> = () => deletePhotos(ids),
		immediate = false
	) {
		if (!ids.length || (!immediate && !(await this.ask(title, message)))) return false;
		await run();
		if (this.skip || immediate) this.offerUndo(ids);
		return true;
	}

	offerUndo(ids: string[]) {
		clearTimeout(this.timer);
		this.undo = { text: `Deleted ${ids.length === 1 ? 'the photo' : `${ids.length} photos`}`, ids };
		this.timer = setTimeout(() => (this.undo = null), UNDO_MS);
	}

	async undoLast() {
		const u = this.undo;
		if (!u || this.undoing) return;
		clearTimeout(this.timer);
		this.undoing = true;
		try {
			await restoreFromTrash(u.ids);
			this.undo = null;
		} catch (e) {
			alert((e as Error).message);
		} finally {
			this.undoing = false;
		}
	}

	dismissUndo() {
		clearTimeout(this.timer);
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
