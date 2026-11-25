// Upload queue: one file at a time, duplicate check by content hash, retries for transient
// errors, persisted in IndexedDB so a closed app resumes where it left off.

export type UploadSource = 'phone' | 'desktop';
export type UploadStatus = 'queued' | 'hashing' | 'checking' | 'uploading' | 'duplicate' | 'done' | 'failed';

export interface UploadItem {
	id: string;
	name: string;
	size: number;
	source: UploadSource;
	status: UploadStatus;
	progress: number; // 0..1
	error?: string;
}

export interface StoredUpload {
	id: string;
	name: string;
	source: UploadSource;
	file: Blob;
}

/** Persistence for pending uploads. */
export interface UploadStore {
	put(u: StoredUpload): Promise<void>;
	delete(id: string): Promise<void>;
	all(): Promise<StoredUpload[]>;
}

export class UploadHttpError extends Error {
	constructor(
		public status: number,
		message: string
	) {
		super(message);
	}
}

export interface Transport {
	/** Hex SHA-256 of the file, or null if hashing isn't available (non-secure context). */
	hash(file: File): Promise<string | null>;
	exists(hash: string): Promise<boolean>;
	upload(file: File, source: UploadSource, onProgress: (fraction: number) => void): Promise<{ duplicate: boolean }>;
}

export class MemoryStore implements UploadStore {
	private map = new Map<string, StoredUpload>();
	async put(u: StoredUpload) {
		this.map.set(u.id, u);
	}
	async delete(id: string) {
		this.map.delete(id);
	}
	async all() {
		return [...this.map.values()];
	}
}

export class IndexedDBStore implements UploadStore {
	private db: Promise<IDBDatabase>;
	constructor(name = 'photos-uploads') {
		this.db = new Promise((resolve, reject) => {
			const req = indexedDB.open(name, 1);
			req.onupgradeneeded = () => req.result.createObjectStore('uploads', { keyPath: 'id' });
			req.onsuccess = () => resolve(req.result);
			req.onerror = () => reject(req.error);
		});
	}
	private async tx<T>(mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
		const db = await this.db;
		return new Promise((resolve, reject) => {
			const req = fn(db.transaction('uploads', mode).objectStore('uploads'));
			req.onsuccess = () => resolve(req.result);
			req.onerror = () => reject(req.error);
		});
	}
	async put(u: StoredUpload) {
		await this.tx('readwrite', (s) => s.put(u));
	}
	async delete(id: string) {
		await this.tx('readwrite', (s) => s.delete(id));
	}
	async all() {
		return this.tx<StoredUpload[]>('readonly', (s) => s.getAll());
	}
}

