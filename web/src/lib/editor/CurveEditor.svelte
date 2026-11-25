<script lang="ts">
	// Tone curve editor (desktop): drag points, click the line to add one, double-click a point
	// (or drag it off the graph) to remove it. The luminance histogram is drawn behind.
	import { evalCurve, IDENTITY_CURVE, type Point } from './curve';

	let {
		points,
		histogram = null,
		onchange,
		oncommit
	}: {
		points: Point[] | undefined;
		histogram?: Float32Array | null;
		onchange: (p: Point[]) => void;
		oncommit: () => void;
	} = $props();

	const SIZE = 240;
	const pts = $derived(points && points.length >= 2 ? points : IDENTITY_CURVE);
	let svg: SVGSVGElement;
	let dragging = $state<number | null>(null);
	let removing = $state(false);

	const path = $derived.by(() => {
		let d = '';
		for (let i = 0; i <= 96; i++) {
			const x = i / 96;
			d += `${i ? 'L' : 'M'}${(x * SIZE).toFixed(1)},${((1 - evalCurve(pts, x)) * SIZE).toFixed(1)}`;
		}
		return d;
	});

	const histPath = $derived.by(() => {
		if (!histogram) return '';
		let max = 0;
		for (let i = 1; i < histogram.length - 1; i++) max = Math.max(max, histogram[i]);
		if (!max) return '';
		let d = `M0,${SIZE}`;
		for (let i = 0; i < histogram.length; i++) {
			const x = (i / (histogram.length - 1)) * SIZE;
			d += `L${x.toFixed(1)},${(SIZE - Math.min(1, histogram[i] / max) * SIZE * 0.9).toFixed(1)}`;
		}
		return d + `L${SIZE},${SIZE}Z`;
	});

	function toCurve(e: PointerEvent): Point {
		const r = svg.getBoundingClientRect();
		return [(e.clientX - r.left) / r.width, 1 - (e.clientY - r.top) / r.height];
	}

	const clamp01 = (v: number) => Math.min(1, Math.max(0, v));
	const GAP = 0.02;

	function startDrag(e: PointerEvent, i: number) {
		e.stopPropagation();
		svg.setPointerCapture(e.pointerId);
		dragging = i;
	}

	function addPoint(e: PointerEvent) {
		const [x, y] = toCurve(e);
		if (pts.length >= 16) return;
		if (pts.some((p) => Math.abs(p[0] - x) < GAP)) return;
		const next = [...pts, [clamp01(x), clamp01(y)] as Point].sort((a, b) => a[0] - b[0]);
		onchange(next);
		svg.setPointerCapture(e.pointerId);
		dragging = next.findIndex((p) => p[0] === clamp01(x));
	}

	function move(e: PointerEvent) {
		if (dragging == null) return;
		const [x, y] = toCurve(e);
		const i = dragging;
		const inner = i > 0 && i < pts.length - 1;
		removing = inner && (y < -0.15 || y > 1.15 || x < -0.1 || x > 1.1);
		const lo = i > 0 ? pts[i - 1][0] + GAP : 0;
		const hi = i < pts.length - 1 ? pts[i + 1][0] - GAP : 1;
		const next = pts.map((p) => [...p] as Point);
		next[i] = [Math.min(hi, Math.max(lo, x)), clamp01(y)];
		onchange(next);
	}

	function up() {
		if (dragging == null) return;
		if (removing) onchange(pts.filter((_, k) => k !== dragging));
		dragging = null;
		removing = false;
		oncommit();
	}

	function remove(i: number) {
		if (i === 0 || i === pts.length - 1) return;
		onchange(pts.filter((_, k) => k !== i));
		oncommit();
	}
</script>

<svg
	bind:this={svg}
	class="curve"
	viewBox="0 0 {SIZE} {SIZE}"
	role="application"
	aria-label="Tone curve"
	onpointerdown={addPoint}
	onpointermove={move}
	onpointerup={up}
	onpointercancel={up}
>
	{#if histPath}<path d={histPath} class="hist" />{/if}
	{#each [0.25, 0.5, 0.75] as g (g)}
		<line x1={g * SIZE} y1="0" x2={g * SIZE} y2={SIZE} class="grid" />
		<line x1="0" y1={g * SIZE} x2={SIZE} y2={g * SIZE} class="grid" />
	{/each}
	<line x1="0" y1={SIZE} x2={SIZE} y2="0" class="diag" />
	<path d={path} class="line" />
	{#each pts as p, i (i)}
		<circle
			cx={p[0] * SIZE}
			cy={(1 - p[1]) * SIZE}
			r={dragging === i ? 7 : 5}
			class="pt"
			class:removing={removing && dragging === i}
			role="presentation"
			onpointerdown={(e) => startDrag(e, i)}
			ondblclick={() => remove(i)}
		/>
	{/each}
</svg>

<style>
	.curve {
		width: 100%;
		aspect-ratio: 1;
		background: #1c1c1e;
		border-radius: 6px;
		touch-action: none;
		cursor: crosshair;
		display: block;
	}
	.hist {
		fill: rgba(255, 255, 255, 0.12);
	}
	.grid {
		stroke: rgba(255, 255, 255, 0.08);
		stroke-width: 1;
	}
	.diag {
		stroke: rgba(255, 255, 255, 0.15);
		stroke-dasharray: 3 3;
	}
	.line {
		fill: none;
		stroke: #f2f2f7;
		stroke-width: 1.6;
	}
	.pt {
		fill: #1c1c1e;
		stroke: #f2f2f7;
		stroke-width: 1.6;
		cursor: grab;
	}
	.pt.removing {
		stroke: #ff453a;
	}
</style>
