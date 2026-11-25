<script lang="ts">
	// Full-screen photo viewer: swipe/arrow navigation, swipe-down/Esc to close,
	// pinch / double-tap / ctrl+wheel zoom, info panel, download original.
	import { onMount } from 'svelte';
	import { api, originalUrl, previewUrl, thumbUrl, type AssetDetail } from '#lib/api.ts';
	import { captureLabel, offsetLabel } from '#lib/dates.ts';
	import { app, setFavorite } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import Icon from './Icon.svelte';
	import ExportSheet from './ExportSheet.svelte';
	import Editor from '#lib/editor/Editor.svelte';

	let {
		ids,
		id,
		onChange,
		onClose
	}: { ids: string[]; id: string; onChange: (id: string) => void; onClose: () => void } = $props();

	const index = $derived(Math.max(0, ids.indexOf(id)));
	const asset = $derived(app.byId.get(id));

	let vw = $state(window.innerWidth);
	let vh = $state(window.innerHeight);
	let chrome = $state(true);
	let infoOpen = $state(false);
	let detail = $state<AssetDetail | null>(null);
	let animating = $state(false);
	let closing = $state(false);
	let editing = $state(false);
	let exporting = $state(false);
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
			const a = n && app.byId.get(n);
			if (a) new Image().src = previewUrl(a.id, a.ev, app.fmt);
		}
	});

	$effect(() => {
		// The original would hide an edit: deep zoom only swaps in the original for unedited photos.
		if (scale >= 1.6 && originalShowable && asset?.ev === 0) fullRes = true;
	});

	function openEditor() {
		if (!asset || !net.online || !canEdit) return;
		resetZoom();
		editing = true;
	}

	function toggleFavorite() {
		if (asset && net.online) setFavorite([asset.id], !asset.fav).catch((e) => alert(e.message));
	}

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
		onChange(ids[next]);
	}

	/** Rect of the grid thumbnail for this asset, if it is on screen. */
	function thumbRect(assetId: string): DOMRect | null {
		const el = document.querySelector(`[data-asset-id="${assetId}"]`);
		if (!el) return null;
		const r = el.getBoundingClientRect();
		return r.bottom > 0 && r.top < vh ? r : null;
	}

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
			fill: 'forwards'
		});
	}

	async function close() {
		if (closing) return;
		closing = true;
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
			if (e.key === 'ArrowRight') go(1);
			else if (e.key === 'ArrowLeft') go(-1);
			else if (e.key === 'Escape' && infoOpen) infoOpen = false;
			else if (e.key === 'Escape' || e.key === ' ') {
				e.preventDefault();
				close();
			} else if (e.key === 'i') infoOpen = !infoOpen;
			else if (e.key === 'f') toggleFavorite();
			else if (e.key === 'e') openEditor();
		};
		window.addEventListener('resize', onResize);
		window.addEventListener('keydown', onKey);
		stage.addEventListener('gesturestart', onGestureStart, { passive: false });
		stage.addEventListener('gesturechange', onGestureChange, { passive: false });
		return () => {
			stage.removeEventListener('gesturestart', onGestureStart);
			stage.removeEventListener('gesturechange', onGestureChange);
			document.documentElement.style.overflow = '';
			window.removeEventListener('resize', onResize);
			window.removeEventListener('keydown', onKey);
		};
	});

	// ---- pointer gestures -------------------------------------------------
	const pointers = new Map<number, { x: number; y: number }>();
	let axis: 'x' | 'y' | 'pan' | 'pinch' | null = null;
	let start = { x: 0, y: 0, t: 0, tx: 0, ty: 0, scale: 1, dist: 1, cx: 0, cy: 0 };
	let lastTap = 0;
	let tapTimer: ReturnType<typeof setTimeout> | undefined;

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
		if ((e.target as HTMLElement).closest('button, a, .info')) return;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
		if (pointers.size === 2) {
			axis = 'pinch';
			const c = center();
			start = { ...start, scale, dist: dist(), cx: c.x, cy: c.y, tx, ty };
		} else if (pointers.size === 1) {
			axis = null;
			start = { ...start, x: e.clientX, y: e.clientY, t: performance.now(), tx, ty };
		}
	}

	function onPointerMove(e: PointerEvent) {
		if (!pointers.has(e.pointerId)) return;
		pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
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
			dy = my;
		}
	}

	function onPointerUp(e: PointerEvent) {
		if (!pointers.has(e.pointerId)) return;
		pointers.delete(e.pointerId);
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
			if (dy > 120 || dy / Math.max(1, elapsed) > 0.6) close();
			else animateTo(() => (dy = 0));
		} else if (!axis && elapsed < 300) {
			const now = performance.now();
			if (now - lastTap < 300) {
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
		axis = null;
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
		onwheel={onWheel}
	>
		{#each slides as s (s.id)}
			{@const a = app.byId.get(s.id)}
			{#if a}
				<div
					class="slide"
					class:current={s.o === 0}
					class:animating
					style="transform: translate({s.o * pitch + dx}px, {s.o === 0 ? Math.max(0, dy) : 0}px) scale({s.o === 0
						? 1 - dismissProgress * 0.3
						: 1})"
				>
					<div
						class="frame"
						style={s.o === 0 ? `transform: translate(${tx}px, ${ty}px) scale(${scale})` : ''}
						class:animating
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
								ready = new Set(ready).add(a.id);
								const img = e.currentTarget as HTMLImageElement;
								dims = new Map(dims).set(`${a.id}/${a.ev}`, { w: img.naturalWidth, h: img.naturalHeight });
							}}
						/>
						{#if s.o === 0 && fullRes}
							<img class="high" src={originalUrl(a.id)} alt="" draggable="false" />
						{/if}
					</div>
				</div>
			{/if}
		{/each}
	</div>

	<header class="bar top">
		<button class="icon-btn" onclick={close} aria-label="Close"><Icon name="back" /></button>
		<div class="title">
			{#if asset}
				<div class="date">{captureLabel(asset.t, asset.tz)}</div>
				<div class="sub muted">{index + 1} of {ids.length}</div>
			{/if}
		</div>
		<button class="icon-btn heart" class:filled={asset?.fav} onclick={toggleFavorite} disabled={!net.online}
			aria-label={asset?.fav ? 'Unfavourite' : 'Favourite'} aria-pressed={asset?.fav ?? false}><Icon name="heart" /></button>
		<button class="icon-btn" class:on={infoOpen} onclick={() => (infoOpen = !infoOpen)} aria-label="Info"
			><Icon name="info" /></button
		>
		{#if net.online}
			<button class="icon-btn" onclick={openEditor} disabled={!canEdit}
				title={canEdit ? 'Edit (E)' : "Editing needs WebGPU, which this browser doesn't offer"} aria-label="Edit"><Icon name="edit" /></button>
			<button class="icon-btn" onclick={() => (exporting = true)} title="Export / share" aria-label="Export"><Icon name="share" /></button>
		{/if}
	</header>

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
	{#if exporting && asset}
		<ExportSheet {asset} onClose={() => (exporting = false)} />
	{/if}

	{#if infoOpen && asset}
		<aside class="info">
			<button class="icon-btn info-close" onclick={() => (infoOpen = false)} aria-label="Close info" title="Close (Esc)"
				><Icon name="close" /></button>
			<h3>{asset.name}</h3>
			<dl>
				<dt>Taken</dt>
				<dd>
					{captureLabel(asset.t, asset.tz)}
					<span class="muted">{offsetLabel(asset.tz)}{detail ? ` · from ${detail.asset.dateSource}` : ''}</span>
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
				<dt>Size</dt>
				<dd>{asset.w} × {asset.h} <span class="muted">({((asset.w * asset.h) / 1e6).toFixed(1)} MP)</span></dd>
				{#if detail?.asset.lat != null && detail?.asset.lon != null}
					<dt>Location</dt>
					<dd>
						<a
							href="https://www.openstreetmap.org/?mlat={detail.asset.lat}&mlon={detail.asset.lon}#map=14/{detail.asset
								.lat}/{detail.asset.lon}"
							target="_blank"
							rel="noreferrer">{detail.asset.lat.toFixed(5)}, {detail.asset.lon.toFixed(5)}</a
						>
					</dd>
				{/if}
				{#if detail?.asset.description}
					<dt>Description</dt>
					<dd>{detail.asset.description}</dd>
				{/if}
				{#if detail}
					<dt>{detail.files.length > 1 ? 'Files' : 'File'}</dt>
					{#each detail.files as f (f)}
						<dd class="file">{f}</dd>
					{/each}
				{/if}
			</dl>
		</aside>
	{/if}
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
	.viewer:not(.chrome) .nav {
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
	.icon-btn.on {
		background: rgba(10, 132, 255, 0.15);
	}
	.nav {
		display: none;
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
		.viewer:hover .nav:not(:disabled) {
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
	}
	@media (min-width: 768px) {
		.info {
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
</style>