/** Talks to the PhotoServer upload API. */
export const httpTransport: Transport = {
	async hash(file) {
		if (!globalThis.crypto?.subtle) return null;
		const digest = await crypto.subtle.digest('SHA-256', await file.arrayBuffer());
		return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
	},
	async exists(hash) {
		const res = await fetch(`/api/assets/${hash}`, { method: 'HEAD' });
		return res.ok;
	},
	upload(file, source, onProgress) {
		return new Promise((resolve, reject) => {
			const xhr = new XMLHttpRequest();
			const params = new URLSearchParams({ source, name: file.name, mtime: String(file.lastModified) });
			xhr.open('POST', `/api/uploads?${params}`);
			xhr.setRequestHeader('X-Client-API-Version', '2');
			xhr.setRequestHeader('Content-Type', 'application/octet-stream');
			xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total);
			xhr.onload = () => {
				if (xhr.status >= 200 && xhr.status < 300) {
					resolve({ duplicate: !!JSON.parse(xhr.responseText).duplicate });
				} else {
					let msg = xhr.statusText;
					try {
						msg = JSON.parse(xhr.responseText).error ?? msg;
					} catch {
						/* not json */
					}
					reject(new UploadHttpError(xhr.status, msg));
				}
			};
			xhr.onerror = () => reject(new Error('Network error'));
			xhr.send(file);
		});
	}
};

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class UploadQueue {
	items = $state<UploadItem[]>([]);
	running = $state(false);
	private files = new Map<string, File>();
	private draining: Promise<void> | null = null;
	/** Called after a file was stored on the server (to refresh the catalog). */
	onUploaded?: () => void;

	constructor(
		private transport: Transport,
		private store: UploadStore,
		private opts: { retryDelayMs?: number; attempts?: number } = {}
	) {}

	active = $derived(this.items.filter((i) => ['queued', 'hashing', 'checking', 'uploading'].includes(i.status)).length);

	async add(files: File[], source: UploadSource) {
		for (const f of files) {
			const id = crypto.randomUUID();
			this.files.set(id, f);
			this.items.push({ id, name: f.name, size: f.size, source, status: 'queued', progress: 0 });
			await this.store.put({ id, name: f.name, source, file: f }).catch(() => {});
		}
		this.kick();
	}

	/** Re-queue uploads left over from a previous session. */
	async resume() {
		for (const u of await this.store.all()) {
			if (this.items.some((i) => i.id === u.id)) continue;
			const f = u.file instanceof File ? u.file : new File([u.file], u.name);
			this.files.set(u.id, f);
			this.items.push({ id: u.id, name: u.name, size: f.size, source: u.source, status: 'queued', progress: 0 });
		}
		this.kick();
	}

	clearFinished() {
		this.items = this.items.filter((i) => !['done', 'duplicate', 'failed'].includes(i.status));
	}

	retryFailed() {
		for (const i of this.items) if (i.status === 'failed') this.set(i.id, { status: 'queued', error: undefined, progress: 0 });
		this.kick();
	}

	idle(): Promise<void> {
		return this.draining ?? Promise.resolve();
	}

	private kick() {
		this.draining ??= this.drain().finally(() => {
			this.draining = null;
			this.running = false;
		});
	}

	private set(id: string, patch: Partial<UploadItem>) {
		const i = this.items.findIndex((x) => x.id === id);
		if (i >= 0) this.items[i] = { ...this.items[i], ...patch };
	}

	private async drain() {
		this.running = true;
		for (;;) {
			const next = this.items.find((i) => i.status === 'queued');
			if (!next) break;
			await this.process(next);
		}
	}

	private async process(item: UploadItem) {
		const file = this.files.get(item.id);
		if (!file) return this.set(item.id, { status: 'failed', error: 'File no longer available' });
		const attempts = this.opts.attempts ?? 3;
		for (let attempt = 1; ; attempt++) {
			try {
				this.set(item.id, { status: 'hashing' });
				const hash = await this.transport.hash(file);
				if (hash) {
					this.set(item.id, { status: 'checking' });
					if (await this.transport.exists(hash)) {
						this.set(item.id, { status: 'duplicate', progress: 1 });
						break;
					}
				}
				this.set(item.id, { status: 'uploading', progress: 0 });
				const r = await this.transport.upload(file, item.source, (p) => this.set(item.id, { progress: p }));
				this.set(item.id, { status: r.duplicate ? 'duplicate' : 'done', progress: 1 });
				if (!r.duplicate) this.onUploaded?.();
				break;
			} catch (e) {
				const permanent = e instanceof UploadHttpError && e.status >= 400 && e.status < 500;
				if (permanent || attempt >= attempts) {
					this.set(item.id, { status: 'failed', error: (e as Error).message });
					// a rejected file will never succeed; a network failure is kept so it resumes next launch
					if (permanent) await this.store.delete(item.id).catch(() => {});
					return;
				}
				await sleep((this.opts.retryDelayMs ?? 1000) * 2 ** (attempt - 1));
			}
		}
		this.files.delete(item.id);
		await this.store.delete(item.id).catch(() => {});
	}
}
