<script lang="ts">
	// The title bar's filter/sort button for the grid on screen (see gridView.svelte.ts).
	import { FILTERS, SORTS, gridView, type ViewFilter, type ViewSort } from '#lib/gridView.svelte.ts';
	import Icon from './Icon.svelte';

	let open = $state(false);
	let root: HTMLElement;

	const sort = $derived(gridView.sort ?? gridView.natural);

	function pickFilter(f: ViewFilter) {
		gridView.set(f, gridView.sort);
		open = false;
	}
	function pickSort(s: ViewSort) {
		gridView.set(gridView.filter, s === gridView.natural ? null : s);
		open = false;
	}

	$effect(() => {
		if (!open) return;
		const away = (e: PointerEvent) => {
			if (!root.contains(e.target as Node)) open = false;
		};
		const esc = (e: KeyboardEvent) => {
			if (e.key === 'Escape') open = false;
		};
		window.addEventListener('pointerdown', away);
		window.addEventListener('keydown', esc);
		return () => {
			window.removeEventListener('pointerdown', away);
			window.removeEventListener('keydown', esc);
		};
	});
</script>

<div class="filter" bind:this={root}>
	<button class="icon-btn" class:active={gridView.active} aria-haspopup="menu" aria-expanded={open}
		title="Filter and sort" aria-label="Filter and sort" onclick={() => (open = !open)}><Icon name="filter" /></button>
	{#if open}
		<div class="menu" role="menu">
			{#if gridView.sortable}
				<div class="group">Sort</div>
				{#each SORTS as s (s.key)}
					<button role="menuitemradio" aria-checked={sort === s.key} onclick={() => pickSort(s.key)}>
						<span class="check">{sort === s.key ? '✓' : ''}</span>{s.label}
					</button>
				{/each}
				<hr />
			{/if}
			<div class="group">Show</div>
			{#each FILTERS as f (f.key)}
				<button role="menuitemradio" aria-checked={gridView.filter === f.key} onclick={() => pickFilter(f.key)}>
					<span class="check">{gridView.filter === f.key ? '✓' : ''}</span>{f.label}
				</button>
			{/each}
		</div>
	{/if}
</div>

<style>
	.filter {
		position: relative;
	}
	.active {
		color: var(--accent);
		background: color-mix(in srgb, var(--accent) 14%, transparent);
		border-radius: 8px;
	}
	.menu {
		position: absolute;
		right: 0;
		top: calc(100% + 6px);
		z-index: 40;
		min-width: 200px;
		max-height: 70dvh;
		overflow: auto;
		padding: 6px;
		background: var(--bg-elevated);
		border: 0.5px solid var(--separator);
		border-radius: 12px;
		box-shadow: 0 10px 30px rgba(0, 0, 0, 0.25);
	}
	.group {
		padding: 4px 10px 2px;
		font-size: 12px;
		font-weight: 600;
		color: var(--text-secondary, gray);
	}
	.menu button {
		display: flex;
		width: 100%;
		align-items: center;
		gap: 6px;
		padding: 7px 10px;
		border: none;
		background: none;
		border-radius: 7px;
		text-align: left;
		font: inherit;
		font-size: 15px;
		color: inherit;
		cursor: pointer;
	}
	.menu button:hover {
		background: color-mix(in srgb, var(--accent) 12%, transparent);
	}
	.check {
		width: 14px;
		color: var(--accent);
	}
	hr {
		border: none;
		border-top: 0.5px solid var(--separator);
		margin: 6px 4px;
	}
</style>
