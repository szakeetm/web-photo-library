<script lang="ts">
	// Crop rectangle over the full (straightened) frame: drag inside to move, corners/edges to resize.
	// The crop never leaves the image; with an aspect ratio set, corners keep it.
	import type { Crop } from './recipe';
	import { constrainCrop } from './geometry';

	let {
		crop,
		width,
		height,
		frameW,
		frameH,
		angle,
		aspect,
		straightening = false,
		onchange,
		oncommit
	}: {
		crop: Crop;
		/** Displayed size of the frame in CSS px. */
		width: number;
		height: number;
		/** Frame size in image pixels (for aspect maths and the edge constraint). */
		frameW: number;
		frameH: number;
		angle: number;
		/** Locked pixel aspect (w/h) or null for freeform. */
		aspect: number | null;
		/** Straighten slider/dial in use: show the dense alignment grid instead of thirds. */
		straightening?: boolean;
		onchange: (c: Crop) => void;
		oncommit: () => void;
	} = $props();

	type Mode = 'move' | 'n' | 's' | 'e' | 'w' | 'ne' | 'nw' | 'se' | 'sw';
	let drag: { mode: Mode; x: number; y: number; start: Crop } | null = $state(null);
	const MIN = 0.04;

	function down(e: PointerEvent, mode: Mode) {
		e.stopPropagation();
		e.preventDefault();
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		drag = { mode, x: e.clientX, y: e.clientY, start: crop };
	}

	function move(e: PointerEvent) {
		if (!drag) return;
		const dx = (e.clientX - drag.x) / width;
		const dy = (e.clientY - drag.y) / height;
		const s = drag.start;
		let { x, y, w, h } = s;
		const m = drag.mode;
		if (m === 'move') {
			x = Math.min(1 - w, Math.max(0, x + dx));
			y = Math.min(1 - h, Math.max(0, y + dy));
		} else {
			if (m.includes('w')) {
				const nx = Math.min(x + w - MIN, Math.max(0, x + dx));
				w += x - nx;
				x = nx;
			}
			if (m.includes('e')) w = Math.min(1 - x, Math.max(MIN, w + dx));
			if (m.includes('n')) {
				const ny = Math.min(y + h - MIN, Math.max(0, y + dy));
				h += y - ny;
				y = ny;
			}
			if (m.includes('s')) h = Math.min(1 - y, Math.max(MIN, h + dy));
			if (aspect != null) {
				// keep the pixel aspect: derive the dependent side from the dragged one
				const normAspect = (aspect * frameH) / frameW; // w/h in normalised units
				if (m === 'n' || m === 's') {
					const nw = h * normAspect;
					x += (w - nw) / 2;
					w = nw;
				} else {
					const nh = w / normAspect;
					if (m.includes('n')) y += h - nh;
					else if (!m.includes('s')) y += (h - nh) / 2;
					h = nh;
				}
				if (x < 0 || y < 0 || x + w > 1 + 1e-9 || y + h > 1 + 1e-9) return; // would leave the frame
			}
		}
		onchange(constrainCrop(s, { x, y, w, h }, angle, frameW, frameH));
	}

	function up() {
		if (drag) oncommit();
		drag = null;
	}

	const px = $derived({ x: crop.x * width, y: crop.y * height, w: crop.w * width, h: crop.h * height });
	const handles: Mode[] = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];
</script>

