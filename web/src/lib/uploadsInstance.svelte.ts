import { app } from './state.svelte.ts';
import { IndexedDBStore, MemoryStore, UploadQueue, httpTransport, type UploadSource } from './uploads.svelte.ts';

/** The app-wide upload queue (browser only). */
export const uploads = new UploadQueue(
	httpTransport,
	typeof indexedDB === 'undefined' ? new MemoryStore() : new IndexedDBStore()
);

let reloadTimer: ReturnType<typeof setTimeout> | undefined;
uploads.onUploaded = () => {
	clearTimeout(reloadTimer);
	reloadTimer = setTimeout(() => app.reload(), 800);
};

export const uploadUI = $state({ open: false });

/** Phone uploads when on a small touch screen, desktop otherwise. */
export function currentSource(): UploadSource {
	return navigator.maxTouchPoints > 0 && Math.min(screen.width, screen.height) < 768 ? 'phone' : 'desktop';
}

export const imageAccept =
	'image/*,.heic,.heif,.dng,.cr2,.cr3,.nef,.arw,.raf,.orf,.rw2,.avif,.webp,.tif,.tiff';

export function isImageName(name: string): boolean {
	return /\.(jpe?g|heic|heif|hif|png|gif|webp|avif|tiff?|bmp|dng|cr2|cr3|nef|nrw|arw|raf|orf|rw2|pef|srw)$/i.test(name);
}
