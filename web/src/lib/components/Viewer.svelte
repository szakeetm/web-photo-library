<script lang="ts">
	import { reveal } from '#lib/reveal.ts';
	// Full-screen photo viewer: swipe/arrow navigation, swipe-down/Esc to close,
	// pinch / double-tap / ctrl+wheel zoom, info panel, download original. Videos play over their
	// poster (VideoPlayer) and are never zoomed or edited. Live Photos play their motion while the photo
	// is pressed and held (LiveOverlay).
	import { onMount } from 'svelte';
	import { gestureDebug } from '#lib/gestureDebug.svelte.ts';
	import GestureDebug from './GestureDebug.svelte';
	import { folderHref, LOCAL_FOLDERS } from '#lib/sources.ts';
	import { api, isPhotosRoot, originalUrl, previewUrl, thumbUrl, type AssetDetail, type CatalogAsset } from '#lib/api.ts';
	import { captureLabel, isoLabel, offsetLabel, isoDateTime } from '#lib/dates.ts';
	import { app, setFavorite, rotatePhotos, pendingTurns, deletePhotos, restoreFromTrash, deleteForever } from '#lib/state.svelte.ts';
	import { deleteFlow, deleteKey } from '#lib/deleteFlow.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import Icon from './Icon.svelte';
	import FaceAvatar from './FaceAvatar.svelte';
	import ExportSheet from './ExportSheet.svelte';
	import AdjustDateSheet from './AdjustDateSheet.svelte';
	import TrimBar from './TrimBar.svelte';
	import Editor from '#lib/editor/Editor.svelte';
	import VideoPlayer from './VideoPlayer.svelte';
	import LiveOverlay from './LiveOverlay.svelte';
	import { codecLabel, contentRangeTotal, formatBytes, formatDuration } from '#lib/video.ts';

	let {
		ids,
		id,
		onChange,
		onClose,
		trash = false
	}: { ids: string[]; id: string; onChange: (id: string) => void; onClose: () => void; trash?: boolean } = $props();

	const index = $derived(Math.max(0, ids.indexOf(id)));
	const asset = $derived(app.lookup(id));
	const isVideo = $derived(asset?.dur != null);
	let player = $state<ReturnType<typeof VideoPlayer>>();

	let vw = $state(window.innerWidth);
	let vh = $state(window.innerHeight);
	let chrome = $state(true);
	let infoOpen = $state(false);
	// Phone layout: the info pane is a bottom sheet. Swipe up on the photo opens it, swipe down
	// (on the photo, or on the sheet when it is scrolled to the top) puts it away.
	/** How far the sheet is dragged down (px); 0 when resting. */
	let sheetY = $state(0);
	let sheetDragging = $state(false);
	let sheetEl = $state<HTMLElement>();
	const narrow = () => window.innerWidth < 768;

	function closeSheet() {
		if (!narrow() || !sheetEl) {
			infoOpen = false;
			return;
		}
		sheetDragging = false;
		sheetY = sheetEl.offsetHeight;
		setTimeout(() => {
			infoOpen = false;
			sheetY = 0;
		}, 220);
	}

	$effect(() => {
		const el = sheetEl;
		if (!el) return;
		let startY = 0;
		let startT = 0;
		let pulling = false;
		const onStart = (e: TouchEvent) => {
			if (!narrow() || e.touches.length !== 1) return;
			startY = e.touches[0].clientY;
			startT = performance.now();
			pulling = false;
		};
		const onMove = (e: TouchEvent) => {
			if (!narrow() || e.touches.length !== 1) return;
			const d = e.touches[0].clientY - startY;
			// only a downward pull that starts with the content at its top moves the sheet
			if (!pulling && (d <= 4 || el.scrollTop > 0)) return;
			pulling = true;
			sheetDragging = true;
			e.preventDefault();
			sheetY = Math.max(0, d);
		};
		const onEnd = () => {
			if (!pulling) return;
			pulling = false;
			sheetDragging = false;
			const v = sheetY / Math.max(1, performance.now() - startT);
			if (sheetY > 90 || v > 0.5) closeSheet();
			else sheetY = 0;
		};
		el.addEventListener('touchstart', onStart, { passive: true });
		el.addEventListener('touchmove', onMove, { passive: false });
		el.addEventListener('touchend', onEnd);
		el.addEventListener('touchcancel', onEnd);
		return () => {
			el.removeEventListener('touchstart', onStart);
			el.removeEventListener('touchmove', onMove);
			el.removeEventListener('touchend', onEnd);
			el.removeEventListener('touchcancel', onEnd);
		};
	});
	let detail = $state<AssetDetail | null>(null);
	let animating = $state(false);
	let closing = $state(false);
	let editing = $state(false);
	let exporting = $state(false);
	let adjustingDate = $state(false);
	/** The trim editor is open for the current video (draft range in seconds). */
	let trimming = $state(false);
	let trimStart = $state(0);
	let trimEnd = $state(0);
	let trimBusy = $state(false);

	function openTrim() {
		if (!asset || asset.dur == null || asset.live) return;
		trimStart = asset.tr?.[0] ?? 0;
		trimEnd = asset.tr?.[1] ?? asset.dur;
		trimming = true;
		infoOpen = false;
	}

	async function trimCall(work: () => Promise<{ asset: CatalogAsset }>, after?: (a: CatalogAsset) => void) {
		trimBusy = true;
		try {
			const r = await work();
			if (after) after(r.asset);
			else app.patchAsset(r.asset);
			trimming = false;
			app.reload();
		} catch (e) {
			alert((e as Error).message);
		} finally {
			trimBusy = false;
		}
	}
	const canEdit = typeof navigator !== 'undefined' && 'gpu' in navigator;
	/** Displayed pixel size of loaded previews (an edit's crop changes the aspect). */
	let dims = $state(new Map<string, { w: number; h: number }>());

	// gesture state
	let dx = $state(0);
	let dy = $state(0);
	let scale = $state(1);
	let tx = $state(0);
	let ty = $state(0);
	let fullRes = $state(false);
	/** Previews that finished loading (their blurred placeholder is hidden). */
	let ready = $state(new Set<string>());

	const SLIDE_GAP = 24;
	const pitch = $derived(vw + SLIDE_GAP);
	const dismissProgress = $derived(scale === 1 ? Math.min(1, Math.max(0, dy) / 300) : 0);

	const displayable = ['public.jpeg', 'public.png', 'org.webmproject.webp', 'com.compuserve.gif'];
	const originalShowable = $derived(
		!!detail && (displayable.includes(detail.asset.mime) || (detail.asset.mime === 'public.heic' && app.fmt === 'heic'))
	);

	$effect(() => {
		const current = id;
		detail = null;
		fullRes = false;
		api.asset(current)
			.then((d) => {
				if (current === id) detail = d;
			})
			.catch(() => {});
		// prefetch neighbours
		for (const n of [ids[index - 1], ids[index + 1]]) {
			const a = n && app.lookup(n);
			if (a) new Image().src = previewUrl(a.id, a.ev, app.fmt);
		}
	});

	/** When the open photo's current edit was saved (shown in the info panel). */
	let editedAt = $state<string | null>(null);
	$effect(() => {
		const current = id;
		const ev = asset?.ev ?? 0;
		editedAt = null;
		if (!infoOpen || ev === 0) return;
		api.edits(current)
			.then((h) => {
				if (current === id) editedAt = h.versions.find((v) => v.version === h.current)?.createdAt ?? null;
			})
			.catch(() => {});
	});

	$effect(() => {
		// The original would hide an edit: deep zoom only swaps in the original for unedited photos.
		// Local mode: the original comes off this Mac's disk, so it is loaded at the first zoom step.
		if (scale >= (app.local ? 1.05 : 1.6) && originalShowable && asset?.ev === 0 && !isVideo) fullRes = true;
	});

	// The original is downloaded and decoded off-screen while the zoomed preview stays up; it is only
	// put on screen once decoded, so painting it can't stall zooming (a 48 MP photo takes a while).
	/** Blob URL of the decoded original, once ready. */
	let fullSrc = $state<string | null>(null);
	/** fetching: the Mac is getting the original from an rclone remote (`remote`) before it can send it;
	 *  loading: the original is coming from the Mac to this device. */
	let fullStatus = $state<{ phase: 'fetching' | 'loading' | 'decoding'; received: number; total: number; remote?: string } | null>(null);
	$effect(() => {
		if (!fullRes) return;
		const current = id;
		const ctl = new AbortController();
		let url: string | null = null;
		let stopped = false;
		fullStatus = { phase: 'loading', received: 0, total: 0 };
		(async () => {
			// on a remote source, the Mac first fetches the original (seconds to minutes): say so
			const where = await api.originalWhere(current, ctl.signal);
			if (where && !where.onMac && !stopped) fullStatus = { phase: 'fetching', received: 0, total: 0, remote: where.remote ?? undefined };
			const res = await fetch(originalUrl(current), { signal: ctl.signal });
			if (!stopped) fullStatus = { phase: 'loading', received: 0, total: Number(res.headers.get('content-length')) || 0 };
			if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
			const total = Number(res.headers.get('content-length')) || 0;
			const reader = res.body.getReader();
			const chunks: Uint8Array[] = [];
			let received = 0;
			let shown = 0;
			for (;;) {
				const { done, value } = await reader.read();
				if (done) break;
				chunks.push(value);
				received += value.length;
				// a few updates per MB are plenty
				if (received - shown > 256 * 1024) {
					shown = received;
					fullStatus = { phase: 'loading', received, total };
				}
			}
			if (stopped) return;
			url = URL.createObjectURL(new Blob(chunks as BlobPart[], { type: res.headers.get('content-type') ?? '' }));
			fullStatus = { phase: 'decoding', received, total };
			const img = new Image();
			img.decoding = 'async';
			img.src = url;
			await img.decode();
			if (stopped) return;
			fullSrc = url;
			fullStatus = null;
		})().catch(() => {
			if (!stopped) fullStatus = null; // keep the preview
		});
		return () => {
			stopped = true;
			ctl.abort();
			fullStatus = null;
			fullSrc = null;
			const u = url;
			// after the <img> using it is gone
			if (u) setTimeout(() => URL.revokeObjectURL(u), 1000);
		};
	});
	const mb = (n: number) => (n / 1024 ** 2).toFixed(1);

	/** The open video's file size (the original's length, read with a one-byte range request). */
	let fileBytes = $state<number | null>(null);
	$effect(() => {
		const current = id;
		fileBytes = null;
		if (!infoOpen || !isVideo || !net.online) return;
		const ctl = new AbortController();
		fetch(originalUrl(current), { headers: { Range: 'bytes=0-0' }, cache: 'no-store', signal: ctl.signal })
			.then((r) => {
				r.body?.cancel();
				if (!r.ok || current !== id) return;
				fileBytes = r.status === 206 ? contentRangeTotal(r.headers.get('Content-Range')) : Number(r.headers.get('Content-Length')) || null;
			})
			.catch(() => {});
		return () => ctl.abort();
	});

	/** Folders holding the open photo (a Takeout copy can sit in several), with links to them. */
	const folderLinks = $derived(
		(asset?.folders ?? [])
			.map((fid) => app.folders.find((f) => f.id === fid))
			.filter((f): f is NonNullable<typeof f> => !!f)
			.map((f) => {
				const top = app.folders.find((r) => r.root === f.root && r.relPath === '');
				const source = f.root === 'uploads' ? 'Uploads' : f.root === 'library' ? LOCAL_FOLDERS : top?.name || 'Source';
				// a Photos library is shown as one (its folders are 0…F)
				if (isPhotosRoot(f.root)) return { id: f.id, href: folderHref(f.root, ''), name: source };
				return { id: f.id, href: folderHref(f.root, f.relPath), name: f.relPath ? `${source}/${f.relPath}` : source };
			})
	);
	const albumLinks = $derived(asset ? app.albums.filter((al) => al.assetIds.includes(asset.id)) : []);

	/** Faces in the open photo (people hidden from People are left out). */
	const faces = $derived(
		(detail?.faces ?? []).filter((f) => f.personId == null || !app.personById.get(f.personId)?.hidden)
	);

	/** Names a face nobody was recognised in: joins an existing person with that name, or creates one. */
	async function nameFace(faceId: number) {
		const name = prompt('Who is this?')?.trim();
		if (!name) return;
		try {
			const same = app.people.find((p) => p.name?.toLowerCase() === name.toLowerCase());
			if (same) await api.assignFace(faceId, same.id);
			else await api.createPerson(name, [faceId]);
			const current = id;
			const d = await api.asset(current);
			if (current === id) detail = d;
			app.reload();
		} catch (e) {
			alert((e as Error).message);
		}
	}

	/** Takes a wrongly recognised person off a face: that face is never matched to them again. */
	async function removeFaceFromPerson(faceId: number, name: string | null) {
		if (!confirm(name ? `This isn't ${name}?` : "This isn't the same person?")) return;
		try {
			await api.assignFace(faceId, null);
			const current = id;
			const d = await api.asset(current);
			if (current === id) detail = d;
			app.reload();
		} catch (e) {
			alert((e as Error).message);
		}
	}

	function openEditor() {
		if (!asset || !net.online || !canEdit || isVideo) return;
		resetZoom();
		editing = true;
	}

	/** Rotations of the shown photos still being saved (the picture turns when its save is done). */
	let rotations = $state(0);
	/** One click instead of edit → rotate → done: the current edit turns with the photo. */
	function rotate(clockwise: boolean) {
		if (!asset || !net.online || isVideo) return;
		resetZoom();
		rotations++;
		rotatePhotos([asset.id], clockwise, {
			preview: true,
			beforeSwap: (pid) => {
				const a = app.byId.get(pid);
				if (!a || a.id !== asset?.id) return;
				const src = previewUrl(a.id, a.ev, app.fmt);
				ghost = { id: a.id, src, style: `transform: translate(${tx}px, ${ty}px) scale(${scale})${turnTransform(a)}` };
				setTimeout(() => ghost?.src === src && (ghost = null), 4000); // never stuck
			}
		})
			.catch((e) => alert(`Couldn't rotate the photo: ${(e as Error).message}`))
			.finally(() => rotations--);
	}

	function toggleFavorite() {
		if (asset && net.online) setFavorite([asset.id], !asset.fav).catch((e) => alert(e.message));
	}

	/** Takes the shown photo out of this list (delete, restore…), then shows its neighbour or closes. */
	async function leave(work: (id: string) => Promise<unknown>) {
		if (!asset || !net.online) return;
		const gone = asset.id;
		const neighbour = ids[index + 1] ?? ids[index - 1];
		try {
			stopLive();
			resetZoom();
			if (neighbour) onChange(neighbour);
			await work(gone);
			if (!neighbour) onClose();
		} catch (e) {
			if (neighbour) onChange(gone);
			alert((e as Error).message);
		}
	}

	/** `immediate` (⌘⌫ / Ctrl+Delete): no question, Undo instead. */
	function removeUpload(immediate = false) {
		if (!asset || !net.online) return;
		const id = asset.id;
		const msg = app.isUpload(id)
			? "It stays in the Trash until you delete it there (then it's deleted from disk)."
			: 'Its file stays where it is (it is never deleted): it is only hidden here. Restore it from the Trash any time.';
		deleteFlow
			.remove([id], app.isUpload(id) ? 'Delete this uploaded photo?' : 'Hide this photo?', msg, () => leave((x) => deletePhotos([x])), immediate)
			.catch((e) => alert((e as Error).message));
	}

	function deletePermanently() {
		if (!confirm("Delete this photo permanently? The file is deleted from disk; this can't be undone.")) return;
		leave((id) => deleteForever([id]));
	}

	/** The open Trash item. */
	const trashItem = $derived(trash && asset ? app.trash.find((x) => x.asset.id === asset.id) : undefined);

	function resetZoom() {
		scale = 1;
		tx = 0;
		ty = 0;
	}

	async function animateTo(update: () => void) {
		animating = true;
		update();
		await new Promise((r) => setTimeout(r, 260));
		animating = false;
	}

	/** Next/previous photo. Swipes slide; keys and buttons switch instantly. */
	async function go(delta: number, slide = false) {
		const next = index + delta;
		if (next < 0 || next >= ids.length) {
			if (dx !== 0) await animateTo(() => (dx = 0));
			return;
		}
		if (slide) await animateTo(() => (dx = -delta * pitch));
		dx = 0;
		resetZoom();
		stopLive();
		onChange(ids[next]);
	}

	/** Rect of the grid thumbnail for this asset, if it is on screen. */
	function thumbRect(assetId: string): DOMRect | null {
		const el = document.querySelector(`[data-asset-id="${assetId}"]`);
		if (!el) return null;
		const r = el.getBoundingClientRect();
		return r.bottom > 0 && r.top < vh ? r : null;
	}

	/** The picture turned ahead of the server's new rendition (rotate), shrunk to fit when on its side. */
	function turnTransform(a: { id: string; ev: number; w: number; h: number }) {
		const n = pendingTurns.get(a.id) ?? 0;
		if (!n) return '';
		const d = dims.get(`${a.id}/${a.ev}`) ?? { w: a.w, h: a.h };
		const fit = Math.min(vw / d.w, vh / d.h);
		const w = d.w * fit;
		const h = d.h * fit;
		const k = n % 2 ? Math.min(vw / h, vh / w) : 1;
		return ` rotate(${n * 90}deg) scale(${k})`;
	}

	// When a rotation's new rendition replaces the picture, the old one (turned on the client) stays on
	// top until the new one is decoded: swapping the <img> source alone shows a black frame first.
	let ghost = $state<{ id: string; src: string; style: string } | null>(null);
	/** Rect the image occupies when fitted into the viewport. */
	function fittedRect(): { x: number; y: number; w: number; h: number } {
		const a = asset;
		if (!a) return { x: 0, y: 0, w: vw, h: vh };
		const d = dims.get(`${a.id}/${a.ev}`) ?? { w: a.w, h: a.h };
		const s = Math.min(vw / d.w, vh / d.h);
		const w = d.w * s;
		const h = d.h * s;
		return { x: (vw - w) / 2, y: (vh - h) / 2, w, h };
	}

	let stage: HTMLDivElement;

	function flip(from: DOMRect, reverse: boolean): Animation | null {
		const img = stage?.querySelector<HTMLElement>('.slide.current .frame');
		if (!img) return null;
		const to = fittedRect();
		const s = Math.max(from.width / to.w, from.height / to.h);
		const fx = from.x + from.width / 2 - (to.x + to.w / 2);
		const fy = from.y + from.height / 2 - (to.y + to.h / 2);
		const frames = [
			{ transform: `translate(${fx}px, ${fy}px) scale(${s})` },
			{ transform: 'translate(0, 0) scale(1)' }
		];
		return img.animate(reverse ? frames.reverse() : frames, {
			duration: 280,
			easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)',
			// Opening must not hold its end state: a finished animation that "fills forwards" keeps
			// overriding the frame's own transform, so pinch/double-tap zoom changed nothing on screen.
			// (It ends at the frame's resting transform, so letting go is seamless.) Closing holds its
			// end state until the viewer is removed.
			fill: reverse ? 'forwards' : 'none'
		});
	}

	async function close() {
		if (closing) return;
		closing = true;
		stopLive();
		const r = scale === 1 ? thumbRect(id) : null;
		if (r) {
			const anim = flip(r, true);
			await anim?.finished.catch(() => {});
		}
		onClose();
	}

	onMount(() => {
		const r = thumbRect(id);
		if (r) flip(r, false);
		document.documentElement.style.overflow = 'hidden';
		const onResize = () => {
			vw = window.innerWidth;
			vh = window.innerHeight;
		};
		const onKey = (e: KeyboardEvent) => {
			if (editing || exporting) return;
			// The video scrubber has keyboard focus: its arrow keys seek.
			if (e.target instanceof HTMLInputElement && e.key !== 'Escape') return;
			if (e.key === 'ArrowRight') go(1);
			else if (e.key === 'ArrowLeft') go(-1);
			else if (e.key === 'Escape' && infoOpen) infoOpen = false;
			else if (e.key === ' ' && isVideo && player) {
				e.preventDefault();
				player.toggle();
			}
			else if (e.key === 'Escape' || e.key === ' ') {
				e.preventDefault();
				close();
			} else if (e.key === 'i') infoOpen = !infoOpen;
			else if (e.key === 'f' && !trash) toggleFavorite();
			else if (deleteKey(e) && !trash && !document.querySelector('[role=alertdialog]')) {
				e.preventDefault();
				removeUpload(deleteKey(e) === 'now');
			} else if ((e.key === 'e' || e.key === 'Enter') && !trash && !(e.target as HTMLElement).closest?.('button')) openEditor();
			else if (['[', ']', 'l', 'L', 'r', 'R'].includes(e.key) && !trash && !e.metaKey && !e.ctrlKey && !e.altKey)
				rotate(e.key === ']' || e.key.toLowerCase() === 'r');
		};
		// Leaving the app or window mid-hold (or mid-hover) may never deliver pointerup/leave: stop there.
		const onLeave = () => {
			if (!holding && !livePlaying && !holdTimer) return;
			stopLive();
			pointers.clear();
			axis = null;
			if (dx !== 0 || dy !== 0) animateTo(() => ((dx = 0), (dy = 0)));
		};
		const onVisibility = () => {
			if (document.visibilityState === 'hidden') onLeave();
		};
		window.addEventListener('resize', onResize);
		window.addEventListener('keydown', onKey);
		window.addEventListener('blur', onLeave);
		document.addEventListener('visibilitychange', onVisibility);
		stage.addEventListener('gesturestart', onGestureStart, { passive: false });
		stage.addEventListener('gesturechange', onGestureChange, { passive: false });
		return () => {
			stage.removeEventListener('gesturestart', onGestureStart);
			stage.removeEventListener('gesturechange', onGestureChange);
			document.documentElement.style.overflow = '';
			window.removeEventListener('resize', onResize);
			window.removeEventListener('keydown', onKey);
			window.removeEventListener('blur', onLeave);
			document.removeEventListener('visibilitychange', onVisibility);
		};
	});

	// ---- pointer gestures -------------------------------------------------
	const pointers = new Map<number, { x: number; y: number }>();
	let axis: 'x' | 'y' | 'pan' | 'pinch' | null = null;
	let start = { x: 0, y: 0, t: 0, tx: 0, ty: 0, scale: 1, dist: 1, cx: 0, cy: 0 };
	let lastTap = 0;
	let tapTimer: ReturnType<typeof setTimeout> | undefined;

	// Live Photo: a single press held 300 ms without moving (and not zoomed) plays the motion until
	// release. While it plays, moves don't page; another finger ends it (and starts afresh); the release doesn't
	// toggle the chrome. `livePlaying` is also set by hovering the LIVE badge (LiveOverlay).
	let livePlaying = $state(false);
	let holding = false;
	let holdTimer: ReturnType<typeof setTimeout> | undefined;

	function stopLive() {
		clearTimeout(holdTimer);
		holdTimer = undefined;
		holding = false;
		livePlaying = false;
	}

	function dist() {
		const [a, b] = [...pointers.values()];
		return Math.hypot(a.x - b.x, a.y - b.y);
	}
	function center() {
		const [a, b] = [...pointers.values()];
		return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
	}

	function clampPan() {
		const f = fittedRect();
		const maxX = Math.max(0, (f.w * scale - vw) / 2);
		const maxY = Math.max(0, (f.h * scale - vh) / 2);
		tx = Math.max(-maxX, Math.min(maxX, tx));
		ty = Math.max(-maxY, Math.min(maxY, ty));
	}

	/** Zoom to `next` keeping the screen point (px, py) fixed. */
	function zoomAt(next: number, px: number, py: number) {
		if (isVideo) return;
		next = Math.max(1, Math.min(6, next));
		const ox = px - vw / 2;
		const oy = py - vh / 2;
		tx = ox - ((ox - tx) * next) / scale;
		ty = oy - ((oy - ty) * next) / scale;
		scale = next;
		if (scale === 1) {
			tx = 0;
			ty = 0;
		}
		clampPan();
	}

	function onPointerDown(e: PointerEvent) {
		if ((e.target as HTMLElement).closest('button, a, input, .info, .video-controls')) return;
		if (isVideo && pointers.size > 0) return; // videos don't zoom: a second finger is ignored
		if (holding) {
			// The holding pointer is still down (or its pointerup was lost, e.g. the app was backgrounded
			// mid-hold): a new pointer ends the hold and starts afresh, so the stage can never wedge.
			stopLive();
			pointers.clear();
			axis = null;
		}
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
		if (pointers.size === 2) {
			clearTimeout(holdTimer);
			holdTimer = undefined;
			holding = false;
			axis = 'pinch';
			const c = center();
			start = { ...start, scale, dist: dist(), cx: c.x, cy: c.y, tx, ty };
		} else if (pointers.size === 1) {
			axis = null;
			start = { ...start, x: e.clientX, y: e.clientY, t: performance.now(), tx, ty };
			if (asset?.live && !isVideo && scale === 1 && e.button === 0) {
				clearTimeout(holdTimer);
				holdTimer = setTimeout(() => {
					holdTimer = undefined;
					// A move (axis set at 8 px), a second finger or a zoom cancels the hold.
					if (pointers.size !== 1 || axis || scale !== 1) return;
					holding = true;
					livePlaying = true;
					// A tap just before the hold must not toggle the chrome (and hide the LIVE badge) mid-play.
					clearTimeout(tapTimer);
					tapTimer = undefined;
					lastTap = 0;
				}, 300);
			}
		}
	}

	function onPointerMove(e: PointerEvent) {
		if (!pointers.has(e.pointerId)) return;
		pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
		if (holding && livePlaying) return; // holding plays; it never pages or closes
		if (axis === 'pinch' && pointers.size === 2) {
			const c = center();
			const next = Math.max(1, Math.min(6, (start.scale * dist()) / start.dist));
			const ox = start.cx - vw / 2;
			const oy = start.cy - vh / 2;
			tx = ox - ((ox - start.tx) * next) / start.scale + (c.x - start.cx);
			ty = oy - ((oy - start.ty) * next) / start.scale + (c.y - start.cy);
			scale = next;
			clampPan();
			return;
		}
		const mx = e.clientX - start.x;
		const my = e.clientY - start.y;
		if (!axis) {
			if (Math.hypot(mx, my) < 8) return;
			clearTimeout(holdTimer);
			holdTimer = undefined;
			axis = scale > 1 ? 'pan' : Math.abs(mx) > Math.abs(my) ? 'x' : 'y';
		}
		if (axis === 'pan') {
			tx = start.tx + mx;
			ty = start.ty + my;
			clampPan();
		} else if (axis === 'x') {
			const atEdge = (index === 0 && mx > 0) || (index === ids.length - 1 && mx < 0);
			dx = atEdge ? mx / 3 : mx;
		} else if (axis === 'y') {
			if (infoOpen && narrow()) {
				// with the sheet up, a vertical drag on the photo moves the sheet, not the viewer
				sheetDragging = true;
				sheetY = Math.max(0, my);
			} else dy = my;
		}
	}

	function onPointerUp(e: PointerEvent) {
		if (!pointers.has(e.pointerId)) return;
		pointers.delete(e.pointerId);
		clearTimeout(holdTimer);
		holdTimer = undefined;
		if (holding) {
			// Release ends the motion. A hold is ≥ 300 ms, so it never counts as a tap below.
			const played = livePlaying;
			holding = false;
			livePlaying = false;
			if (played) {
				axis = null;
				return;
			}
		}
		if (axis === 'pinch') {
			if (pointers.size === 0) {
				axis = null;
				if (scale < 1.05) animateTo(resetZoom);
			}
			return;
		}
		const elapsed = performance.now() - start.t;
		if (axis === 'x') {
			const v = dx / Math.max(1, elapsed);
			if (dx < -vw * 0.2 || v < -0.5) go(1, true);
			else if (dx > vw * 0.2 || v > 0.5) go(-1, true);
			else animateTo(() => (dx = 0));
		} else if (axis === 'y') {
			const v = (infoOpen && narrow() ? sheetY : dy) / Math.max(1, elapsed);
			if (infoOpen && narrow()) {
				sheetDragging = false;
				if (sheetY > 90 || v > 0.5) closeSheet();
				else sheetY = 0;
			} else if (dy < -60 || v < -0.4) {
				// swipe up: info
				infoOpen = true;
				animateTo(() => (dy = 0));
			} else if (dy > 120 || v > 0.6) close();
			else animateTo(() => (dy = 0));
		} else if (!axis && elapsed < 300) {
			const now = performance.now();
			if (isVideo) chrome = !chrome;
			else if (now - lastTap < 300) {
				clearTimeout(tapTimer);
				lastTap = 0;
				animateTo(() => (scale > 1 ? resetZoom() : zoomAt(2.5, e.clientX, e.clientY)));
			} else {
				lastTap = now;
				tapTimer = setTimeout(() => (chrome = !chrome), 300);
			}
		}
		axis = null;
	}

	/** The system took the gesture: snap back, never navigate. */
	function onPointerCancel(e: PointerEvent) {
		pointers.delete(e.pointerId);
		if (holdTimer || holding) stopLive();
		axis = null;
		sheetDragging = false;
		sheetY = 0;
		animateTo(() => {
			dx = 0;
			dy = 0;
		});
	}

	function onWheel(e: WheelEvent) {
		e.stopPropagation();
		if (e.ctrlKey) {
			e.preventDefault();
			zoomAt(scale * Math.exp(-e.deltaY / 100), e.clientX, e.clientY);
		} else if (scale > 1) {
			e.preventDefault();
			tx -= e.deltaX;
			ty -= e.deltaY;
			clampPan();
		}
	}

	/** One-line gesture state for the debug overlay. */
	const debugState = () => {
		// What is actually drawn: the zoomed frame's on-screen width vs the viewport, and the images' state.
		const frame = stage?.querySelector<HTMLElement>('.slide.current .frame');
		const r = frame?.getBoundingClientRect();
		const imgs = [...(frame?.querySelectorAll<HTMLImageElement>('img') ?? [])]
			.map((i) => `${i.classList.contains('low') ? 'low' : i.src.includes('/original') ? 'orig' : 'prev'}:${i.complete ? i.naturalWidth + 'x' + i.naturalHeight : 'loading'}`)
			.join(' ');
		return `ptrs=${pointers.size}[${[...pointers.keys()].join(',')}] axis=${axis ?? '-'} scale=${scale.toFixed(2)}${animating ? ' ANIM' : ''}${fullRes ? ' FULL' : ''}${chrome ? '' : ' nochrome'}${infoOpen ? ' info' : ''} drawn=${r ? (r.width / vw).toFixed(2) : '?'}× ${imgs}`;
	};

	// Safari trackpad pinch
	let gestureStart = 1;
	function onGestureStart(e: Event) {
		e.preventDefault();
		e.stopPropagation();
		gestureStart = scale;
	}
	function onGestureChange(e: Event) {
		e.preventDefault();
		e.stopPropagation();
		// On iPhone the same pinch also arrives as two touch pointers, which zoom around the fingers.
		if (pointers.size >= 2) return;
		const g = e as unknown as { scale: number; clientX: number; clientY: number };
		zoomAt(gestureStart * g.scale, g.clientX ?? vw / 2, g.clientY ?? vh / 2);
	}

	const slides = $derived(
		[-1, 0, 1]
			.map((o) => ({ o, id: ids[index + o] }))
			.filter((s): s is { o: number; id: string } => !!s.id)
	);

	const fmtExposure = (s: number | null) => (s == null ? '' : s >= 1 ? `${s}s` : `1/${Math.round(1 / s)}s`);
	const camera = $derived(
		detail ? [detail.asset.cameraMake, detail.asset.cameraModel].filter(Boolean).join(' ').trim() : ''
	);
