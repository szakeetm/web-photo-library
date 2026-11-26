// Exports written by the browser itself into a folder on its own computer (File System Access:
// Chrome and Edge). For exports too big to download as one ZIP from another device: each file is
// fetched from the Mac on its own and streamed to disk, a few at a time, retried when the network
// drops. A file is only there once it's complete (createWritable writes to a swap file and commits on
// close), so running the same export into the same folder again picks up where it stopped.
import { api, exportEntryUrl, type ExportEntryInfo } from './api.ts';

export const canWriteFolders = typeof window !== 'undefined' && 'showDirectoryPicker' in window;

type Picker = (o: { id?: string; mode?: 'read' | 'readwrite'; startIn?: string }) => Promise<FileSystemDirectoryHandle>;

/** Asks for a folder (call it straight from a click). Null when the person cancels. */
export async function pickFolder(): Promise<FileSystemDirectoryHandle | null> {
	try {
		return await (window as unknown as { showDirectoryPicker: Picker }).showDirectoryPicker({
			id: 'photo-export',
			mode: 'readwrite',
			startIn: 'downloads'
		});
	} catch (e) {
		if ((e as Error).name === 'AbortError') return null;
		throw e;
	}
}

export interface FolderProgress {
	done: number;
	total: number;
	bytes: number;
	/** files that weren't available on the Mac */
	skipped: string[];
}

const WORKERS = 3;
const PROBLEMS = 'Export problems.txt';

/** Writes export `id` into `root`/`name`; resolves when every file is there. */
export async function writeExport(
	id: string,
	root: FileSystemDirectoryHandle,
	name: string,
	signal: AbortSignal,
	onProgress: (p: FolderProgress) => void
): Promise<FolderProgress> {
	const top = await root.getDirectoryHandle(name, { create: true });
	const entries = await api.exportEntries(id);
	const p: FolderProgress = { done: 0, total: entries.length, bytes: 0, skipped: [] };
	onProgress(p);

	const dirs = new Map<string, Promise<FileSystemDirectoryHandle>>([['', Promise.resolve(top)]]);
	function dirFor(path: string) {
		let key = '';
		for (const part of path.split('/').slice(0, -1)) {
			const k = key ? `${key}/${part}` : part;
			if (!dirs.has(k)) {
				const parent = dirs.get(key)!;
				dirs.set(k, parent.then((d) => d.getDirectoryHandle(part, { create: true })));
			}
			key = k;
		}
		return dirs.get(key)!;
	}

	async function one(n: number, e: ExportEntryInfo) {
		const dir = await dirFor(e.path);
		const file = e.path.split('/').pop()!;
		// already there from an earlier run
		try {
			const f = await (await dir.getFileHandle(file)).getFile();
			if (e.exact ? f.size === e.bytes : f.size > 0) {
				p.bytes += f.size;
				return;
			}
		} catch {
			/* not there yet */
		}
		for (let attempt = 0; ; attempt++) {
			let got = 0;
			try {
				const res = await fetch(exportEntryUrl(id, n), { signal });
				if (res.status === 410) {
					p.skipped.push(e.path);
					return;
				}
				if (!res.ok || !res.body) throw new Error((await res.json().catch(() => null))?.error ?? `HTTP ${res.status}`);
				const w = await (await dir.getFileHandle(file, { create: true })).createWritable();
				const count = new TransformStream<Uint8Array, Uint8Array>({
					transform(chunk, c) {
						got += chunk.byteLength;
						p.bytes += chunk.byteLength;
						onProgress(p);
						c.enqueue(chunk);
					}
				});
				await res.body.pipeThrough(count).pipeTo(w, { signal });
				return;
			} catch (err) {
				p.bytes -= got;
				if (signal.aborted || attempt >= 3) throw err;
				await new Promise((r) => setTimeout(r, 1000 * 2 ** attempt));
			}
		}
	}

	let next = 0;
	async function worker() {
		while (next < entries.length) {
			const n = next++;
			await one(n, entries[n]);
			p.done++;
			onProgress(p);
		}
	}
	await Promise.all(Array.from({ length: Math.min(WORKERS, entries.length) }, worker));

	if (p.skipped.length) {
		const text =
			"These files weren't available (moved or deleted since the last scan) and aren't in this export:\n\n" +
			p.skipped.join('\n') +
			'\n';
		const w = await (await top.getFileHandle(PROBLEMS, { create: true })).createWritable();
		await w.write(text);
		await w.close();
	}
	return p;
}
