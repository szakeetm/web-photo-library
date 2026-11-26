<script lang="ts">
	// Jump to a month: every year (newest first) as a calendar of its 12 months with photo counts;
	// months without photos are greyed out. Opens at the month being looked at.
	import { onMount } from 'svelte';
	import { yearGroups, type MonthMark } from '#lib/timeline.ts';

	let { marks, current, onPick, onClose }: { marks: MonthMark[]; current: MonthMark | null; onPick: (m: MonthMark) => void; onClose: () => void } =
		$props();

	const years = $derived(
		yearGroups(marks).map((y) => ({ ...y, all: Array.from({ length: 12 }, (_, i) => ({ month: i + 1, mark: y.months.find((m) => m.month === i + 1) })) }))
	);
	const short = (m: { month: number }) => new Date(Date.UTC(2000, m.month - 1, 1)).toLocaleDateString(undefined, { month: 'short', timeZone: 'UTC' });

	let panel: HTMLDivElement;
	onMount(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') {
				e.stopPropagation();
				onClose();
			}
		};
		window.addEventListener('keydown', onKey, true);
		const cur = panel.querySelector<HTMLElement>('.month.current') ?? panel.querySelector<HTMLElement>('.month:not(:disabled)');
		cur?.scrollIntoView({ block: 'center' });
		cur?.focus({ preventScroll: true });
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
			<section class="year">
				<h4><span class="ylabel">{y.year}</span><span class="count">{y.count.toLocaleString()}</span></h4>
				<div class="months">
					{#each y.all as m (m.month)}
						<button
							class="month"
							class:current={m.mark != null && current?.key === m.mark.key}
							disabled={!m.mark}
							onclick={() => m.mark && onPick(m.mark)}
						>
							<span>{short(m)}</span>
							<span class="count">{m.mark ? m.mark.count.toLocaleString() : '–'}</span>
						</button>
					{/each}
				</div>
			</section>
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
		max-height: 85dvh;
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
	.year h4 {
		position: sticky;
		top: 0;
		z-index: 1;
		display: flex;
		align-items: baseline;
		gap: 10px;
		margin: 0;
		padding: 10px 8px 6px;
		background: var(--bg);
	}
	.ylabel {
		font-size: 20px;
		font-weight: 700;
	}
	.count {
		color: var(--fg-secondary);
		font-size: 13px;
		font-weight: 400;
		font-variant-numeric: tabular-nums;
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
	.month:hover:not(:disabled) {
		filter: brightness(0.95);
	}
	.month:disabled {
		background: none;
		color: var(--fg-secondary);
		opacity: 0.45;
		cursor: default;
	}
	.month.current {
		background: var(--accent);
		color: white;
	}
	.month.current .count {
		color: rgba(255, 255, 255, 0.85);
	}
</style>
