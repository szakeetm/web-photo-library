<script lang="ts">
	// Trimming a video: a filmstrip with a handle at each end. The trim is kept on the server (the
	// file isn't changed) and applied when playing and exporting; Save as New makes a trimmed copy in
	// the uploads folder instead.
	import { framesUrl, type CatalogAsset } from '#lib/api.ts';
	import { formatDuration } from '#lib/video.ts';

	let {
		asset,
		start = $bindable(),
		end = $bindable(),
		busy = false,
		onSeek,
		onSave,
		onSaveNew,
		onRevert,
		onCancel
	}: {
		asset: CatalogAsset;
		start: number;
		end: number;
		busy?: boolean;
		onSeek: (t: number) => void;
		onSave: () => void;
		onSaveNew: () => void;
		onRevert: () => void;
		onCancel: () => void;
	} = $props();

	const MIN = 0.5;
	const duration = $derived(asset.dur ?? 0);
	let strip: HTMLElement;
	let dragging = $state<'start' | 'end' | null>(null);

	const pct = (t: number) => `${duration ? (t / duration) * 100 : 0}%`;

	function timeAt(e: PointerEvent) {
		const r = strip.getBoundingClientRect();
		return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)) * duration;
	}

	function down(which: 'start' | 'end', e: PointerEvent) {
		dragging = which;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		e.stopPropagation();
	}

	function move(e: PointerEvent) {
		if (!dragging) return;
		const t = timeAt(e);
		if (dragging === 'start') start = Math.min(t, end - MIN);
		else end = Math.max(t, start + MIN);
		onSeek(dragging === 'start' ? start : end);
	}

	function up() {
		if (dragging === 'end') onSeek(start); // play from the new start next
		dragging = null;
	}

	function nudge(which: 'start' | 'end', e: KeyboardEvent) {
		const step = e.shiftKey ? 1 : 0.1;
		const d = e.key === 'ArrowLeft' ? -step : e.key === 'ArrowRight' ? step : 0;
		if (!d) return;
		e.preventDefault();
		e.stopPropagation();
		if (which === 'start') start = Math.min(Math.max(0, start + d), end - MIN);
		else end = Math.max(Math.min(duration, end + d), start + MIN);
		onSeek(which === 'start' ? start : end);
	}

	const changed = $derived(start > 0.05 || duration - end > 0.05);
</script>

<div class="trim video-controls" role="group" aria-label="Trim video">
	<div class="strip" bind:this={strip} style:background-image="url({framesUrl(asset.id)})">
		<div class="dim" style:left="0" style:width={pct(start)}></div>
		<div class="dim" style:left={pct(end)} style:right="0"></div>
		<div class="frame" style:left={pct(start)} style:width="calc({pct(end)} - {pct(start)})"></div>
		<div
			class="handle"
			style:left={pct(start)}
			role="slider"
			tabindex="0"
			aria-label="Start"
			aria-valuemin={0}
			aria-valuemax={duration}
			aria-valuenow={start}
			onpointerdown={(e) => down('start', e)}
			onpointermove={move}
			onpointerup={up}
			onpointercancel={up}
			onkeydown={(e) => nudge('start', e)}
		></div>
		<div
			class="handle end"
			style:left={pct(end)}
			role="slider"
			tabindex="0"
			aria-label="End"
			aria-valuemin={0}
			aria-valuemax={duration}
			aria-valuenow={end}
			onpointerdown={(e) => down('end', e)}
			onpointermove={move}
			onpointerup={up}
			onpointercancel={up}
			onkeydown={(e) => nudge('end', e)}
		></div>
	</div>
	<div class="row">
		<span class="time">{formatDuration(start)} – {formatDuration(end)} · {formatDuration(end - start)}</span>
		<span class="spacer"></span>
		{#if asset.tr}<button class="btn" disabled={busy} onclick={onRevert}>Revert</button>{/if}
		<button class="btn" disabled={busy} onclick={onCancel}>Cancel</button>
		<button class="btn" disabled={busy || !changed} onclick={onSaveNew} title="A trimmed copy, as a new video">Save as New</button>
		<button class="btn primary" disabled={busy} onclick={onSave}>Save</button>
	</div>
</div>

<style>
	.trim {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		z-index: 5;
		padding: 10px 16px calc(env(safe-area-inset-bottom) + 10px);
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
	}
	.strip {
		position: relative;
		height: 48px;
		border-radius: 6px;
		background-size: 100% 100%;
		background-color: #222;
		touch-action: none;
	}
	.dim {
		position: absolute;
		top: 0;
		bottom: 0;
		background: rgba(0, 0, 0, 0.6);
	}
	.frame {
		position: absolute;
		top: -2px;
		bottom: -2px;
		border: 3px solid #f5c518;
		border-radius: 6px;
		pointer-events: none;
	}
	.handle {
		position: absolute;
		top: -4px;
		bottom: -4px;
		width: 18px;
		margin-left: -9px;
		border-radius: 5px;
		background: #f5c518;
		cursor: ew-resize;
		touch-action: none;
	}
	.handle::after {
		content: '';
		position: absolute;
		left: 7px;
		top: 14px;
		bottom: 14px;
		width: 4px;
		border-radius: 2px;
		background: rgba(0, 0, 0, 0.5);
	}
	.row {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-top: 10px;
		flex-wrap: wrap;
	}
	.time {
		font-size: 13px;
		font-variant-numeric: tabular-nums;
	}
	.spacer {
		flex: 1;
	}
</style>
