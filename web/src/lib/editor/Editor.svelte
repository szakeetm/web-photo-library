<script lang="ts">
	// Photo editor. Desktop: Lightroom-style panels beside the image. Phone: Photos-style — the image,
	// a row of adjustment buttons with a ruler dial, and a Crop tab. Both render with the shared WebGPU
	// pipeline on the unedited 2048 px preview; Done sends the recipe to the server, which renders the
	// same recipe for the saved previews and full-resolution exports.
	import { onMount, untrack } from 'svelte';
	import { api, previewUrl, type CatalogAsset, type EditHistory } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { shortcut } from '#lib/platform.ts';
	import Icon from '#lib/components/Icon.svelte';
	import { EditRenderer } from './renderer';
	import { fetchGainMap } from './gainmap';
	import { EditorSession } from './session.svelte';
	import { ADJUSTMENTS, emptyRecipe, frameSize, isIdentity, type Adjustment, type AdjustmentInfo, type Recipe } from './recipe';
	import { ASPECTS, FULL, cropWithAspect, fitCrop, flipHorizontal, rotateClockwise, rotateCounterClockwise } from './geometry';
	import type { Point } from './curve';
	import Slider from './Slider.svelte';
	import Dial from './Dial.svelte';
	import CropOverlay from './CropOverlay.svelte';
	import CurveEditor from './CurveEditor.svelte';

	let { asset, onClose }: { asset: CatalogAsset; onClose: (saved: boolean) => void } = $props();

	const wideQuery = matchMedia('(min-width: 900px) and (pointer: fine)');
	let wide = $state(wideQuery.matches);

	let status = $state<'loading' | 'ready' | 'error'>('loading');
	let error = $state('');
	let renderer: EditRenderer | null = null;
	let gpuCtx: GPUCanvasContext | null = null;
	/** HDR photo: the canvas shows the HDR rendition (extended range); the saved edit keeps HDR too. */
	let hdr = false;
	let canvas = $state<HTMLCanvasElement>();
	let stage = $state<HTMLDivElement>();
	let stageW = $state(0);
	let stageH = $state(0);
	let srcW = $state(0);
	let srcH = $state(0);

	const session = new EditorSession();
	let history = $state<EditHistory | null>(null);
	let mode = $state<'adjust' | 'crop'>('adjust');
	let selected = $state<Adjustment>('exposure');
	let showOriginal = $state(false);
	let saving = $state(false);
	let autoBusy = $state(false);
	let aspect = $state<number | null>(null);
	let aspectLabel = $state('Freeform');
	let hist = $state<{ r: Float32Array; g: Float32Array; b: Float32Array; l: Float32Array } | null>(null);
	let open = $state<Record<string, boolean>>({ light: true, color: true, curve: false, effects: false, geometry: false, history: false });

	const recipe = $derived(session.recipe);
	/** What the canvas shows: crop mode shows the whole frame; "original" shows the unedited photo. */
	const shown = $derived<Recipe>(
		showOriginal ? emptyRecipe() : mode === 'crop' ? { ...recipe, crop: undefined } : recipe
	);
	const frame = $derived(srcW ? frameSize(recipe, srcW, srcH) : { w: 1, h: 1 });
	const outSize = $derived.by(() => {
		if (!srcW) return { w: 1, h: 1 };
		const f = frameSize(shown, srcW, srcH);
		const c = shown.crop ?? FULL;
		return { w: Math.max(1, Math.round(c.w * f.w)), h: Math.max(1, Math.round(c.h * f.h)) };
	});
	/** CSS size of the canvas: fitted into the stage. */
	const display = $derived.by(() => {
		const pad = wide ? 32 : mode === 'crop' ? 36 : 8;
		const s = Math.min((stageW - pad * 2) / outSize.w, (stageH - pad * 2) / outSize.h);
		return { w: Math.max(1, Math.floor(outSize.w * s)), h: Math.max(1, Math.floor(outSize.h * s)) };
	});

	// ---- loading -----------------------------------------------------------------------------

	onMount(() => {
		const onWide = () => (wide = wideQuery.matches);
		wideQuery.addEventListener('change', onWide);
		const ro = new ResizeObserver(() => {
			if (!stage) return;
			stageW = stage.clientWidth;
			stageH = stage.clientHeight;
		});
		if (stage) ro.observe(stage);
		window.addEventListener('keydown', onKey);
		window.addEventListener('keyup', onKeyUp);
		load();
		return () => {
			wideQuery.removeEventListener('change', onWide);
			ro.disconnect();
			window.removeEventListener('keydown', onKey);
			window.removeEventListener('keyup', onKeyUp);
			renderer?.destroy();
		};
	});

	async function load() {
		try {
			renderer = await EditRenderer.create();
			if (!renderer) {
				throw new Error(
					"Editing needs WebGPU, which this browser doesn't offer (or has turned off). Use a current Chrome, Edge or Safari, or Firefox on Windows or a Mac."
				);
			}
			const [h, blob, gainMap] = await Promise.all([
				api.edits(asset.id),
				fetch(previewUrl(asset.id, 0, app.fmt)).then((r) => {
					if (!r.ok) throw new Error(`Couldn't load the photo (${r.status}).`);
					return r.blob();
				}),
				fetchGainMap(asset.id)
			]);
			history = h;
			const bitmap = await createImageBitmap(blob);
			srcW = bitmap.width;
			srcH = bitmap.height;
			renderer.setSource(bitmap);
			bitmap.close();
			renderer.setGainMap(gainMap);
			hdr = gainMap != null;
			const current = h.versions.find((v) => v.version === h.current)?.recipe ?? emptyRecipe();
			session.reset(current);
			renderer.device.lost.then((info) => {
				if (info.reason !== 'destroyed') {
					status = 'error';
					error = 'The graphics device was lost. Close the editor and try again.';
				}
			});
			status = 'ready';
		} catch (e) {
			status = 'error';
			error = e instanceof Error ? e.message : String(e);
		}
	}

	// ---- rendering -----------------------------------------------------------------------------

	let frameRequested = false;
	$effect(() => {
		// track what the picture depends on
		void shown;
		void outSize;
		if (status !== 'ready' || !canvas) return;
		if (!gpuCtx) {
			gpuCtx = canvas.getContext('webgpu');
			if (!gpuCtx) {
				status = 'error';
				error = "This browser can't draw with WebGPU here.";
				return;
			}
			// An HDR photo draws extended-range values (brighter than SDR white) where the display allows.
			const config: GPUCanvasConfiguration = {
				device: renderer!.device,
				format: hdr ? 'rgba16float' : navigator.gpu.getPreferredCanvasFormat(),
				colorSpace: 'display-p3',
				toneMapping: { mode: hdr ? 'extended' : 'standard' },
				alphaMode: 'opaque'
			};
			try {
				gpuCtx.configure(config);
			} catch {
				// a browser without Display-P3 canvases: sRGB (colors outside sRGB are clipped on screen only)
				gpuCtx.configure({ ...config, colorSpace: 'srgb' });
			}
		}
		if (frameRequested) return;
		frameRequested = true;
		requestAnimationFrame(() => {
			frameRequested = false;
			draw();
		});
	});

	function draw() {
		if (!renderer || !gpuCtx || !canvas) return;
		if (canvas.width !== outSize.w || canvas.height !== outSize.h) {
			canvas.width = outSize.w;
			canvas.height = outSize.h;
		}
		renderer.render($state.snapshot(shown) as Recipe, gpuCtx.getCurrentTexture(), hdr);
	}

	// Histogram (desktop): a small render read back, throttled.
	let histTimer: ReturnType<typeof setTimeout> | undefined;
	let histBusy = false;
	$effect(() => {
		void recipe;
		if (!wide || status !== 'ready') return;
		clearTimeout(histTimer);
		histTimer = setTimeout(updateHistogram, 120);
	});

	async function updateHistogram() {
		if (!renderer || histBusy) return;
		histBusy = true;
		try {
			const r = $state.snapshot(recipe) as Recipe;
			const full = renderer.outputSize(r);
			const k = Math.min(1, 256 / Math.max(full.w, full.h));
			const w = Math.max(1, Math.round(full.w * k));
			const h = Math.max(1, Math.round(full.h * k));
			const tex = renderer.device.createTexture({
				size: [w, h],
				format: 'rgba8unorm',
				usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC
			});
			renderer.render(r, tex);
			const px = await renderer.readTexture(tex, w, h);
			tex.destroy();
			const bins = 64;
			const out = { r: new Float32Array(bins), g: new Float32Array(bins), b: new Float32Array(bins), l: new Float32Array(bins) };
			for (let i = 0; i < px.length; i += 4) {
				out.r[px[i] >> 2]++;
				out.g[px[i + 1] >> 2]++;
				out.b[px[i + 2] >> 2]++;
				out.l[Math.min(63, Math.round(px[i] * 0.2290 + px[i + 1] * 0.6917 + px[i + 2] * 0.0793) >> 2)]++;
			}
			hist = out;
		} catch {
			/* device busy or lost: try again on the next change */
		} finally {
			histBusy = false;
		}
	}

	const histPaths = $derived.by(() => {
		if (!hist) return null;
		const W = 256;
		const H = 72;
		let max = 1;
		for (const ch of [hist.r, hist.g, hist.b]) for (let i = 1; i < 63; i++) max = Math.max(max, ch[i]);
		const path = (ch: Float32Array) => {
			let d = `M0,${H}`;
			for (let i = 0; i < ch.length; i++) d += `L${((i / 63) * W).toFixed(1)},${(H - Math.min(1, ch[i] / max) * H).toFixed(1)}`;
			return d + `L${W},${H}Z`;
		};
		return { r: path(hist.r), g: path(hist.g), b: path(hist.b) };
	});

	// ---- editing -----------------------------------------------------------------------------

	const value = (key: Adjustment) => (recipe[key] as number | undefined) ?? 0;
	function setAdjustment(key: Adjustment, v: number) {
		session.preview({ ...recipe, [key]: Math.round(v * 1000) / 1000 });
	}
	const fmtValue = (a: AdjustmentInfo, v: number) =>
		a.key === 'exposure' ? `${v > 0 ? '+' : ''}${v.toFixed(2)}` : `${v > 0 ? '+' : ''}${Math.round(v * 100)}`;

	// straighten keeps the crop that existed when the gesture started, shrunk to fit
	let straightenBase: Recipe['crop'] | null = null;
	/** True while the straighten slider/dial is being moved: shows an alignment grid. */
	let straightening = $state(false);
	function setStraighten(v: number) {
		straightenBase ??= recipe.crop ?? FULL;
		straightening = true;
		const angle = Math.round(v * 10) / 10;
		session.preview({ ...recipe, straighten: angle, crop: fitCrop(straightenBase, angle, frame.w, frame.h) });
	}
	function commitStraighten() {
		straightenBase = null;
		straightening = false;
		session.commit();
	}

	// Desktop: dragging outside the crop box turns the picture (straighten), like Photos on the Mac.
	let spin: { cx: number; cy: number; a0: number; s0: number; moved: boolean } | null = null;
	const angleAt = (e: PointerEvent) => (Math.atan2(e.clientY - spin!.cy, e.clientX - spin!.cx) * 180) / Math.PI;
	function spinStart(e: PointerEvent) {
		if (mode !== 'crop' || !wide || e.button !== 0 || !canvas) return false;
		if ((e.target as HTMLElement).closest('.box, button, input')) return false;
		const r = canvas.getBoundingClientRect();
		spin = { cx: r.left + r.width / 2, cy: r.top + r.height / 2, a0: 0, s0: recipe.straighten ?? 0, moved: false };
		spin.a0 = angleAt(e);
		straightening = true; // the alignment grid shows from the press on
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		e.preventDefault();
		return true;
	}
	function spinMove(e: PointerEvent) {
		if (!spin) return;
		let d = angleAt(e) - spin.a0;
		if (d > 180) d -= 360;
		if (d < -180) d += 360;
		spin.moved = true;
		setStraighten(Math.max(-45, Math.min(45, spin.s0 + d)));
	}
	function spinEnd() {
		if (!spin) return;
		const moved = spin.moved;
		spin = null;
		if (moved) commitStraighten();
		else straightening = false;
	}

	function chooseAspect(label: string) {
		const a = ASPECTS.find((x) => x.label === label);
		if (!a) return;
		aspectLabel = a.label;
		aspect = a.value === 'original' ? frame.w / frame.h : a.value;
		if (aspect != null) session.set({ ...recipe, crop: cropWithAspect(recipe, aspect, srcW, srcH) });
	}

	function rotate(clockwise = true) {
		session.set(clockwise ? rotateClockwise(recipe) : rotateCounterClockwise(recipe));
		if (aspect != null) aspect = 1 / aspect;
	}

	function resetGeometry() {
		session.set({ ...recipe, crop: undefined, straighten: undefined, rotate: undefined, flipH: undefined, flipV: undefined });
		aspect = null;
		aspectLabel = 'Freeform';
	}

	async function auto() {
		if (autoBusy) return;
		autoBusy = true;
		try {
			const { recipe: a } = await api.autoEnhance(asset.id);
			const light: (keyof Recipe)[] = ['exposure', 'brilliance', 'highlights', 'shadows', 'brightness', 'contrast', 'blackPoint', 'saturation', 'vibrance', 'warmth', 'tint', 'curve'];
			const next: Recipe = { ...recipe };
			for (const k of light) delete next[k];
			session.set({ ...next, ...a, schema: recipe.schema, crop: recipe.crop, straighten: recipe.straighten, rotate: recipe.rotate, flipH: recipe.flipH, flipV: recipe.flipV });
		} catch (e) {
			alert((e as Error).message);
		} finally {
			autoBusy = false;
		}
	}

	async function done() {
		if (!session.dirty) return onClose(false);
		saving = true;
		try {
			const result = session.result();
			const { asset: updated } = isIdentity(result) ? await api.revertEdit(asset.id) : await api.saveEdit(asset.id, result);
			app.patchAsset(updated);
			app.reload();
			onClose(true);
		} catch (e) {
			saving = false;
			alert(`Couldn't save the edit: ${(e as Error).message}`);
		}
	}

	function cancel() {
		if (session.dirty && !confirm('Discard your changes?')) return;
		onClose(false);
	}

	function revertToOriginal() {
		session.set(emptyRecipe());
		aspect = null;
		aspectLabel = 'Freeform';
	}

	// ---- input -----------------------------------------------------------------------------

	function onKey(e: KeyboardEvent) {
		const target = e.target as HTMLElement;
		if (target.closest('input, select, textarea')) return;
		const mod = e.metaKey || e.ctrlKey;
		if (mod && e.key.toLowerCase() === 'z') {
			e.preventDefault();
			if (e.shiftKey) session.redo();
			else session.undo();
		} else if (e.ctrlKey && !e.metaKey && e.key.toLowerCase() === 'y') {
			// Windows and Linux redo
			e.preventDefault();
			session.redo();
		} else if (e.key === 'Escape') {
			e.preventDefault();
			if (mode === 'crop') mode = 'adjust';
			else cancel();
		} else if (e.key === 'Enter' && mode === 'crop') {
			mode = 'adjust';
		} else if (mod && (e.key === '[' || e.key === ']')) {
			e.preventDefault();
			rotate(e.key === ']');
		} else if (e.key === '\\') {
			showOriginal = true;
		} else if (e.key === 'c' && !mod) {
			mode = mode === 'crop' ? 'adjust' : 'crop';
		}
		e.stopPropagation();
	}
	function onKeyUp(e: KeyboardEvent) {
		if (e.key === '\\') showOriginal = false;
	}

	// press and hold the photo (phone) to see the original
	let holdTimer: ReturnType<typeof setTimeout> | undefined;
	function holdStart(e: PointerEvent) {
		if (mode === 'crop' || (e.target as HTMLElement).closest('.overlay')) return;
		holdTimer = setTimeout(() => (showOriginal = true), 180);
	}
	function holdEnd() {
		clearTimeout(holdTimer);
		showOriginal = false;
	}

	// ---- zoom: pinch (phone), double-tap or double-click; one finger moves a zoomed photo. Not while
	// cropping (the crop box has its own drags). The canvas has the preview's pixels, so up to 5× stays sharp.
	const MAX_ZOOM = 5;
	let zoom = $state(1);
	let pan = $state({ x: 0, y: 0 });
	const pointers = new Map<number, { x: number; y: number }>();
	let pinch: { d: number; z: number; ux: number; uy: number } | null = null;
	let drag: { x: number; y: number; px: number; py: number } | null = null;
	/** The finger down now, while it may still be a tap (short, not moved, alone). */
	let tap: { id: number; x: number; y: number; t: number } | null = null;
	/** The last tap, for double-taps. */
	let lastTap: { x: number; y: number; t: number } | null = null;
	const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
	/** The stage's centre: the unzoomed photo's centre (it is centred in the stage). */
	function centre() {
		const r = stage!.getBoundingClientRect();
		return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
	}
	function setZoom(z: number, x: number, y: number) {
		zoom = clamp(z, 1, MAX_ZOOM);
		const mx = (display.w * (zoom - 1)) / 2;
		const my = (display.h * (zoom - 1)) / 2;
		pan = zoom === 1 ? { x: 0, y: 0 } : { x: clamp(x, -mx, mx), y: clamp(y, -my, my) };
	}
	/** Zooms to `z` keeping the photo point under the screen point (px, py) where it is. */
	function zoomAround(z: number, px: number, py: number) {
		const c = centre();
		const ux = (px - c.x - pan.x) / zoom;
		const uy = (py - c.y - pan.y) / zoom;
		const nz = clamp(z, 1, MAX_ZOOM);
		setZoom(nz, px - c.x - ux * nz, py - c.y - uy * nz);
	}
	// cropping, rotating or a new size: back to the whole photo
	$effect(() => {
		void display.w;
		void display.h;
		void mode;
		untrack(() => setZoom(1, 0, 0));
	});
	const twoPoints = () => [...pointers.values()].slice(0, 2);
	function zoomDown(e: PointerEvent): boolean {
		if (mode === 'crop' || status !== 'ready' || !stage) return false;
		if ((e.target as HTMLElement).closest('button, input, .overlay')) return false;
		pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
		if (pointers.size === 2) {
			holdEnd();
			tap = null; // a pinch, not a tap
			const [a, b] = twoPoints();
			const c = centre();
			const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
			pinch = { d: Math.hypot(a.x - b.x, a.y - b.y) || 1, z: zoom, ux: (mx - c.x - pan.x) / zoom, uy: (my - c.y - pan.y) / zoom };
			drag = null;
			return true;
		}
		if (pointers.size !== 1) return true;
		tap = { id: e.pointerId, x: e.clientX, y: e.clientY, t: Date.now() };
		if (zoom > 1) {
			// zoomed: one finger moves the photo (no hold-to-compare)
			drag = { x: e.clientX, y: e.clientY, px: pan.x, py: pan.y };
			return true;
		}
		return false;
	}
	function zoomMove(e: PointerEvent): boolean {
		if (!pointers.has(e.pointerId)) return false;
		pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
		if (tap?.id === e.pointerId && Math.hypot(e.clientX - tap.x, e.clientY - tap.y) > 10) tap = null;
		if (pinch && pointers.size >= 2) {
			const [a, b] = twoPoints();
			const c = centre();
			const z = clamp(pinch.z * (Math.hypot(a.x - b.x, a.y - b.y) / pinch.d), 1, MAX_ZOOM);
			const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
			setZoom(z, mx - c.x - pinch.ux * z, my - c.y - pinch.uy * z);
			return true;
		}
		if (drag) {
			setZoom(zoom, drag.px + e.clientX - drag.x, drag.py + e.clientY - drag.y);
			return true;
		}
		return false;
	}
	function zoomUp(e: PointerEvent) {
		if (!pointers.has(e.pointerId)) return;
		pointers.delete(e.pointerId);
		const now = Date.now();
		if (tap?.id === e.pointerId && now - tap.t < 250) {
			// a second tap close to the first, soon after it: zoom in there, or back to the whole photo
			if (lastTap && now - lastTap.t < 350 && Math.hypot(tap.x - lastTap.x, tap.y - lastTap.y) < 30) {
				lastTap = null;
				holdEnd();
				if (zoom > 1) setZoom(1, 0, 0);
				else zoomAround(2.5, tap.x, tap.y);
			} else lastTap = { x: tap.x, y: tap.y, t: now };
		}
		tap = null;
		if (pointers.size < 2) pinch = null;
		if (pointers.size === 1 && zoom > 1) {
			// one finger left after a pinch: it carries on moving the photo
			const [p] = [...pointers.values()];
			drag = { x: p.x, y: p.y, px: pan.x, py: pan.y };
		} else if (pointers.size === 0) drag = null;
	}

	const selectedInfo = $derived(ADJUSTMENTS.find((a) => a.key === selected)!);
	const groups = [
		{ id: 'light', title: 'Light' },
		{ id: 'color', title: 'Color' },
		{ id: 'effects', title: 'Effects' }
	] as const;
	const when = (s: string) => new Date(s).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
	/** Ring fill for the phone's adjustment buttons. */
	const ring = (a: AdjustmentInfo) => {
		const v = value(a.key);
		return Math.min(1, Math.abs(v) / Math.max(Math.abs(a.min), a.max));
	};
