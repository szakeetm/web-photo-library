<script lang="ts" module>
	/** The grid's last width, so a grid that opens again lays out at once at its real size. */
	let lastWidth = 0;
</script>

<script lang="ts">
	// Virtualised photo grid using window scrolling. Pinch (touch/trackpad) and ctrl+wheel change density.
	import { onMount, tick } from 'svelte';
	import { layoutGrid, visibleRange, columnsFor, idAt, neighbour, type GridLayout, type Section } from '#lib/gridLayout.ts';
	import Thumb from './Thumb.svelte';
	import MonthJump from './MonthJump.svelte';
	import { markAt, monthMarks, type MonthMark } from '#lib/timeline.ts';

	import { dragSelect, type Selection } from '#lib/selection.svelte.ts';
	import { scroller } from '#lib/scroller.ts';
	import { gridZoom } from '#lib/gridView.svelte.ts';

	let {
		sections,
		startAtEnd = false,
		selection,
		onActivate,
		onLongPress,
		onFocusMove
	}: {
		sections: Section[];
		startAtEnd?: boolean;
		selection?: Selection;
		onActivate: (id: string, e: MouseEvent) => void;
		onLongPress?: (id: string) => void;
		/** desktop: the arrow keys select the photo next to the selected one (Photos on the Mac); unset: no arrow keys */
		onFocusMove?: (id: string) => void;
	} = $props();

	const targets = [64, 96, 136, 200, 300];
	const GAP = 2;
	const HEADER = 48;
	/** the sticky title bar over the grid */
	const TOP_BAR = 56;

	let container: HTMLDivElement;
	// Until the grid knows its width it lays out nothing: a guess (one photo per row) would mount
	// hundreds of thumbnails, and build a row per photo, for a frame nobody sees.
	let width = $state(lastWidth);
	let scrollTop = $state(0);
	let viewport = $state(800);
	let containerTop = $state(0);
	let density = $state(storedDensity());
	$effect(() => {
		if (width > 0) lastWidth = width;
	});

	function storedDensity(): number {
		try {
			const v = localStorage.getItem('gridDensity');
			const n = Number(v);
			if (v !== null && Number.isInteger(n) && n >= 0 && n < targets.length) return n;
		} catch {
			/* storage unavailable */
		}
		return typeof window !== 'undefined' && window.innerWidth < 600 ? 1 : 2;
	}

	const columns = $derived(columnsFor(width || 1, targets[density]));
	const EMPTY: GridLayout = { blocks: [], height: 0, tile: 1, columns: 1, gap: GAP, indexOf: new Map() };
	const layout = $derived(width > 0 ? layoutGrid(sections, { width, columns, gap: GAP, headerHeight: HEADER }) : EMPTY);
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
	// The native scrollbar scrolls; the month pill opens the month picker to jump.
	let jumping = $state(false);

	function jumpTo(m: MonthMark) {
		jumping = false;
		// leave room for the sticky title bar
		scroller.to(Math.max(0, containerTop + m.y - TOP_BAR));
	}

	// Arrow keys select the photo next to the selected one (desktop; not after Select was pressed),
	// scrolling it into view; with shift they select the range from the anchor to there (Photos on the
	// Mac). Several selected: from the range's moving end, or the one clicked last. Nothing selected:
	// the first press selects the top-left photo on screen.
	$effect(() => {
		if (!onFocusMove) return;
		const onKey = (e: KeyboardEvent) => {
			const dir = ({ ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down' } as const)[e.key as 'ArrowLeft'];
			if (!dir || e.metaKey || e.ctrlKey || e.altKey || selection?.explicit) return;
			if ((e.target as HTMLElement).closest?.('input, select, textarea, [contenteditable]')) return;
			if (document.querySelector('.viewer, [role=dialog], [role=alertdialog]')) return;
			const from = selection?.cursor;
			const next = from && layout.blocks.some((b) => b.kind === 'row' && b.items.includes(from))
				? neighbour(layout.blocks, from, dir)
				: firstOnScreen();
			e.preventDefault();
			if (!next) return;
			if (e.shiftKey && from && selection) {
				const order = layout.blocks.flatMap((b) => (b.kind === 'row' ? b.items : []));
				selection.rangeTo(order, next);
			} else onFocusMove(next);
			reveal(next);
		};
		window.addEventListener('keydown', onKey);
		return () => window.removeEventListener('keydown', onKey);
	});

	/** The top-left photo whose row is (at least partly) below the title bar. */
	function firstOnScreen(): string | null {
		const top = scroller.top - containerTop + TOP_BAR;
		for (const b of layout.blocks) if (b.kind === 'row' && b.y + b.h > top) return b.items[0];
		return null;
	}

	/** Scrolls just enough to show a photo's row below the title bar. */
	function reveal(id: string) {
		const b = layout.blocks.find((x) => x.kind === 'row' && x.items.includes(id));
		if (!b) return;
		const rowTop = containerTop + b.y;
		const rowBottom = rowTop + b.h;
		if (rowTop < scroller.top + TOP_BAR) scroller.to(rowTop - TOP_BAR - GAP);
		else if (rowBottom > scroller.top + viewport) scroller.to(rowBottom - viewport + GAP);
	}

	function measure() {
		viewport = window.innerHeight;
		scrollTop = scroller.top;
		if (container) containerTop = container.getBoundingClientRect().top + scroller.top;
	}

	// While the grid flies past (a fling), thumbnails show their blurred placeholder and load once it
	// slows down: decoding hundreds of images that are on screen for a frame is wasted work (and on a
	// phone can run the page out of memory). Only real speed holds them back (scrollbar drags, hard
	// flings), and they load again as soon as the grid slows down, not when a long momentum scroll
	// finally stops. Decoding is off the main thread.
	/** px per ms: hold back above FAST (about a screen per 100 ms), load again below SLOW */
	const FAST = 9;
	const SLOW = 5;
	let flinging = $state(false);
	let lastY = 0;
	let lastT = 0;
	let smooth = 0;
	let settleTimer: ReturnType<typeof setTimeout> | undefined;
	let raf = 0;
	function onScroll() {
		if (raf) return;
		raf = requestAnimationFrame((t) => {
			raf = 0;
			const y = scroller.top;
			const speed = lastT ? Math.abs(y - lastY) / Math.max(1, t - lastT) : 0; // px per ms
			lastY = y;
			lastT = t;
			scrollTop = y;
			// a few frames' average, so one uneven frame doesn't flip it
			smooth = smooth * 0.6 + speed * 0.4;
			if (smooth > FAST) flinging = true;
			else if (smooth < SLOW) flinging = false;
			clearTimeout(settleTimer);
			settleTimer = setTimeout(() => {
				flinging = false;
				lastT = 0;
				smooth = 0;
			}, 60);
		});
	}

	/** Change density keeping the photo at the viewport centre in place. */
	async function setDensity(next: number) {
		next = Math.max(0, Math.min(targets.length - 1, next));
		if (next === density) return;
		const centerY = scroller.top + viewport / 2 - containerTop;
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
		if (pos) scroller.to(containerTop + layout.blocks[pos.block].y - offset - viewport / 2);
	}

	onMount(() => {
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
		const offScroll = scroller.onScroll(onScroll);
		window.addEventListener('resize', measure);
		window.addEventListener('wheel', onWheel, { passive: false });
		document.addEventListener('gesturestart', onGestureStart, { passive: false });
		document.addEventListener('gesturechange', onGestureChange, { passive: false });
		document.addEventListener('gestureend', onGestureEnd, { passive: false });
		return () => {
			offScroll();
			clearTimeout(settleTimer);
			window.removeEventListener('resize', measure);
			window.removeEventListener('wheel', onWheel);
			document.removeEventListener('gesturestart', onGestureStart);
			document.removeEventListener('gesturechange', onGestureChange);
			document.removeEventListener('gestureend', onGestureEnd);
		};
	});

	// Drag-select while selecting (Photos on iPhone; with a mouse too): a drag that starts sideways on a photo selects
	// everything between it and the photo under the finger (or unselects, if the first one was
	// selected); up/down drags still scroll. Near the top or bottom edge the grid scrolls by itself.
	const order = $derived(sections.flatMap((s) => s.items));
	let drag: {
		pointer: number;
		x: number;
		y: number;
		from: string;
		base: Set<string>;
		active: boolean;
		lastX: number;
		lastY: number;
	} | null = null;
	let suppressClick = false;
	let autoRaf = 0;

	function pointAt(clientX: number, clientY: number) {
		const r = container.getBoundingClientRect();
		return idAt(layout, clientX - r.left, clientY - r.top);
	}

	function dragDown(e: PointerEvent) {
		if (!selection?.active || e.button !== 0) return;
		const id = pointAt(e.clientX, e.clientY);
		if (!id) return;
		drag = { pointer: e.pointerId, x: e.clientX, y: e.clientY, from: id, base: new Set(selection.ids), active: false, lastX: e.clientX, lastY: e.clientY };
	}

	function update() {
		if (!drag || !selection) return;
		const id = pointAt(drag.lastX, drag.lastY);
		if (id) selection.set(dragSelect(drag.base, order, drag.from, id), id);
	}

	function autoScroll() {
		autoRaf = 0;
		if (!drag?.active) return;
		const edge = 80;
		const top = Math.max(edge, containerTop - scroller.top + edge);
		let v = 0;
		if (drag.lastY < top) v = -Math.min(20, (top - drag.lastY) / 3);
		else if (drag.lastY > window.innerHeight - edge) v = Math.min(20, (drag.lastY - (window.innerHeight - edge)) / 3);
		if (v) {
			scroller.by(v);
			update();
			autoRaf = requestAnimationFrame(autoScroll);
		}
	}

	function dragMove(e: PointerEvent) {
		if (!drag || e.pointerId !== drag.pointer) return;
		drag.lastX = e.clientX;
		drag.lastY = e.clientY;
		if (!drag.active) {
			const dx = Math.abs(e.clientX - drag.x);
			const dy = Math.abs(e.clientY - drag.y);
			if (dx < 8 && dy < 8) return;
			if (dy > dx) return void (drag = null); // a scroll
			drag.active = true;
			try {
				container.setPointerCapture(e.pointerId);
			} catch {
				/* already released */
			}
		}
		e.preventDefault();
		update();
		if (!autoRaf) autoRaf = requestAnimationFrame(autoScroll);
	}

	function dragUp(e: PointerEvent) {
		if (!drag || e.pointerId !== drag.pointer) return;
		if (drag.active) {
			// a click that may follow the drag isn't a tap (and none may come: forget it soon)
			suppressClick = true;
			setTimeout(() => (suppressClick = false), 300);
		}
		drag = null;
		cancelAnimationFrame(autoRaf);
		autoRaf = 0;
	}

	function activate(id: string, e: MouseEvent) {
		if (suppressClick) {
			suppressClick = false;
			return;
		}
		onActivate(id, e);
	}

	// The title bar's zoom control (desktop) drives the density.
	$effect(() => {
		gridZoom.max = targets.length - 1;
		gridZoom.set = (n) => setDensity(n);
		gridZoom.enabled = true;
		return () => {
			gridZoom.enabled = false;
		};
	});
	$effect(() => {
		gridZoom.level = Math.max(0, density);
	});

	// Photos-style: open scrolled to the newest photos at the bottom.
	let scrolledToEnd = false;
	$effect(() => {
		if (startAtEnd && !scrolledToEnd && width > 0 && layout.height > 0) {
			scrolledToEnd = true;
			tick().then(() => {
				measure();
				scroller.to(scroller.scrollHeight);
			});
		}
	});
</script>

<div
	class="grid"
	role="group"
	aria-label="Photos"
	class:selecting={selection?.active}
	bind:this={container}
	bind:clientWidth={width}
	style="height: {layout.height}px"
	onpointerdown={dragDown}
	onpointermove={dragMove}
	onpointerup={dragUp}
	onpointercancel={dragUp}
	ondragstart={(e) => selection?.active && e.preventDefault()}
>
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
					onActivate={activate}
					{onLongPress}
					defer={flinging}
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
{#if jumping}
	<MonthJump {marks} current={currentMark} onPick={jumpTo} onClose={() => (jumping = false)} />
{/if}

<style>
	.grid {
		position: relative;
		width: 100%;
	}
	/* sideways drags select instead of doing anything else */
	.grid.selecting {
		touch-action: pan-y;
	}
	.grid.selecting :global(.thumb) {
		touch-action: pan-y;
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
