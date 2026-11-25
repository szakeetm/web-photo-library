<script lang="ts">
	// Virtualised photo grid using window scrolling. Pinch (touch/trackpad), ctrl+wheel and +/- change density.
	import { onMount, tick } from 'svelte';
	import { layoutGrid, visibleRange, columnsFor, type Section } from '#lib/gridLayout.ts';
	import Thumb from './Thumb.svelte';
	import TimelineScrubber from './TimelineScrubber.svelte';
	import MonthJump from './MonthJump.svelte';
	import { markAt, monthMarks, type MonthMark } from '#lib/timeline.ts';

	import type { Selection } from '#lib/selection.svelte.ts';

	let {
		sections,
		startAtEnd = false,
		selection,
		onActivate,
		onLongPress
	}: {
		sections: Section[];
		startAtEnd?: boolean;
		selection?: Selection;
		onActivate: (id: string, e: MouseEvent) => void;
		onLongPress?: (id: string) => void;
	} = $props();

	const targets = [64, 96, 136, 200, 300];
	const GAP = 2;
	const HEADER = 48;

	let container: HTMLDivElement;
	let width = $state(0);
	let scrollTop = $state(0);
	let viewport = $state(800);
	let containerTop = $state(0);
	let density = $state(-1);

	const columns = $derived(columnsFor(width || 1, targets[Math.max(0, density)]));
	const layout = $derived(layoutGrid(sections, { width: width || 1, columns, gap: GAP, headerHeight: HEADER }));
	const range = $derived(visibleRange(layout.blocks, scrollTop - containerTop, viewport, viewport));
	const visible = $derived(layout.blocks.slice(range[0], range[1] + 1));
	/** Label of the section at the top of the viewport (floating date pill). */
	const currentLabel = $derived.by(() => {
		const top = scrollTop - containerTop + 60;
		let label: string | null = null;
		for (const b of layout.blocks) {
			if (b.y > top) break;
			if (b.kind === 'header') label = b.label;
		}
		return label;
	});

	/** Months of this grid (empty when its sections aren't months, e.g. an album). */
	const marks = $derived.by(() => {
		const ys = new Map<string, number>();
		for (const b of layout.blocks) if (b.kind === 'header') ys.set(b.key.slice(2), b.y);
		return monthMarks(sections, ys);
	});
	const currentMark = $derived(markAt(marks, scrollTop - containerTop + 60));
	const showScrubber = $derived(marks.length >= 2 && layout.height > viewport * 2.5);
	let jumping = $state(false);

	function jumpTo(m: MonthMark) {
		jumping = false;
		// leave room for the sticky title bar
		window.scrollTo(0, Math.max(0, containerTop + m.y - 56));
	}

	function measure() {
		viewport = window.innerHeight;
		scrollTop = window.scrollY;
		if (container) containerTop = container.getBoundingClientRect().top + window.scrollY;
	}

	let raf = 0;
	function onScroll() {
		if (raf) return;
		raf = requestAnimationFrame(() => {
			raf = 0;
			scrollTop = window.scrollY;
		});
	}

	/** Change density keeping the photo at the viewport centre in place. */
	async function setDensity(next: number) {
		next = Math.max(0, Math.min(targets.length - 1, next));
		if (next === density) return;
		const centerY = window.scrollY + viewport / 2 - containerTop;
		const [i] = visibleRange(layout.blocks, centerY, 1, 0);
		const anchorBlock = layout.blocks[i];
		const anchorId = anchorBlock?.kind === 'row' ? anchorBlock.items[0] : undefined;
		const offset = anchorBlock ? anchorBlock.y - centerY : 0;
		density = next;
		try {
			localStorage.setItem('gridDensity', String(next));
		} catch {
			/* storage unavailable */
		}
		await tick();
		const pos = anchorId ? layout.indexOf.get(anchorId) : undefined;
		if (pos) window.scrollTo(0, containerTop + layout.blocks[pos.block].y - offset - viewport / 2);
	}

	onMount(() => {
		let stored = NaN;
		try {
			stored = Number(localStorage.getItem('gridDensity'));
		} catch {
			/* ignore */
		}
		density = Number.isFinite(stored) && stored >= 0 && stored < targets.length && localStorage.getItem('gridDensity') !== null
			? stored
			: window.innerWidth < 600 ? 1 : 2;
		measure();

		// Gestures belong to the viewer while it is open.
		const viewerOpen = () => !!document.querySelector('.viewer');
		let wheelAcc = 0;
		const onWheel = (e: WheelEvent) => {
			if (!e.ctrlKey || viewerOpen()) return;
			e.preventDefault();
			wheelAcc += e.deltaY;
			if (Math.abs(wheelAcc) > 40) {
				setDensity(density + (wheelAcc > 0 ? -1 : 1));
				wheelAcc = 0;
			}
		};
		let gestureScale = 1;
		const onGestureStart = (e: Event) => {
			if (viewerOpen()) return;
			e.preventDefault();
			gestureScale = 1;
		};
		const onGestureChange = (e: Event) => {
			if (viewerOpen()) return;
			e.preventDefault();
			gestureScale = (e as unknown as { scale: number }).scale;
		};
		const onGestureEnd = (e: Event) => {
			if (viewerOpen()) return;
			e.preventDefault();
			if (gestureScale > 1.15) setDensity(density + 1);
			else if (gestureScale < 0.87) setDensity(density - 1);
		};
		const onKey = (e: KeyboardEvent) => {
			if (e.target instanceof HTMLInputElement || e.metaKey || e.ctrlKey || viewerOpen() || document.querySelector('[role=dialog]')) return;
			if (e.key === '+' || e.key === '=') setDensity(density + 1);
			if (e.key === '-') setDensity(density - 1);
		};
		window.addEventListener('scroll', onScroll, { passive: true });
		window.addEventListener('resize', measure);
		window.addEventListener('wheel', onWheel, { passive: false });
		document.addEventListener('gesturestart', onGestureStart, { passive: false });
		document.addEventListener('gesturechange', onGestureChange, { passive: false });
		document.addEventListener('gestureend', onGestureEnd, { passive: false });
		window.addEventListener('keydown', onKey);
		return () => {
			window.removeEventListener('scroll', onScroll);
			window.removeEventListener('resize', measure);
			window.removeEventListener('wheel', onWheel);
			document.removeEventListener('gesturestart', onGestureStart);
			document.removeEventListener('gesturechange', onGestureChange);
			document.removeEventListener('gestureend', onGestureEnd);
			window.removeEventListener('keydown', onKey);
		};
	});

	// Photos-style: open scrolled to the newest photos at the bottom.
	let scrolledToEnd = false;
	$effect(() => {
		if (startAtEnd && !scrolledToEnd && width > 0 && layout.height > 0) {
			scrolledToEnd = true;
			tick().then(() => {
				measure();
				window.scrollTo(0, document.documentElement.scrollHeight);
			});
		}
	});