</script>

<div class="editor" class:wide class:narrow={!wide} role="dialog" aria-modal="true" aria-label="Edit photo">
	{#if wide}
		<header class="toolbar">
			<button class="tb" onclick={cancel}>Cancel</button>
			<div class="spacer"></div>
			<button class="tb icon" onclick={() => session.undo()} disabled={!session.canUndo} title="Undo ({shortcut('Z')})" aria-label="Undo"><Icon name="undo" size={18} /></button>
			<button class="tb icon" onclick={() => session.redo()} disabled={!session.canRedo} title="Redo ({shortcut('Z', true)})" aria-label="Redo"><Icon name="redo" size={18} /></button>
			<button
				class="tb icon"
				title="Hold to compare with the original (\)"
				aria-label="Compare with original"
				onpointerdown={() => (showOriginal = true)}
				onpointerup={() => (showOriginal = false)}
				onpointerleave={() => (showOriginal = false)}><Icon name="compare" size={18} /></button
			>
			<!-- the rotate icon points counter-clockwise; mirrored it points clockwise -->
			<button class="tb icon" onclick={() => rotate(false)} title="Rotate left ({shortcut('[')})" aria-label="Rotate left"><Icon name="rotate" size={18} /></button>
			<button class="tb icon" onclick={() => rotate(true)} title="Rotate right ({shortcut(']')})" aria-label="Rotate right"
				><span class="mirror"><Icon name="rotate" size={18} /></span></button
			>
			<button class="tb" class:active={mode === 'crop'} onclick={() => (mode = mode === 'crop' ? 'adjust' : 'crop')} title="Crop & straighten (C)">
				<Icon name="crop" size={16} /> Crop
			</button>
			<button class="tb" onclick={revertToOriginal} disabled={isIdentity(recipe)}>Revert to Original</button>
			<div class="spacer"></div>
			<button class="tb primary" onclick={done} disabled={saving || status !== 'ready'}>{saving ? 'Saving…' : 'Done'}</button>
		</header>
	{:else}
		<header class="topbar">
			<button class="tb" onclick={cancel}>Cancel</button>
			<div class="mid">
				<button class="tb icon" onclick={() => session.undo()} disabled={!session.canUndo} aria-label="Undo"><Icon name="undo" size={20} /></button>
				<button class="tb icon" onclick={() => session.redo()} disabled={!session.canRedo} aria-label="Redo"><Icon name="redo" size={20} /></button>
				{#if !isIdentity(recipe)}
					<button class="tb revert" onclick={revertToOriginal} title="Revert to Original">Revert</button>
				{/if}
			</div>
			<button class="tb done" onclick={done} disabled={saving || status !== 'ready'}>{saving ? 'Saving…' : 'Done'}</button>
		</header>
	{/if}

	<div class="body">
		<div
			class="stage"
			bind:this={stage}
			role="presentation"
			class:spinnable={mode === 'crop' && wide}
			onpointerdown={(e) => zoomDown(e) || spinStart(e) || holdStart(e)}
			onpointermove={(e) => zoomMove(e) || spinMove(e)}
			onpointerup={(e) => (zoomUp(e), spinEnd(), holdEnd())}
			onpointercancel={(e) => (zoomUp(e), spinEnd(), holdEnd())}
			onpointerleave={holdEnd}
		>
			{#if status === 'loading'}
				<div class="msg">Loading…</div>
			{:else if status === 'error'}
				<div class="msg error">
					<p>{error}</p>
					<button class="tb" onclick={() => onClose(false)}>Close</button>
				</div>
			{/if}
			<div class="canvaswrap" style="width: {display.w}px; height: {display.h}px; transform: translate({pan.x}px, {pan.y}px) scale({zoom})"
				hidden={status !== 'ready'}>
				<canvas bind:this={canvas} style="width: {display.w}px; height: {display.h}px"></canvas>
				{#if mode === 'crop' && !showOriginal && status === 'ready'}
					<CropOverlay
						crop={recipe.crop ?? FULL}
						width={display.w}
						height={display.h}
						frameW={frame.w}
						frameH={frame.h}
						angle={recipe.straighten ?? 0}
						{aspect}
						{straightening}
						onchange={(c) => session.preview({ ...recipe, crop: c })}
						oncommit={() => session.commit()}
					/>
				{:else if straightening && !showOriginal && status === 'ready'}
					<div class="straightgrid" aria-hidden="true"></div>
				{/if}
			</div>
			{#if showOriginal}<div class="badge">Original</div>{/if}
		</div>

		{#if wide}
			<aside class="panel">
				<div class="histogram" aria-label="Histogram">
					{#if histPaths}
						<svg viewBox="0 0 256 72" preserveAspectRatio="none">
							<path d={histPaths.r} fill="rgba(255,69,58,0.55)" />
							<path d={histPaths.g} fill="rgba(48,209,88,0.55)" />
							<path d={histPaths.b} fill="rgba(10,132,255,0.55)" />
						</svg>
					{/if}
				</div>
				<button class="auto" onclick={auto} disabled={autoBusy || status !== 'ready'}><Icon name="wand" size={16} /> {autoBusy ? 'Analysing…' : 'Auto'}</button>

				{#each groups as g (g.id)}
					<section>
						<button class="sect" onclick={() => (open[g.id] = !open[g.id])} aria-expanded={open[g.id]}>
							<span class="chev" class:open={open[g.id]}>›</span>{g.title}
						</button>
						{#if open[g.id]}
							<div class="sliders">
								{#each ADJUSTMENTS.filter((a) => a.group === g.id) as a (a.key)}
									<Slider
										label={a.label}
										value={value(a.key)}
										min={a.min}
										max={a.max}
										format={(v) => fmtValue(a, v)}
										oninput={(v) => setAdjustment(a.key, v)}
										oncommit={() => session.commit()}
									/>
								{/each}
							</div>
						{/if}
					</section>
					{#if g.id === 'color'}
						<section>
							<button class="sect" onclick={() => (open.curve = !open.curve)} aria-expanded={open.curve}>
								<span class="chev" class:open={open.curve}>›</span>Tone Curve
								{#if recipe.curve}<span class="reset" role="button" tabindex="0"
										onclick={(e) => { e.stopPropagation(); session.set({ ...recipe, curve: undefined }); }}
										onkeydown={(e) => e.key === 'Enter' && session.set({ ...recipe, curve: undefined })}>Reset</span>{/if}
							</button>
							{#if open.curve}
								<div class="curvebox">
									<CurveEditor
										points={recipe.curve as Point[] | undefined}
										histogram={hist?.l ?? null}
										onchange={(p) => session.preview({ ...recipe, curve: p })}
										oncommit={() => session.commit()}
									/>
									<p class="hint">Click to add a point · drag off or double-click to remove</p>
								</div>
							{/if}
						</section>
					{/if}
				{/each}

				<section>
					<button class="sect" onclick={() => (open.geometry = !open.geometry)} aria-expanded={open.geometry}>
						<span class="chev" class:open={open.geometry}>›</span>Crop & Straighten
					</button>
					{#if open.geometry}
						<div class="sliders">
							<div class="row">
								<button class="tb small" class:active={mode === 'crop'} onclick={() => (mode = mode === 'crop' ? 'adjust' : 'crop')}>
									{mode === 'crop' ? 'Done Cropping' : 'Show Crop'}
								</button>
								<select class="select" value={aspectLabel} onchange={(e) => chooseAspect((e.target as HTMLSelectElement).value)} aria-label="Aspect ratio">
									{#each ASPECTS as a (a.label)}<option>{a.label}</option>{/each}
								</select>
							</div>
							<Slider
								label="Straighten"
								value={recipe.straighten ?? 0}
								min={-45}
								max={45}
								step={0.1}
								format={(v) => `${v.toFixed(1)}°`}
								oninput={setStraighten}
								oncommit={commitStraighten}
							/>
							<div class="row">
								<button class="tb small" onclick={() => rotate(false)}><Icon name="rotate" size={16} /> Left</button>
								<button class="tb small" onclick={() => rotate(true)}><span class="mirror"><Icon name="rotate" size={16} /></span> Right</button>
								<button class="tb small" onclick={() => session.set(flipHorizontal(recipe))}><Icon name="flip" size={16} /> Flip</button>
								<button class="tb small" onclick={resetGeometry}>Reset</button>
							</div>
						</div>
					{/if}
				</section>

				{#if history && history.versions.length}
					<section>
						<button class="sect" onclick={() => (open.history = !open.history)} aria-expanded={open.history}>
							<span class="chev" class:open={open.history}>›</span>History
						</button>
						{#if open.history}
							<ul class="versions">
								{#each [...history.versions].reverse() as v (v.version)}
									<li>
										<button onclick={() => session.set(v.recipe)}>
											Version {v.version}
											<span>{when(v.createdAt)}{v.version === history.current ? ' · current' : ''}</span>
										</button>
									</li>
								{/each}
								<li><button onclick={revertToOriginal}>Original</button></li>
							</ul>
						{/if}
					</section>
				{/if}
			</aside>
		{:else}
			<div class="tools">
				{#if mode === 'adjust'}
					<Dial
						label={selectedInfo.label}
						value={value(selected)}
						min={selectedInfo.min}
						max={selectedInfo.max}
						format={(v) => fmtValue(selectedInfo, v)}
						oninput={(v) => setAdjustment(selected, v)}
						oncommit={() => session.commit()}
					/>
					<div class="chips" role="listbox" aria-label="Adjustments">
						<button class="chip" class:busy={autoBusy} onclick={auto} aria-label="Auto">
							<span class="ring"><Icon name="wand" size={20} /></span>
							<span class="cap">Auto</span>
						</button>
						{#each ADJUSTMENTS as a (a.key)}
							<button
								class="chip"
								class:sel={selected === a.key}
								role="option"
								aria-selected={selected === a.key}
								onclick={() => (selected = a.key)}
								aria-label={a.label}
							>
								<span class="ring" style="--p: {ring(a)}">
									<svg viewBox="0 0 48 48" class="arc" aria-hidden="true"><circle cx="24" cy="24" r="22" pathLength="1" /></svg>
									<Icon name={a.icon} size={20} />
								</span>
								<span class="cap">{a.label}</span>
							</button>
						{/each}
					</div>
				{:else}
					<Dial
						label="Straighten"
						value={recipe.straighten ?? 0}
						min={-45}
						max={45}
						format={(v) => `${v.toFixed(1)}°`}
						oninput={setStraighten}
						oncommit={commitStraighten}
					/>
					<div class="croptools">
						<button class="tb icon" onclick={() => rotate(false)} aria-label="Rotate left"><Icon name="rotate" /></button>
						<button class="tb icon" onclick={() => session.set(flipHorizontal(recipe))} aria-label="Flip"><Icon name="flip" /></button>
						<select class="select" value={aspectLabel} onchange={(e) => chooseAspect((e.target as HTMLSelectElement).value)} aria-label="Aspect ratio">
							{#each ASPECTS as a (a.label)}<option>{a.label}</option>{/each}
						</select>
						<button class="tb" onclick={resetGeometry}>Reset</button>
					</div>
				{/if}
				<nav class="tabs">
					<button class:active={mode === 'adjust'} onclick={() => (mode = 'adjust')}><Icon name="edit" size={20} /><span>Adjust</span></button>
					<button class:active={mode === 'crop'} onclick={() => (mode = 'crop')}><Icon name="crop" size={20} /><span>Crop</span></button>
				</nav>
			</div>
		{/if}
	</div>

	{#if saving}
		<div class="saving" role="status">Saving…</div>
	{/if}
</div>

<style>
	.editor {
		position: fixed;
		inset: 0;
		z-index: 200;
		background: #000;
		color: #f2f2f7;
		display: flex;
		flex-direction: column;
		user-select: none;
		-webkit-user-select: none;
		font-size: 14px;
	}
	.body {
		flex: 1;
		min-height: 0;
		display: flex;
	}
	.stage {
		flex: 1;
		min-width: 0;
		min-height: 0;
		position: relative;
		display: flex;
		align-items: center;
		justify-content: center;
		overflow: hidden;
		touch-action: none;
	}
	/* outside the crop box: drag to straighten */
	.stage.spinnable {
		cursor: grab;
	}
	.stage.spinnable:active {
		cursor: grabbing;
	}
	.canvaswrap {
		position: relative;
		flex: none;
	}
	canvas {
		display: block;
	}
	/* alignment grid over the whole picture while straightening outside crop mode */
	.straightgrid {
		position: absolute;
		inset: 0;
		pointer-events: none;
		outline: 1px solid rgba(255, 255, 255, 0.6);
		background-image:
			linear-gradient(90deg, rgba(255, 255, 255, 0.35) 1px, transparent 1px),
			linear-gradient(180deg, rgba(255, 255, 255, 0.35) 1px, transparent 1px);
		background-size: calc(100% / 8) calc(100% / 8);
		background-position: -0.5px -0.5px;
	}
	.msg {
		position: absolute;
		inset: 0;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 12px;
		color: #8e8e93;
		padding: 24px;
		text-align: center;
		max-width: 520px;
		margin: auto;
	}
	.badge {
		position: absolute;
		top: 12px;
		left: 50%;
		transform: translateX(-50%);
		background: rgba(0, 0, 0, 0.6);
		border-radius: 6px;
		padding: 3px 10px;
		font-size: 12px;
		letter-spacing: 0.05em;
		text-transform: uppercase;
	}
	.tb {
		border: none;
		background: none;
		color: #f2f2f7;
		font: inherit;
		padding: 6px 10px;
		border-radius: 7px;
		cursor: pointer;
		display: inline-flex;
		align-items: center;
		gap: 6px;
	}
	.tb:disabled {
		opacity: 0.35;
		cursor: default;
	}
	.tb.icon {
		padding: 6px;
	}
	.mirror {
		display: inline-flex;
		transform: scaleX(-1);
	}
	.tb.active {
		color: #ffd60a;
	}
	.saving {
		position: absolute;
		inset: 0;
		display: flex;
		align-items: center;
		justify-content: center;
		background: rgba(0, 0, 0, 0.5);
		font-size: 16px;
	}
	.select {
		font: inherit;
		color: #f2f2f7;
		background: #2c2c2e;
		border: none;
		border-radius: 7px;
		padding: 6px 8px;
	}

	/* ---- desktop ---- */
	.toolbar {
		display: flex;
		align-items: center;
		gap: 4px;
		padding: 8px 12px;
		background: #1c1c1e;
		border-bottom: 0.5px solid #38383a;
	}
	.toolbar .spacer {
		flex: 1;
	}
	.toolbar .tb:hover:not(:disabled) {
		background: #2c2c2e;
	}
	.toolbar .primary {
		background: #ffd60a;
		color: #000;
		font-weight: 600;
		padding: 6px 16px;
	}
	.toolbar .primary:hover:not(:disabled) {
		background: #ffe03a;
	}
	.panel {
		width: 300px;
		flex: none;
		overflow-y: auto;
		background: #1c1c1e;
		border-left: 0.5px solid #38383a;
		padding: 12px 14px 24px;
	}
	.histogram {
		height: 72px;
		background: #000;
		border-radius: 6px;
		overflow: hidden;
	}
	.histogram svg {
		width: 100%;
		height: 100%;
		display: block;
		mix-blend-mode: screen;
	}
	.auto {
		margin: 10px 0 6px;
		width: 100%;
		border: none;
		border-radius: 7px;
		background: #2c2c2e;
		color: #f2f2f7;
		padding: 7px;
		font: inherit;
		cursor: pointer;
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 6px;
	}
	.auto:hover:not(:disabled) {
		background: #3a3a3c;
	}
	section {
		border-top: 0.5px solid #38383a;
		padding: 2px 0 6px;
	}
	.sect {
		width: 100%;
		border: none;
		background: none;
		color: #f2f2f7;
		font: inherit;
		font-weight: 600;
		font-size: 13px;
		text-align: left;
		padding: 9px 0 6px;
		cursor: pointer;
		display: flex;
		align-items: center;
		gap: 6px;
	}
	.chev {
		display: inline-block;
		width: 10px;
		transition: transform 0.15s;
		color: #8e8e93;
	}
	.chev.open {
		transform: rotate(90deg);
	}
	.sect .reset {
		margin-left: auto;
		font-weight: 400;
		color: #0a84ff;
		font-size: 12px;
	}
	.row {
		display: flex;
		gap: 6px;
		align-items: center;
		margin: 6px 0;
	}
	.tb.small {
		background: #2c2c2e;
		font-size: 13px;
	}
	.curvebox .hint {
		color: #8e8e93;
		font-size: 11px;
		margin: 6px 0 0;
	}
	.versions {
		list-style: none;
		padding: 0;
		margin: 0;
	}
	.versions button {
		width: 100%;
		text-align: left;
		background: none;
		border: none;
		color: #f2f2f7;
		font: inherit;
		padding: 6px 4px;
		border-radius: 6px;
		cursor: pointer;
		display: flex;
		justify-content: space-between;
		gap: 8px;
	}
	.versions button:hover {
		background: #2c2c2e;
	}
	.versions span {
		color: #8e8e93;
		font-size: 12px;
	}

	/* ---- phone ---- */
	.narrow .body {
		flex-direction: column;
	}
	.topbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: calc(6px + env(safe-area-inset-top)) 8px 6px;
	}
	.topbar .mid {
		display: flex;
		gap: 4px;
	}
	.topbar .revert {
		color: #ff453a;
	}
	.topbar .done {
		color: #ffd60a;
		font-weight: 600;
	}
	.tools {
		flex: none;
		padding: 8px 0 env(safe-area-inset-bottom);
		background: #000;
	}
	.chips {
		display: flex;
		gap: 14px;
		overflow-x: auto;
		padding: 12px 16px 6px;
		scrollbar-width: none;
		scroll-snap-type: x proximity;
	}
	.chips::-webkit-scrollbar {
		display: none;
	}
	.chip {
		flex: none;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 5px;
		background: none;
		border: none;
		color: #8e8e93;
		padding: 0;
		scroll-snap-align: center;
		cursor: pointer;
	}
	.chip .cap {
		font-size: 10px;
		max-width: 64px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.ring {
		position: relative;
		width: 48px;
		height: 48px;
		border-radius: 50%;
		background: #1c1c1e;
		display: flex;
		align-items: center;
		justify-content: center;
		color: #f2f2f7;
	}
	.arc {
		position: absolute;
		inset: 0;
		width: 48px;
		height: 48px;
		transform: rotate(-90deg);
	}
	.arc circle {
		fill: none;
		stroke: #ffd60a;
		stroke-width: 2.5;
		stroke-dasharray: var(--p) 1;
	}
	.chip.sel {
		color: #ffd60a;
	}
	.chip.sel .ring {
		box-shadow: inset 0 0 0 1.5px #f2f2f7;
	}
	.chip.busy .ring {
		opacity: 0.5;
	}
	.croptools {
		display: flex;
		justify-content: center;
		align-items: center;
		gap: 14px;
		padding: 12px 16px 6px;
	}
	.tabs {
		display: flex;
		justify-content: center;
		gap: 40px;
		padding: 8px 0 6px;
	}
	.tabs button {
		background: none;
		border: none;
		color: #8e8e93;
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 2px;
		font-size: 10px;
		cursor: pointer;
	}
	.tabs button.active {
		color: #ffd60a;
	}
</style>