<div class="overlay" style="width: {width}px; height: {height}px">
	<div class="dim" style="left: 0; top: 0; width: {width}px; height: {px.y}px"></div>
	<div class="dim" style="left: 0; top: {px.y + px.h}px; width: {width}px; height: {Math.max(0, height - px.y - px.h)}px"></div>
	<div class="dim" style="left: 0; top: {px.y}px; width: {px.x}px; height: {px.h}px"></div>
	<div class="dim" style="left: {px.x + px.w}px; top: {px.y}px; width: {Math.max(0, width - px.x - px.w)}px; height: {px.h}px"></div>
	<div
		class="box"
		class:dragging={!!drag}
		style="left: {px.x}px; top: {px.y}px; width: {px.w}px; height: {px.h}px"
		role="application"
		aria-label="Crop area"
		onpointerdown={(e) => down(e, 'move')}
		onpointermove={move}
		onpointerup={up}
		onpointercancel={up}
	>
		<div class="grid" class:hidden={straightening}></div>
		<div class="fine" class:show={straightening}></div>
		{#each handles as h (h)}
			<div
				class="handle {h}"
				role="presentation"
				onpointerdown={(e) => down(e, h)}
				onpointermove={move}
				onpointerup={up}
				onpointercancel={up}
			></div>
		{/each}
	</div>
</div>

<style>
	.overlay {
		position: absolute;
		left: 0;
		top: 0;
		overflow: hidden;
		touch-action: none;
	}
	.dim {
		position: absolute;
		background: rgba(0, 0, 0, 0.55);
		pointer-events: none;
	}
	.box {
		position: absolute;
		cursor: move;
		touch-action: none;
	}
	/* drawn inside the box: a crop of the whole photo (box on the overlay's clipped edges) keeps it */
	.box::before {
		content: '';
		position: absolute;
		inset: 0;
		border: 1.5px solid rgba(255, 255, 255, 0.95);
		box-shadow: 0 0 2px rgba(0, 0, 0, 0.35);
		pointer-events: none;
	}
	.grid {
		position: absolute;
		inset: 0;
		opacity: 0;
		transition: opacity 0.15s;
		background:
			linear-gradient(90deg, transparent calc(33.33% - 0.5px), rgba(255, 255, 255, 0.5) calc(33.33% - 0.5px), rgba(255, 255, 255, 0.5) calc(33.33% + 0.5px), transparent calc(33.33% + 0.5px), transparent calc(66.66% - 0.5px), rgba(255, 255, 255, 0.5) calc(66.66% - 0.5px), rgba(255, 255, 255, 0.5) calc(66.66% + 0.5px), transparent calc(66.66% + 0.5px)),
			linear-gradient(180deg, transparent calc(33.33% - 0.5px), rgba(255, 255, 255, 0.5) calc(33.33% - 0.5px), rgba(255, 255, 255, 0.5) calc(33.33% + 0.5px), transparent calc(33.33% + 0.5px), transparent calc(66.66% - 0.5px), rgba(255, 255, 255, 0.5) calc(66.66% - 0.5px), rgba(255, 255, 255, 0.5) calc(66.66% + 0.5px), transparent calc(66.66% + 0.5px));
		pointer-events: none;
	}
	.box.dragging .grid:not(.hidden) {
		opacity: 1;
	}
	/* dense grid for lining up horizons/verticals while straightening */
	.fine {
		position: absolute;
		inset: 0;
		opacity: 0;
		transition: opacity 0.15s;
		background-image:
			linear-gradient(90deg, rgba(255, 255, 255, 0.35) 1px, transparent 1px),
			linear-gradient(180deg, rgba(255, 255, 255, 0.35) 1px, transparent 1px);
		background-size: calc(100% / 8) calc(100% / 8);
		background-position: -0.5px -0.5px;
		pointer-events: none;
	}
	.fine.show {
		opacity: 1;
	}
	.handle {
		position: absolute;
		width: 28px;
		height: 28px;
		touch-action: none;
	}
	/* corner brackets */
	.handle.nw,
	.handle.ne,
	.handle.se,
	.handle.sw {
		border: 0 solid white;
	}
	.handle.nw { left: 0; top: 0; border-left-width: 4px; border-top-width: 4px; cursor: nwse-resize; }
	.handle.ne { right: 0; top: 0; border-right-width: 4px; border-top-width: 4px; cursor: nesw-resize; }
	.handle.se { right: 0; bottom: 0; border-right-width: 4px; border-bottom-width: 4px; cursor: nwse-resize; }
	.handle.sw { left: 0; bottom: 0; border-left-width: 4px; border-bottom-width: 4px; cursor: nesw-resize; }
	/* edge grips (invisible, wide hit areas) */
	.handle.n, .handle.s { left: 28px; right: 28px; width: auto; height: 22px; cursor: ns-resize; }
	.handle.n { top: -11px; }
	.handle.s { bottom: -11px; }
	.handle.e, .handle.w { top: 28px; bottom: 28px; height: auto; width: 22px; cursor: ew-resize; }
	.handle.e { right: -11px; }
	.handle.w { left: -11px; }
</style>
