<script lang="ts">
	// Jump to a month: years (newest first) with photo counts; a year opens its months.
	import { onMount } from 'svelte';
	import { yearGroups, type MonthMark } from '#lib/timeline.ts';

	let { marks, current, onPick, onClose }: { marks: MonthMark[]; current: MonthMark | null; onPick: (m: MonthMark) => void; onClose: () => void } =
		$props();

	const years = $derived(yearGroups(marks));
	let open = $state<number | null>(null);
	$effect.pre(() => {
		if (open == null) open = current?.year ?? years[0]?.year ?? null;
	});
	const short = (m: MonthMark) => new Date(Date.UTC(2000, m.month - 1, 1)).toLocaleDateString(undefined, { month: 'short', timeZone: 'UTC' });

	let panel: HTMLDivElement;
	onMount(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') {
				e.stopPropagation();
				onClose();
			}
		};
		window.addEventListener('keydown', onKey, true);
		panel.querySelector<HTMLElement>('.year.open, .year')?.focus();
		// keep the current year in view
		panel.querySelector('.year.open')?.scrollIntoView({ block: 'center' });
		return () => window.removeEventListener('keydown', onKey, true);
	});
</script>

<div class="scrim" role="presentation" onclick={onClose}></div>
<div class="panel" bind:this={panel} role="dialog" aria-modal="true" aria-label="Jump to month">
	<div class="head">
		<h3>Jump to</h3>
		<button class="close" onclick={onClose} aria-label="Close">Done</button>
	</div>
	<div class="list">
		{#each years as y (y.year)}
			<button class="year" class:open={open === y.year} aria-expanded={open === y.year} onclick={() => (open = open === y.year ? null : y.year)}>
				<span class="ylabel">{y.year}</span>
				<span class="count">{y.count.toLocaleString()}</span>
				<span class="chev">›</span>
			</button>
			{#if open === y.year}
				<div class="months">
					{#each y.months as m (m.key)}
						<button class="month" class:current={current?.key === m.key} onclick={() => onPick(m)}>
							<span>{short(m)}</span>
							<span class="count">{m.count.toLocaleString()}</span>
						</button>
					{/each}
				</div>
			{/if}
		{/each}
	</div>
</div>

<style>
	.scrim {
		position: fixed;
		inset: 0;
		z-index: 60;
		background: rgba(0, 0, 0, 0.3);
	}
	.panel {
		position: fixed;
		z-index: 61;
		left: 0;
		right: 0;
		bottom: 0;
		max-height: 75dvh;
		display: flex;
		flex-direction: column;
		background: var(--bg);
		border-radius: 14px 14px 0 0;
		box-shadow: 0 -8px 40px rgba(0, 0, 0, 0.25);
		padding-bottom: env(safe-area-inset-bottom);
	}
	@media (min-width: 768px) {
		.panel {
			left: auto;
			right: 24px;
			top: 72px;
			bottom: auto;
			width: 340px;
			max-height: calc(100dvh - 100px);
			border-radius: 14px;
		}
	}
	.head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 14px 16px 8px;
		border-bottom: 0.5px solid var(--separator);
	}
	h3 {
		margin: 0;
		font-size: 17px;
	}
	.close {
		border: none;
		background: none;
		color: var(--accent);
		font: inherit;
		font-weight: 600;
		cursor: pointer;
	}
	.list {
		overflow-y: auto;
		padding: 6px 8px 12px;
	}
	.year {
		display: flex;
		align-items: center;
		gap: 10px;
		width: 100%;
		border: none;
		background: none;
		padding: 10px 8px;
		border-radius: 8px;
		font: inherit;
		color: var(--fg);
		cursor: pointer;
	}
	.year:hover {
		background: var(--bg-elevated);
	}
	.ylabel {
		font-size: 18px;
		font-weight: 700;
	}
	.count {
		color: var(--fg-secondary);
		font-size: 13px;
		font-variant-numeric: tabular-nums;
	}
	.year .count {
		margin-left: auto;
	}
	.chev {
		color: var(--fg-secondary);
		transition: transform 0.15s;
	}
	.year.open .chev {
		transform: rotate(90deg);
	}
	.months {
		display: grid;
		grid-template-columns: repeat(4, 1fr);
		gap: 6px;
		padding: 2px 8px 10px;
	}
	.month {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 2px;
		border: none;
		border-radius: 10px;
		background: var(--bg-elevated);
		padding: 8px 4px;
		font: inherit;
		font-weight: 600;
		color: var(--fg);
		cursor: pointer;
	}
	.month:hover {
		filter: brightness(0.95);
	}
	.month.current {
		background: var(--accent);
		color: white;
	}
	.month.current .count {
		color: rgba(255, 255, 255, 0.85);
	}
</style>
