<script lang="ts">
	// Photos-style ruler: drag sideways to change the value; double-tap resets.
	let {
		value,
		min,
		max,
		label,
		format,
		oninput,
		oncommit
	}: {
		value: number;
		min: number;
		max: number;
		label: string;
		format: (v: number) => string;
		oninput: (v: number) => void;
		oncommit: () => void;
	} = $props();

	const zero = $derived(min < 0 ? 0 : min);
	/** Pixels of drag for the whole range. */
	const SPAN = 320;
	const TICK = 8; // px between ticks
	const offset = $derived(((value - zero) / (max - min)) * SPAN);

	let start: { x: number; v: number } | null = null;
	let lastTap = 0;
	let el: HTMLDivElement;

	function down(e: PointerEvent) {
		el.setPointerCapture(e.pointerId);
		start = { x: e.clientX, v: value };
		const now = performance.now();
		if (now - lastTap < 300) {
			oninput(zero);
			oncommit();
			start = null;
		}
		lastTap = now;
	}
	function move(e: PointerEvent) {
		if (!start) return;
		let v = start.v - ((e.clientX - start.x) / SPAN) * (max - min);
		v = Math.min(max, Math.max(min, v));
		// gentle detent at zero
		if (Math.abs(v - zero) < (max - min) * 0.012) v = zero;
		if (v !== value) {
			if (Math.sign(v - zero) !== Math.sign(value - zero) && (v === zero) !== (value === zero)) navigator.vibrate?.(5);
			oninput(v);
		}
	}
	function up() {
		if (start) oncommit();
		start = null;
	}
	function key(e: KeyboardEvent) {
		const stepSize = (max - min) / 100;
		if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') oninput(Math.max(min, value - stepSize));
		else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') oninput(Math.min(max, value + stepSize));
		else return;
		e.preventDefault();
		oncommit();
	}
</script>

<div class="dial">
	<div class="readout">
		<span class="name">{label}</span>
		<span class="val" class:changed={value !== zero}>{format(value)}</span>
	</div>
	<div
		class="ruler"
		bind:this={el}
		role="slider"
		tabindex="0"
		aria-label={label}
		aria-valuemin={min}
		aria-valuemax={max}
		aria-valuenow={value}
		onpointerdown={down}
		onpointermove={move}
		onpointerup={up}
		onpointercancel={up}
		onkeydown={key}
		style="--off: {-offset}px; --tick: {TICK}px"
	>
		<div class="ticks"></div>
		<div class="needle"></div>
	</div>
</div>

<style>
	.dial {
		user-select: none;
		-webkit-user-select: none;
	}
	.readout {
		display: flex;
		justify-content: center;
		gap: 8px;
		font-size: 13px;
		color: #8e8e93;
		margin-bottom: 6px;
	}
	.name {
		text-transform: uppercase;
		letter-spacing: 0.04em;
		font-size: 11px;
		align-self: center;
	}
	.val {
		font-variant-numeric: tabular-nums;
		color: #f2f2f7;
		min-width: 3ch;
	}
	.val.changed {
		color: #ffd60a;
	}
	.ruler {
		position: relative;
		height: 34px;
		touch-action: none;
		overflow: hidden;
		mask-image: linear-gradient(90deg, transparent, black 25%, black 75%, transparent);
		-webkit-mask-image: linear-gradient(90deg, transparent, black 25%, black 75%, transparent);
		cursor: ew-resize;
	}
	.ticks {
		position: absolute;
		inset: 6px 0;
		/* one tick at the left edge of each tile; tiles shift with the value, a tick sits under the needle at 0 */
		background-image:
			linear-gradient(90deg, #8e8e93 0 1px, transparent 1px),
			linear-gradient(90deg, #48484a 0 1px, transparent 1px);
		background-size: calc(var(--tick) * 5) 100%, var(--tick) 60%;
		background-repeat: repeat-x;
		background-position:
			calc(50% + var(--off) + var(--tick) * 2.5) 0,
			calc(50% + var(--off) + var(--tick) * 0.5) 50%;
	}
	.needle {
		position: absolute;
		left: 50%;
		top: 0;
		bottom: 0;
		width: 2px;
		margin-left: -1px;
		background: #ffd60a;
		border-radius: 1px;
	}
	.ruler:focus-visible {
		outline: 1px solid #0a84ff;
	}
</style>
