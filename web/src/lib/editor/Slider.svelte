<script lang="ts">
	// Desktop (Lightroom-style) slider row: label, value, track. Double-click resets.
	let {
		label,
		value,
		min,
		max,
		step = 0.01,
		format = (v: number) => (v > 0 ? '+' : '') + (Math.abs(max) > 1.5 ? v.toFixed(2) : Math.round(v * 100).toString()),
		oninput,
		oncommit
	}: {
		label: string;
		value: number;
		min: number;
		max: number;
		step?: number;
		format?: (v: number) => string;
		oninput: (v: number) => void;
		oncommit: () => void;
	} = $props();

	const zero = $derived(min < 0 ? 0 : min);
	const pct = (v: number) => ((v - min) / (max - min)) * 100;
</script>

<div class="slider" class:changed={value !== zero}>
	<div class="head">
		<span class="label">{label}</span>
		<span class="value">{format(value)}</span>
	</div>
	<div class="track-wrap">
		<div class="fill" style="left: {Math.min(pct(zero), pct(value))}%; width: {Math.abs(pct(value) - pct(zero))}%"></div>
		<input
			type="range"
			{min}
			{max}
			{step}
			{value}
			aria-label={label}
			oninput={(e) => oninput(Number((e.target as HTMLInputElement).value))}
			onchange={oncommit}
			ondblclick={() => {
				oninput(zero);
				oncommit();
			}}
		/>
	</div>
</div>

<style>
	.slider {
		padding: 4px 0;
	}
	.head {
		display: flex;
		justify-content: space-between;
		font-size: 12px;
		color: #c7c7cc;
	}
	.changed .value {
		color: #ffd60a;
	}
	.value {
		font-variant-numeric: tabular-nums;
		color: #8e8e93;
	}
	.track-wrap {
		position: relative;
		height: 18px;
	}
	.fill {
		position: absolute;
		top: 8px;
		height: 2px;
		background: #ffd60a;
		pointer-events: none;
		z-index: 1;
	}
	input {
		position: absolute;
		inset: 0;
		width: 100%;
		margin: 0;
		background: transparent;
		-webkit-appearance: none;
		appearance: none;
		cursor: pointer;
	}
	input::-webkit-slider-runnable-track {
		height: 2px;
		background: #48484a;
	}
	input::-moz-range-track {
		height: 2px;
		background: #48484a;
	}
	input::-webkit-slider-thumb {
		-webkit-appearance: none;
		width: 12px;
		height: 12px;
		margin-top: -5px;
		border-radius: 50%;
		background: #f2f2f7;
		position: relative;
		z-index: 2;
	}
	input::-moz-range-thumb {
		width: 12px;
		height: 12px;
		border: none;
		border-radius: 50%;
		background: #f2f2f7;
	}
	input:focus-visible {
		outline: 1px solid #0a84ff;
	}
</style>
