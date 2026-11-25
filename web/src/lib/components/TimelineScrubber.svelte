<script lang="ts">
	// Timeline scrubber: a rail along the right edge with year marks. Drag (or click) to jump through
	// the grid; a bubble shows the month under the finger. On touch screens it appears while scrolling.
	import { onMount } from 'svelte';
	import { markAt, yearTicks, type MonthMark } from '#lib/timeline.ts';

	let {
		marks,
		gridHeight,
		gridTop
	}: {
		marks: MonthMark[];
		/** Height of the whole grid (px) and its top within the page. */
		gridHeight: number;
		gridTop: number;
	} = $props();

	let rail: HTMLDivElement;
	let railTop = $state(0);
	let railHeight = $state(0);
	let viewport = $state(800);
	let scrollY = $state(0);
	let dragging = $state(false);
	let hovering = $state(false);
	let recentlyScrolled = $state(false);
	const touch = typeof matchMedia !== 'undefined' && matchMedia('(pointer: coarse)').matches;

	/** How far the page scrolls. */
	let range = $state(1);
	$effect(() => {
		void gridHeight;
		void gridTop;
		measure();
	});
	const fraction = $derived(Math.min(1, Math.max(0, scrollY / range)));
	const ticks = $derived(yearTicks(marks, range, railHeight));
	/** Month at the viewport top (just below the title bar). */
	const current = $derived(markAt(marks, scrollY - gridTop + 80));
	const visible = $derived(!touch || dragging || recentlyScrolled);

	function measure() {
		viewport = window.innerHeight;
		range = Math.max(1, document.documentElement.scrollHeight - viewport);
		if (rail) {
			const r = rail.getBoundingClientRect();
			railTop = r.top;
			railHeight = r.height;
		}
	}

	let hideTimer: ReturnType<typeof setTimeout> | undefined;
	function onScroll() {
		scrollY = window.scrollY;
		range = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
		if (!touch) return;
		recentlyScrolled = true;
		clearTimeout(hideTimer);
		hideTimer = setTimeout(() => (recentlyScrolled = false), 1500);
	}

	function jumpTo(clientY: number) {
		const f = Math.min(1, Math.max(0, (clientY - railTop) / Math.max(1, railHeight)));
		window.scrollTo(0, f * range);
		scrollY = window.scrollY;
	}

	function down(e: PointerEvent) {
		e.preventDefault();
		measure();
		rail.setPointerCapture(e.pointerId);
		dragging = true;
		jumpTo(e.clientY);
	}
	function move(e: PointerEvent) {
		if (dragging) jumpTo(e.clientY);
	}
	function up() {
		dragging = false;
		if (touch) {
			clearTimeout(hideTimer);
			hideTimer = setTimeout(() => (recentlyScrolled = false), 1200);
		}
	}

	onMount(() => {
		measure();
		scrollY = window.scrollY;
		window.addEventListener('scroll', onScroll, { passive: true });
		window.addEventListener('resize', measure);
		return () => {
			window.removeEventListener('scroll', onScroll);
			window.removeEventListener('resize', measure);
			clearTimeout(hideTimer);
		};
	});
</script>

<div
	class="scrubber"
	class:visible
	class:active={dragging || hovering}
	bind:this={rail}
	role="scrollbar"
	aria-controls="photo-grid"
	aria-orientation="vertical"
	aria-valuemin={0}
	aria-valuemax={100}
	aria-valuenow={Math.round(fraction * 100)}
	aria-label="Timeline"
	tabindex="-1"
	onpointerdown={down}
	onpointermove={move}
	onpointerup={up}
	onpointercancel={up}
	onpointerenter={() => {
		hovering = true;
		measure();
	}}
	onpointerleave={() => (hovering = false)}
>
	{#each ticks as t (t.year)}
		<span class="year" style="top: {t.px}px">{t.year}</span>
	{/each}
	<span class="thumb" style="top: {fraction * railHeight}px"></span>
	{#if dragging && current}
		<span class="bubble" style="top: {fraction * railHeight}px">{current.label}</span>
	{/if}
</div>

<style>
	.scrubber {
		position: fixed;
		z-index: 12;
		right: 0;
		top: calc(env(safe-area-inset-top) + 72px);
		bottom: calc(var(--tabbar-h) + env(safe-area-inset-bottom) + 16px);
		width: 44px;
		touch-action: none;
		cursor: ns-resize;
		opacity: 0;
		pointer-events: none;
		transition: opacity 0.2s;
		user-select: none;
		-webkit-user-select: none;
	}
	.scrubber.visible {
		opacity: 1;
		pointer-events: auto;
	}
	@media (min-width: 768px) {
		.scrubber {
			bottom: 16px;
			right: 4px;
		}
	}
	.year {
		position: absolute;
		right: 8px;
		transform: translateY(-50%);
		font-size: 10px;
		font-weight: 600;
		color: var(--fg-secondary);
		background: var(--bg-bar);
		border-radius: 6px;
		padding: 1px 4px;
		opacity: 0;
		transition: opacity 0.15s;
		pointer-events: none;
	}
	/* Year marks show while the rail is in use (and always on touch while it is visible). */
	.scrubber.active .year {
		opacity: 1;
	}
	@media (pointer: coarse) {
		.year {
			opacity: 1;
		}
	}
	.thumb {
		position: absolute;
		right: 6px;
		width: 6px;
		height: 36px;
		margin-top: -18px;
		border-radius: 3px;
		background: var(--fg-secondary);
		opacity: 0.55;
		pointer-events: none;
	}
	.scrubber.active .thumb {
		opacity: 0.9;
		background: var(--accent);
	}
	@media (pointer: coarse) {
		.thumb {
			width: 30px;
			height: 30px;
			right: 6px;
			margin-top: -15px;
			border-radius: 15px;
			background: var(--bg-bar);
			box-shadow: 0 1px 6px rgba(0, 0, 0, 0.25);
			opacity: 1;
			backdrop-filter: blur(16px);
			-webkit-backdrop-filter: blur(16px);
		}
		.thumb::after {
			content: '⇅';
			display: block;
			text-align: center;
			line-height: 30px;
			font-size: 14px;
			color: var(--fg-secondary);
		}
	}
	.bubble {
		position: absolute;
		right: 48px;
		transform: translateY(-50%);
		white-space: nowrap;
		padding: 6px 12px;
		border-radius: 14px;
		font-size: 14px;
		font-weight: 600;
		background: var(--bg-bar);
		backdrop-filter: blur(16px);
		-webkit-backdrop-filter: blur(16px);
		box-shadow: 0 2px 10px rgba(0, 0, 0, 0.2);
		pointer-events: none;
	}
</style>
