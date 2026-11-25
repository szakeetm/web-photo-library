<script lang="ts">
	// The viewer's gesture log (see gestureDebug.svelte.ts). Listens on window in the bubbling phase, so
	// it sees each event after the viewer's own handlers (including whether they prevented the default),
	// and never takes touches itself (pointer-events: none).
	import { onMount } from 'svelte';

	/** The viewer's gesture state at the time of each event. */
	let { snapshot }: { snapshot: () => string } = $props();

	let lines = $state<string[]>([]);
	let now = $state('');
	const MAX = 18;
	let lastMove = 0;
	let t0 = performance.now();

	function target(e: Event) {
		const el = e.target as Element | null;
		if (!el || !('tagName' in el)) return '?';
		const cls = typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
		return el.tagName.toLowerCase() + cls;
	}

	function zoom() {
		const v = window.visualViewport;
		return v ? `vv×${v.scale.toFixed(2)}` : '';
	}

	function log(text: string) {
		const t = ((performance.now() - t0) / 1000).toFixed(2);
		lines = [...lines.slice(-(MAX - 1)), `${t} ${text} | ${snapshot()}`];
	}

	onMount(() => {
		const opts = { passive: true };
		const pointer = (e: PointerEvent) => {
			if (e.type === 'pointermove') {
				const n = performance.now();
				if (n - lastMove < 250) return; // a sample, not every move
				lastMove = n;
			}
			log(`${e.type.replace('pointer', 'p')} #${e.pointerId}${e.isPrimary ? '*' : ''} ${e.pointerType} ${target(e)}${e.defaultPrevented ? ' PREV' : ''}`);
		};
		const touch = (e: TouchEvent) => {
			if (e.type === 'touchmove') {
				if (e.touches.length < 2) return;
				const n = performance.now();
				if (n - lastMove < 250) return;
				lastMove = n;
			}
			log(`${e.type} n=${e.touches.length} ${target(e)}${e.defaultPrevented ? ' PREV' : ''} ${zoom()}`);
		};
		const gesture = (e: Event) => {
			const g = e as unknown as { scale?: number };
			log(`${e.type} s=${g.scale?.toFixed(2) ?? '?'} ${target(e)}${e.defaultPrevented ? ' PREV' : ''} ${zoom()}`);
		};
		const types: [string, EventListener][] = [
			...['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'lostpointercapture'].map((t) => [t, pointer as EventListener] as [string, EventListener]),
			...['touchstart', 'touchmove', 'touchend', 'touchcancel'].map((t) => [t, touch as EventListener] as [string, EventListener]),
			...['gesturestart', 'gesturechange', 'gestureend'].map((t) => [t, gesture] as [string, EventListener])
		];
		for (const [t, f] of types) window.addEventListener(t, f, opts);
		const tick = setInterval(() => (now = `${snapshot()} ${zoom()}`), 200);
		log('viewer opened');
		return () => {
			for (const [t, f] of types) window.removeEventListener(t, f);
			clearInterval(tick);
		};
	});
</script>

<div class="gesture-debug" aria-hidden="true">
	<div class="now">{now}</div>
	{#each lines as l, i (i)}<div>{l}</div>{/each}
</div>

<style>
	.gesture-debug {
		position: fixed;
		left: 4px;
		right: 4px;
		top: calc(env(safe-area-inset-top) + 50px);
		z-index: 1000;
		pointer-events: none;
		font: 10px/1.25 ui-monospace, Menlo, monospace;
		color: #0f0;
		background: rgba(0, 0, 0, 0.6);
		padding: 4px 6px;
		border-radius: 6px;
		white-space: pre-wrap;
		word-break: break-all;
	}
	.now {
		color: #ff0;
	}
</style>