</script>

<div
	class="viewer"
	class:chrome
	class:info-open={infoOpen}
	style="--dismiss: {dismissProgress}"
	role="dialog"
	aria-modal="true"
	aria-label="Photo viewer"
>
	<div class="backdrop" style="opacity: {closing ? 0 : 1 - dismissProgress}"></div>

	<div
		class="stage"
		bind:this={stage}
		role="presentation"
		onpointerdown={onPointerDown}
		onpointermove={onPointerMove}
		onpointerup={onPointerUp}
		onpointercancel={onPointerCancel}
		oncontextmenu={(e) => {
			if (holding || holdTimer) e.preventDefault(); // a long press on the photo plays a Live Photo
		}}
		onwheel={onWheel}
	>
		{#each slides as s (s.id)}
			{@const a = app.lookup(s.id)}
			{#if a}
				<div
					class="slide"
					class:current={s.o === 0}
					class:animating
					style="transform: translate({s.o * pitch + dx}px, {s.o === 0 ? (dy < 0 ? dy * 0.35 : dy) : 0}px) scale({s.o === 0
						? 1 - dismissProgress * 0.3
						: 1})"
				>
					<div
						class="frame"
						style={s.o === 0 ? `transform: translate(${tx}px, ${ty}px) scale(${scale})${turnTransform(a)}` : ''}
						class:animating
						class:turning={s.o === 0 && (pendingTurns.get(a.id) ?? 0) !== 0}
					>
						{#if !ready.has(a.id)}
							<img class="low" src={thumbUrl(a.id, a.ev, app.fmt)} alt="" draggable="false" />
						{/if}
						<img
							class="high"
							src={previewUrl(a.id, a.ev, app.fmt)}
							alt={a.name}
							draggable="false"
							onload={(e) => {
								const img = e.currentTarget as HTMLImageElement;
								dims = new Map(dims).set(`${a.id}/${a.ev}`, { w: img.naturalWidth, h: img.naturalHeight });
								// Decode before hiding the placeholder: the neighbouring slides (±1) are decoded
								// while off-screen, so swiping to them paints at once (Safari and desktop alike).
								img.decode()
									.catch(() => {})
									.finally(() => {
										ready = new Set(ready).add(a.id);
										// the old picture leaves once the new one has been painted (two frames later)
										if (ghost?.id === a.id && img.src.endsWith(previewUrl(a.id, a.ev, app.fmt))) {
											const g = ghost;
											requestAnimationFrame(() => requestAnimationFrame(() => ghost === g && (ghost = null)));
										}
									});
							}}
						/>
						{#if s.o === 0 && fullSrc}
							<img class="high" src={fullSrc} alt="" draggable="false" decoding="async" />
						{/if}
						{#if s.o === 0 && a.dur != null}
							<VideoPlayer
								bind:this={player}
								asset={a}
								active={!closing}
								onDownload={() => (exporting = true)}
								trim={trimming ? [trimStart, trimEnd] : (a.tr ?? null)}
								editing={trimming}
							/>
						{/if}
						{#if s.o === 0 && a.live && a.dur == null}
							<LiveOverlay
								asset={a}
								active={!closing}
								zoomed={scale > 1}
								still={dims.get(`${a.id}/${a.ev}`)}
								bind:playing={livePlaying}
							/>
						{/if}
					</div>
					{#if s.o === 0 && ghost?.id === a.id}
						<div class="frame ghost" style={ghost.style}>
							<img class="high" src={ghost.src} alt="" draggable="false" />
						</div>
					{/if}
				</div>
			{/if}
		{/each}
	</div>

	<header class="bar top">
		<button class="icon-btn" onclick={close} aria-label="Close"><Icon name="back" /></button>
		{#if asset && !isVideo}
			<!-- Desktop: zoom slider (logarithmic, 1×–6×) like Photos on the Mac -->
			<div class="zoom-ctl">
				<button onclick={() => animateTo(() => zoomAt(scale / 1.5, vw / 2, vh / 2))} disabled={scale <= 1}
					aria-label="Zoom out" title="Zoom out">−</button>
				<input type="range" min="0" max="1000" aria-label="Zoom"
					value={Math.round((Math.log(scale) / Math.log(6)) * 1000)}
					oninput={(e) => zoomAt(6 ** (Number((e.currentTarget as HTMLInputElement).value) / 1000), vw / 2, vh / 2)} />
				<button onclick={() => animateTo(() => zoomAt(scale * 1.5, vw / 2, vh / 2))} disabled={scale >= 6}
					aria-label="Zoom in" title="Zoom in">+</button>
			</div>
		{/if}
		<div class="title">
			{#if asset}
				<div class="date">{isoLabel(asset.t, asset.tz)}</div>
				<div class="sub muted">
					{index + 1} of {ids.length}{#if trashItem?.virtual} · hidden (its file is untouched){:else if trashItem} · upload (can be deleted from disk){/if}
				</div>
			{/if}
		</div>
		{#if trash}
			<button class="icon-btn info-btn" class:on={infoOpen} onclick={() => (infoOpen = !infoOpen)} aria-label="Info"
				><Icon name="info" /></button
			>
			{#if net.online}
				{#if app.local && asset}
					<button class="icon-btn" onclick={() => reveal({ asset: asset.id })} title="Reveal in Finder" aria-label="Reveal in Finder"
						><Icon name="finder" /></button>
				{/if}
				<button class="btn" onclick={() => leave((id) => restoreFromTrash([id]))}>Restore</button>
				{#if trashItem && !trashItem.virtual}
					<button class="icon-btn danger" onclick={deletePermanently} title="Delete permanently" aria-label="Delete permanently"
						><Icon name="trash" /></button>
				{/if}
			{/if}
		{:else}
		<button class="icon-btn heart" class:filled={asset?.fav} onclick={toggleFavorite} disabled={!net.online}
			aria-label={asset?.fav ? 'Unfavourite' : 'Favourite'} aria-pressed={asset?.fav ?? false}><Icon name="heart" /></button>
		<button class="icon-btn info-btn" class:on={infoOpen} onclick={() => (infoOpen = !infoOpen)} aria-label="Info"
			><Icon name="info" /></button
		>
		{#if net.online}
			{#if isVideo && !asset?.live}
				<button class="icon-btn" class:on={trimming} onclick={() => (trimming ? (trimming = false) : openTrim())} title="Trim"
					aria-label="Trim"><Icon name="trim" /></button>
			{/if}
			{#if !isVideo}
				<button class="icon-btn rot" class:busy={rotations > 0} onclick={() => rotate(false)} title="Rotate left (L)"
					aria-label="Rotate left"><Icon name="rotate" /></button>
				<button class="icon-btn rot right" class:busy={rotations > 0} onclick={() => rotate(true)} title="Rotate right (R)"
					aria-label="Rotate right"><span class="mirror"><Icon name="rotate" /></span></button>
				<button class="icon-btn" onclick={openEditor} disabled={!canEdit}
					title={canEdit ? 'Edit (E)' : "Editing needs WebGPU, which this browser doesn't offer"}
					aria-label="Edit"><Icon name="edit" /></button>
			{/if}
			{#if app.local && asset}
				<button class="icon-btn" onclick={() => reveal({ asset: asset.id })} title="Reveal in Finder" aria-label="Reveal in Finder"
					><Icon name="finder" /></button>
			{/if}
			<button class="icon-btn" onclick={() => (exporting = true)} title="Download / share" aria-label="Download"><Icon name="download" /></button>
			{#if asset}
				<button class="icon-btn" onclick={() => removeUpload()} title="Delete" aria-label="Delete"><Icon name="trash" /></button>
			{/if}
		{/if}
		{/if}
	</header>

	{#if fullStatus}
		<div class="full-status" role="status" aria-live="polite">
			<span class="spin"></span>
			{#if fullStatus.phase === 'fetching'}
				Full resolution · the Mac is getting it from {fullStatus.remote ?? 'the remote'}…
			{:else if fullStatus.phase === 'decoding'}
				Full resolution · decoding…
			{:else if fullStatus.total}
				Full resolution · {mb(fullStatus.received)} of {mb(fullStatus.total)} MB
			{:else}
				Loading full resolution…
			{/if}
		</div>
	{/if}

	{#if ids.length > 1}
		<button class="nav prev" onclick={() => go(-1)} disabled={index === 0} aria-label="Previous"
			><Icon name="left" size={28} /></button
		>
		<button class="nav next" onclick={() => go(1)} disabled={index === ids.length - 1} aria-label="Next"
			><Icon name="right" size={28} /></button
		>
	{/if}

	{#if editing && asset}
		<Editor {asset} onClose={() => (editing = false)} />
	{/if}
	{#if trimming && asset && isVideo}
		<TrimBar
			{asset}
			bind:start={trimStart}
			bind:end={trimEnd}
			busy={trimBusy}
			onSeek={(t) => player?.seekTo(t)}
			onSave={() => trimCall(() => api.setTrim(asset.id, trimStart, trimEnd))}
			onSaveNew={() =>
				trimCall(
					() => api.trimCopy(asset.id, trimStart, trimEnd),
					(a) => alert(`Saved as a new video in Uploads (${a.name}).`)
				)}
			onRevert={() => trimCall(() => api.revertTrim(asset.id))}
			onCancel={() => (trimming = false)}
		/>
	{/if}

	{#if adjustingDate && asset}
		<AdjustDateSheet ids={[asset.id]} onClose={() => (adjustingDate = false)} />
	{/if}

	{#if exporting && asset}
		<ExportSheet {asset} onClose={() => (exporting = false)} />
	{/if}

	{#if infoOpen && asset}
		<aside
			class="info"
			class:dragging={sheetDragging}
			bind:this={sheetEl}
			style:transform={sheetY ? `translateY(${sheetY}px)` : undefined}
		>
			<div class="grabber" aria-hidden="true"></div>
			<button class="icon-btn info-close" onclick={closeSheet} aria-label="Close info" title="Close (Esc)"
				><Icon name="close" /></button>
			<h3>{asset.name}</h3>
			<dl>
				<dt>Taken</dt>
				<dd>
					{captureLabel(asset.t, asset.tz)}
					<span class="muted">{offsetLabel(asset.tz)}{detail && !asset.md ? ` · from ${detail.asset.dateSource}` : ''}</span>
					{#if asset.md}
						<div class="muted">
							Date adjusted{detail?.asset.fileTakenAt
								? ` · originally ${captureLabel(detail.asset.fileTakenAt, detail.asset.fileTzOffset ?? null)}`
								: ''}
						</div>
					{/if}
					{#if net.online && !trash}
						<button class="link adjust" onclick={() => (adjustingDate = true)}>Adjust…</button>
					{/if}
				</dd>
				{#if camera}
					<dt>Camera</dt>
					<dd>
						{camera}
						{#if detail?.asset.lens}<div class="muted">{detail.asset.lens}</div>{/if}
						<div class="muted">
							{[
								detail?.asset.aperture ? `ƒ/${detail.asset.aperture}` : '',
								fmtExposure(detail?.asset.shutter ?? null),
								detail?.asset.iso ? `ISO ${detail.asset.iso}` : '',
								detail?.asset.focal ? `${Math.round(detail.asset.focal)} mm` : ''
							]
								.filter(Boolean)
								.join(' · ')}
						</div>
					</dd>
				{/if}
				{#if asset.dur != null}
					<dt>Duration</dt>
					<dd>
						{formatDuration(asset.tr ? asset.tr[1] - asset.tr[0] : asset.dur)}
						{#if asset.tr}<span class="muted">· trimmed from {formatDuration(asset.dur)}</span>{/if}
					</dd>
					<dt>Resolution</dt>
					<dd>{asset.w} × {asset.h}</dd>
					{#if detail?.asset.videoCodec}
						<dt>Codec</dt>
						<dd>{codecLabel(detail.asset.videoCodec)}</dd>
					{/if}
					{#if fileBytes != null}
						<dt>File size</dt>
						<dd>{formatBytes(fileBytes)}</dd>
					{/if}
				{:else}
					<dt>Size</dt>
					<dd>{asset.w} × {asset.h} <span class="muted">({((asset.w * asset.h) / 1e6).toFixed(1)} MP)</span></dd>
				{/if}
				{#if asset.ev > 0}
					<dt>Edited</dt>
					<dd>
						Yes
						{#if editedAt}<span class="muted"
								>· {isoDateTime(editedAt)}</span
							>{/if}
					</dd>
				{/if}
				{#if detail?.asset.lat != null && detail?.asset.lon != null}
					<dt>Location</dt>
					<dd>
						{#if detail.place}
							<a href="/places/{detail.place.id}">{detail.place.name}</a>
							<span class="muted">{[detail.place.region, detail.place.country].filter((x) => x && x !== detail?.place?.name).join(', ')}</span>
							<br />
						{/if}
						<a class="muted"
							href="https://www.openstreetmap.org/?mlat={detail.asset.lat}&mlon={detail.asset.lon}#map=14/{detail.asset
								.lat}/{detail.asset.lon}"
							target="_blank"
							rel="noreferrer">{detail.asset.lat.toFixed(5)}, {detail.asset.lon.toFixed(5)}</a
						>
					</dd>
				{/if}
				{#if faces.length}
					<dt>People</dt>
					<dd class="faces">
						{#each faces as f (f.id)}
							{@const p = f.personId != null ? app.personById.get(f.personId) : undefined}
							{#if p}
								<div class="face-wrap">
									<a class="face" href="/people/{p.id}" title="All photos of {p.name ?? 'this person'}">
										<FaceAvatar faceId={f.id} size={56} />
										<span class:unnamed={!p.name}>{p.name ?? 'Unnamed'}</span>
									</a>
									<button
										class="face-remove"
										disabled={!net.online}
										onclick={() => removeFaceFromPerson(f.id, p.name)}
										title={p.name ? `Not ${p.name}` : 'Not this person'}
										aria-label={p.name ? `Not ${p.name}` : 'Not this person'}><Icon name="close" size={12} /></button
									>
								</div>
							{:else}
								<button class="face" disabled={!net.online} onclick={() => nameFace(f.id)} title="Name this person">
									<FaceAvatar faceId={f.id} size={56} />
									<span class="unnamed">Add Name</span>
								</button>
							{/if}
						{/each}
					</dd>
				{:else if asset.pp?.length}
					<dt>People</dt>
					<dd class="people">
						{#each asset.pp as pid (pid)}
							{@const p = app.personById.get(pid)}
							{#if p}<a href="/people/{pid}">{p.name ?? 'Unnamed person'}</a>{/if}
						{/each}
					</dd>
				{/if}
				{#if detail?.asset.description}
					<dt>Description</dt>
					<dd>{detail.asset.description}</dd>
				{/if}
				{#if albumLinks.length}
					<dt>{albumLinks.length > 1 ? 'Albums' : 'Album'}</dt>
					<dd class="links">
						{#each albumLinks as al (al.id)}<a href="/albums/{al.id}">{al.title}</a>{/each}
					</dd>
				{/if}
				{#if folderLinks.length}
					<dt>{folderLinks.length > 1 ? 'Folders' : 'Folder'}</dt>
					<dd class="links">
						{#each folderLinks as f (f.id)}<a href={f.href}>{f.name}</a>{/each}
					</dd>
				{/if}
				{#if detail}
					<dt>{detail.files.length > 1 ? 'Files' : 'File'}</dt>
					{#each detail.files as f (f)}
						<dd class="file">{f}</dd>
					{/each}
				{/if}
			</dl>
			{#if detail?.text}
				<details class="text">
					<summary>Text in photo</summary>
					<pre>{detail.text}</pre>
					<button class="link adjust" onclick={() => navigator.clipboard?.writeText(detail?.text ?? '')}>Copy</button>
				</details>
			{/if}
		</aside>
	{/if}
	{#if gestureDebug.enabled}<GestureDebug snapshot={debugState} />{/if}
</div>

<style>
	.viewer {
		position: fixed;
		inset: 0;
		z-index: 100;
		touch-action: none;
		overscroll-behavior: contain;
		-webkit-user-select: none;
		user-select: none;
	}
	.backdrop {
		position: absolute;
		inset: 0;
		background: black;
		transition: background 0.25s;
	}
	.viewer.chrome .backdrop {
		background: var(--bg);
	}
	.stage {
		position: absolute;
		inset: 0;
		overflow: hidden;
		/* No iOS long-press callout on the photo (press and hold plays a Live Photo). */
		-webkit-touch-callout: none;
	}
	.slide {
		position: absolute;
		inset: 0;
		will-change: transform;
	}
	.frame {
		position: absolute;
		inset: 0;
		transform-origin: center;
	}
	.animating {
		transition: transform 0.26s cubic-bezier(0.2, 0.8, 0.2, 1);
	}
	.frame img {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		object-fit: contain;
		-webkit-user-drag: none;
	}
	.frame img.low {
		filter: blur(6px);
	}
	.bar {
		position: absolute;
		left: 0;
		right: 0;
		display: flex;
		align-items: center;
		gap: 4px;
		padding: calc(env(safe-area-inset-top) + 6px) 8px 6px;
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
		transition: opacity 0.2s;
		opacity: calc(1 - var(--dismiss) * 3);
	}
	.viewer:not(.chrome) .bar,
	.viewer:not(.chrome) .nav,
	.viewer:not(.chrome) :global(.video-controls),
	.viewer:not(.chrome) :global(.live-badge) {
		opacity: 0;
		pointer-events: none;
	}
	.top {
		top: 0;
	}
	.title {
		flex: 1;
		text-align: center;
		min-width: 0;
	}
	.date {
		font-weight: 600;
		font-size: 14px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.sub {
		font-size: 12px;
	}
	.heart.filled :global(path) {
		fill: currentColor;
	}
	/* the rotate icon points counter-clockwise; mirrored it points clockwise */
	.mirror {
		display: inline-flex;
		transform: scaleX(-1);
	}
	.frame.ghost {
		pointer-events: none;
	}
	/* turning ahead of the server; the new rendition replaces it without animating back */
	.frame.turning {
		transition: transform 0.22s ease-out;
	}
	.rot.busy {
		opacity: 0.5;
	}
	/* a phone: rotate left and right instead of Info (swiping the photo up shows its info there) */
	@media (max-width: 480px) {
		.info-btn {
			display: none;
		}
	}
	.icon-btn.on {
		background: rgba(10, 132, 255, 0.15);
	}
	.nav {
		display: none;
	}
	.zoom-ctl {
		display: none;
	}
	@media (hover: hover) and (min-width: 768px) {
		.zoom-ctl {
			display: flex;
			align-items: center;
			gap: 2px;
			height: 30px;
			padding: 0 6px;
			margin-left: 4px;
			border-radius: 999px;
			background: rgba(127, 127, 127, 0.14);
		}
		.zoom-ctl button {
			border: none;
			background: none;
			color: var(--fg-secondary);
			font-size: 17px;
			width: 22px;
			height: 26px;
			padding: 0;
			cursor: pointer;
			border-radius: 50%;
		}
		.zoom-ctl button:disabled {
			opacity: 0.35;
			cursor: default;
		}
		.zoom-ctl input {
			width: 110px;
			accent-color: var(--fg-secondary);
		}
	}
	.full-status {
		position: absolute;
		z-index: 5;
		left: 12px;
		bottom: calc(env(safe-area-inset-bottom) + 12px);
		display: flex;
		align-items: center;
		gap: 7px;
		padding: 5px 10px;
		border-radius: 999px;
		background: rgb(0 0 0 / 0.55);
		color: #fff;
		font-size: 12px;
		pointer-events: none;
		-webkit-backdrop-filter: blur(10px);
		backdrop-filter: blur(10px);
		animation: full-in 0.2s 0.3s both; /* quick loads never flash it */
	}
	.full-status .spin {
		width: 10px;
		height: 10px;
		border: 1.5px solid rgb(255 255 255 / 0.35);
		border-top-color: #fff;
		border-radius: 50%;
		animation: full-spin 0.8s linear infinite;
	}
	@keyframes full-spin {
		to {
			transform: rotate(360deg);
		}
	}
	@keyframes full-in {
		from {
			opacity: 0;
		}
	}
	@media (hover: hover) and (min-width: 768px) {
		.nav {
			display: flex;
			position: absolute;
			top: 50%;
			transform: translateY(-50%);
			border: none;
			border-radius: 50%;
			width: 44px;
			height: 44px;
			align-items: center;
			justify-content: center;
			background: var(--bg-bar);
			cursor: pointer;
			opacity: 0;
			transition: opacity 0.2s;
		}
		/* Shown on hover, but not in immersive mode (controls hidden). */
		.viewer.chrome:hover .nav:not(:disabled) {
			opacity: 1;
		}
		.prev {
			left: 16px;
		}
		.next {
			right: 16px;
		}
		.viewer.info-open .next {
			right: 356px;
		}
	}
	.info {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		max-height: 55dvh;
		overflow: auto;
		background: var(--bg-elevated);
		border-radius: 14px 14px 0 0;
		padding: 16px 18px calc(16px + env(safe-area-inset-bottom));
		box-shadow: 0 -4px 30px rgba(0, 0, 0, 0.2);
		-webkit-user-select: text;
		user-select: text;
		transition: transform 0.22s ease-out;
		animation: sheet-up 0.25s ease-out;
		overscroll-behavior: contain;
	}
	.info.dragging {
		transition: none;
	}
	.grabber {
		width: 36px;
		height: 5px;
		border-radius: 3px;
		background: var(--separator);
		margin: -8px auto 10px;
	}
	@keyframes sheet-up {
		from {
			transform: translateY(100%);
		}
	}
	@media (min-width: 768px) {
		.grabber {
			display: none;
		}
		.info {
			animation: none;
			left: auto;
			top: 0;
			width: 340px;
			max-height: none;
			border-radius: 0;
			padding-top: calc(env(safe-area-inset-top) + 64px);
		}
		.info-close {
			top: calc(env(safe-area-inset-top) + 56px);
		}
	}
	.info-close {
		position: absolute;
		top: 10px;
		right: 10px;
	}
	.faces {
		display: flex;
		flex-wrap: wrap;
		gap: 10px 12px;
		margin-top: 4px;
	}
	.face {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 3px;
		width: 64px;
		border: none;
		background: none;
		padding: 0;
		font: inherit;
		font-size: 12px;
		color: var(--fg);
		cursor: pointer;
		text-align: center;
	}
	.face-wrap {
		position: relative;
	}
	.face-remove {
		position: absolute;
		top: -4px;
		right: -2px;
		width: 22px;
		height: 22px;
		display: grid;
		place-items: center;
		padding: 0;
		border-radius: 50%;
		border: 1px solid var(--separator);
		background: var(--bg);
		color: var(--fg);
		cursor: pointer;
		opacity: 0.85;
	}
	.face-remove:hover:not(:disabled) {
		opacity: 1;
		color: var(--danger);
	}
	.face-remove:disabled {
		opacity: 0.4;
		cursor: default;
	}
	.face span {
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.face .unnamed {
		color: var(--accent);
	}
	.links {
		display: flex;
		flex-direction: column;
		gap: 2px;
		word-break: break-word;
	}
	.people {
		display: flex;
		flex-wrap: wrap;
		gap: 4px 12px;
	}
	.info h3 {
		margin: 0 40px 12px 0;
		font-size: 16px;
		word-break: break-all;
	}
	dl {
		margin: 0;
		font-size: 14px;
	}
	dt {
		font-size: 12px;
		color: var(--fg-secondary);
		margin-top: 12px;
	}
	dd {
		margin: 2px 0 0;
	}
	dd .muted {
		font-size: 13px;
	}
	.file {
		font-size: 12px;
		word-break: break-all;
		color: var(--fg-secondary);
	}
	.link.adjust {
		border: none;
		background: none;
		padding: 2px 0;
		color: var(--accent);
		cursor: pointer;
		font: inherit;
	}
	.text {
		margin: 10px 0 0;
		font-size: 14px;
	}
	.text summary {
		cursor: pointer;
		color: var(--text-secondary, gray);
	}
	.text pre {
		white-space: pre-wrap;
		font: inherit;
		margin: 6px 0;
		max-height: 200px;
		overflow: auto;
		user-select: text;
	}
</style>
