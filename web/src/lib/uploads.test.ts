import { describe, expect, it } from 'vitest';
import { UploadQueue, type Transport, MemoryStore, UploadHttpError } from './uploads.svelte.ts';

function file(name: string, body = name) {
	return new File([body], name, { type: 'image/jpeg', lastModified: 1_700_000_000_000 });
}

function fakeTransport(opts: { existing?: string[]; flaky?: Record<string, number>; reject?: Record<string, number> }) {
	const calls: string[] = [];
	const failures = { ...(opts.flaky ?? {}) };
	const t: Transport = {
		hash: async (f) => `h-${f.name}`,
		exists: async (h) => (opts.existing ?? []).includes(h),
		upload: async (f, _source, onProgress) => {
			calls.push(f.name);
			if (opts.reject?.[f.name]) throw new UploadHttpError(opts.reject[f.name], 'nope');
			if ((failures[f.name] ?? 0) > 0) {
				failures[f.name]--;
				throw new Error('network');
			}
			onProgress(1);
			return { duplicate: false };
		}
	};
	return { t, calls };
}

describe('UploadQueue', () => {
	it('skips duplicates, retries transient errors, fails fast on client errors', async () => {
		const { t, calls } = fakeTransport({ existing: ['h-dup.jpg'], flaky: { 'flaky.jpg': 2 }, reject: { 'bad.jpg': 415 } });
		const q = new UploadQueue(t, new MemoryStore(), { retryDelayMs: 1 });
		await q.add([file('dup.jpg'), file('flaky.jpg'), file('bad.jpg'), file('ok.jpg')], 'phone');
		await q.idle();
		const status = Object.fromEntries(q.items.map((i) => [i.name, i.status]));
		expect(status).toEqual({ 'dup.jpg': 'duplicate', 'flaky.jpg': 'done', 'bad.jpg': 'failed', 'ok.jpg': 'done' });
		expect(calls.filter((c) => c === 'flaky.jpg').length).toBe(3);
		expect(calls).not.toContain('dup.jpg');
		expect(calls.filter((c) => c === 'bad.jpg').length).toBe(1);
	});

	it('gives up after three attempts', async () => {
		const { t } = fakeTransport({ flaky: { 'x.jpg': 9 } });
		const q = new UploadQueue(t, new MemoryStore(), { retryDelayMs: 1 });
		await q.add([file('x.jpg')], 'desktop');
		await q.idle();
		expect(q.items[0].status).toBe('failed');
	});

	it('resumes unfinished uploads from the store', async () => {
		const store = new MemoryStore();
		await store.put({ id: 'a', name: 'left.jpg', source: 'phone', file: file('left.jpg') });
		const { t, calls } = fakeTransport({});
		const q = new UploadQueue(t, store, { retryDelayMs: 1 });
		await q.resume();
		await q.idle();
		expect(calls).toEqual(['left.jpg']);
		expect(await store.all()).toEqual([]);
	});
});

describe('server updates during uploads', () => {
	it('stops on 426 without losing queued files', async () => {
		const store = new MemoryStore();
		const { t } = fakeTransport({ reject: { 'a.jpg': 426 } });
		const q = new UploadQueue(t, store, { retryDelayMs: 1 });
		let updateNeeded = false;
		q.onUpdateRequired = () => (updateNeeded = true);
		await q.add([file('a.jpg'), file('b.jpg')], 'phone');
		await q.idle();
		expect(updateNeeded).toBe(true);
		expect(q.items.map((i) => i.status)).toEqual(['queued', 'queued']);
		expect((await store.all()).length).toBe(2);
	});

	it('does not start while blocked', async () => {
		const { t, calls } = fakeTransport({});
		const q = new UploadQueue(t, new MemoryStore(), { retryDelayMs: 1 });
		q.blocked = () => true;
		await q.add([file('a.jpg')], 'phone');
		await q.idle();
		expect(calls).toEqual([]);
		expect(q.items[0].status).toBe('queued');
	});

	it('retries 429 but not 415', async () => {
		const { t, calls } = fakeTransport({ reject: { 'busy.jpg': 429, 'bad.jpg': 415 } });
		const q = new UploadQueue(t, new MemoryStore(), { retryDelayMs: 1 });
		await q.add([file('busy.jpg'), file('bad.jpg')], 'phone');
		await q.idle();
		expect(calls.filter((c) => c === 'busy.jpg').length).toBe(3);
		expect(calls.filter((c) => c === 'bad.jpg').length).toBe(1);
	});
});
