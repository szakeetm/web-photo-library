// Changes to photos, one after another.
import { SvelteMap } from 'svelte/reactivity';
import { net } from './net.svelte';
import { hint } from './hint.svelte';

// Every change to a photo (favourite, rotate, edit, trim, dates, delete, restore, album) goes through
// `queued`: changes to the same photo reach the server one at a time, in the order they were given,
// so a quick rotate-rotate-delete-undo can't overtake itself. A change whose turn comes while the
// server can't be reached is not sent. A photo takes at most MAX_QUEUED waiting changes; `mayChange`
// refuses more (with a bubble saying why) before anything is done on screen.

/** The last queued change of each photo (it resolves after all earlier ones). */
const photoOps = new Map<string, Promise<unknown>>();
/** Changes of each photo not yet done (sent or waiting), for busy states. */
export const pendingOps = new SvelteMap<string, number>();
const MAX_QUEUED = 4;

export class OfflineError extends Error {
	constructor() {
		super("The server can't be reached: the change wasn't made.");
	}
}

/** Called whenever a change is given (e.g. the last deletion's Undo goes away then). */
const givenListeners = new Set<() => void>();
export function onChangeGiven(fn: () => void) {
	givenListeners.add(fn);
}

/** True when these photos take another change now; else says why in a bubble (offline, or too many
 *  changes still being saved) and returns false. */
export function mayChange(ids: string[]): boolean {
	if (!net.online) {
		hint.show("Offline: changes can't be made until the server is back.");
		return false;
	}
	if (ids.some((i) => (pendingOps.get(i) ?? 0) >= MAX_QUEUED)) {
		hint.show('Still saving the previous changes… try again in a moment.');
		return false;
	}
	for (const fn of givenListeners) fn();
	return true;
}

/** Whether any of these photos has a change still being saved. */
export const isChanging = (ids: string[]) => ids.some((i) => pendingOps.has(i));

/** Runs `work` once every earlier change to these photos is done (failed ones too). */
export function queued<T>(ids: string[], work: () => Promise<T>): Promise<T> {
	const ids2 = [...new Set(ids)];
	const before = ids2.map((i) => photoOps.get(i)).filter((p): p is Promise<unknown> => !!p);
	for (const i of ids2) pendingOps.set(i, (pendingOps.get(i) ?? 0) + 1);
	const run = Promise.allSettled(before).then(() => {
		if (!net.online) throw new OfflineError();
		return work();
	});
	const done = run.catch(() => {});
	for (const i of ids2) photoOps.set(i, done);
	done.then(() => {
		for (const i of ids2) {
			if (photoOps.get(i) === done) photoOps.delete(i);
			const n = (pendingOps.get(i) ?? 1) - 1;
			if (n > 0) pendingOps.set(i, n);
			else pendingOps.delete(i);
		}
	});
	return run;
}

/** Waits until every change to these photos given so far is done (failed ones too). */
export async function changesSettled(ids: string[]) {
	await Promise.allSettled(ids.map((i) => photoOps.get(i)).filter(Boolean));
}

/** Shows why a change failed: a lost connection as a bubble (once, however many changes it hit),
 *  anything else in an alert, the same message not twice in a row within a few seconds. */
let lastError = { text: '', at: 0 };
export function reportError(e: unknown, prefix = '') {
	const lost = e instanceof OfflineError || (e instanceof DOMException && e.name === 'TimeoutError') || e instanceof TypeError;
	const text = lost ? "The connection was lost: the change wasn't saved." : `${prefix}${(e as Error)?.message ?? e}`;
	const now = Date.now();
	if (text === lastError.text && now - lastError.at < 5000) return;
	lastError = { text, at: now };
	if (lost) hint.show(text, 5000);
	else {
		alert(text);
		lastError.at = Date.now(); // counted from when the alert was closed
	}
}

