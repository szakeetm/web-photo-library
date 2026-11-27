import { describe, expect, it, vi, beforeEach } from 'vitest';

vi.mock('./hint.svelte', () => ({ hint: { show: vi.fn() } }));
vi.mock('./net.svelte', () => ({ net: { online: true } }));

import { queued, mayChange, pendingOps, changesSettled, OfflineError } from './changeQueue.svelte';
import { net } from './net.svelte';
import { hint } from './hint.svelte';

/** A promise resolved by hand. */
function gate() {
	let open!: () => void;
	const p = new Promise<void>((r) => (open = r));
	return { p, open };
}

beforeEach(() => {
	net.online = true;
	vi.mocked(hint.show).mockClear();
});

describe('change queue', () => {
	it('runs changes to the same photo one after another, in order', async () => {
		const log: string[] = [];
		const g = gate();
		const a = queued(['p'], async () => {
			log.push('a start');
			await g.p;
			log.push('a end');
		});
		const b = queued(['p'], async () => log.push('b'));
		const other = queued(['q'], async () => log.push('other'));
		await other;
		expect(log).toEqual(['a start', 'other']); // another photo doesn't wait
		g.open();
		await Promise.all([a, b]);
		expect(log).toEqual(['a start', 'other', 'a end', 'b']);
		expect(pendingOps.size).toBe(0);
	});

	it('a failed change does not stop the next one', async () => {
		const first = queued(['p'], async () => {
			throw new Error('nope');
		});
		const second = queued(['p'], async () => 'ok');
		await expect(first).rejects.toThrow('nope');
		await expect(second).resolves.toBe('ok');
	});

	it('a change to several photos waits for each of them', async () => {
		const log: string[] = [];
		const g = gate();
		const a = queued(['p'], async () => {
			await g.p;
			log.push('p');
		});
		const both = queued(['p', 'q'], async () => log.push('both'));
		await Promise.resolve();
		expect(log).toEqual([]);
		g.open();
		await Promise.all([a, both]);
		expect(log).toEqual(['p', 'both']);
	});

	it('is not sent when the server went away while it waited', async () => {
		const g = gate();
		const started = gate();
		const a = queued(['p'], () => (started.open(), g.p));
		const work = vi.fn(async () => {});
		const b = queued(['p'], work);
		await started.p; // the first one was sent while online
		net.online = false;
		g.open();
		await a;
		await expect(b).rejects.toBeInstanceOf(OfflineError);
		expect(work).not.toHaveBeenCalled();
	});

	it('refuses more waiting changes than a photo takes, and offline, with a bubble', async () => {
		const g = gate();
		const runs = Array.from({ length: 4 }, () => queued(['p'], () => g.p));
		expect(mayChange(['p'])).toBe(false);
		expect(mayChange(['q'])).toBe(true);
		expect(hint.show).toHaveBeenCalledTimes(1);
		g.open();
		await Promise.all(runs);
		await changesSettled(['p']);
		await Promise.resolve();
		expect(mayChange(['p'])).toBe(true);
		net.online = false;
		expect(mayChange(['p'])).toBe(false);
		expect(hint.show).toHaveBeenCalledTimes(2);
	});
});