</script>

<div class="grid" bind:this={container} bind:clientWidth={width} style="height: {layout.height}px">
	{#each visible as b (b.key)}
		{#if b.kind === 'header'}
			<h2 class="header" style="transform: translateY({b.y}px); height: {b.h}px">{b.label}</h2>
		{:else}
			{#each b.items as id, col (id)}
				<Thumb
					{id}
					x={col * (layout.tile + GAP)}
					y={b.y}
					size={layout.tile}
					selecting={selection?.active ?? false}
					selected={selection?.ids.has(id) ?? false}
					{onActivate}
					{onLongPress}
				/>
			{/each}
		{/if}
	{/each}
</div>
{#if currentLabel}
	{#if marks.length >= 2}
		<button class="pill" onclick={() => (jumping = true)} aria-label="{currentLabel} — jump to another month" title="Jump to a month"
			>{currentLabel} <span class="caret">▾</span></button
		>
	{:else}
		<div class="pill">{currentLabel}</div>
	{/if}
{/if}
{#if showScrubber}
	<TimelineScrubber {marks} gridHeight={layout.height} gridTop={containerTop} />
{/if}
{#if jumping}
	<MonthJump {marks} current={currentMark} onPick={jumpTo} onClose={() => (jumping = false)} />
{/if}

<style>
	.grid {
		position: relative;
		width: 100%;
	}
	.header {
		position: absolute;
		left: 0;
		top: 0;
		margin: 0;
		padding: 14px 12px 0;
		font-size: 19px;
		font-weight: 700;
	}
	.pill {
		position: fixed;
		top: calc(env(safe-area-inset-top) + 64px);
		left: 50%;
		transform: translateX(-50%);
		z-index: 9;
		padding: 5px 12px;
		border-radius: 14px;
		font-size: 13px;
		font-weight: 600;
		background: var(--bg-bar);
		backdrop-filter: blur(16px);
		-webkit-backdrop-filter: blur(16px);
		pointer-events: none;
		box-shadow: 0 1px 6px rgba(0, 0, 0, 0.12);
	}
	button.pill {
		pointer-events: auto;
		border: none;
		color: var(--fg);
		font-family: inherit;
		cursor: pointer;
	}
	.caret {
		font-size: 10px;
		color: var(--fg-secondary);
		margin-left: 2px;
	}
	@media (min-width: 768px) {
		.pill {
			left: calc(50% + var(--sidebar-w) / 2);
		}
	}
</style>
