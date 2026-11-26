<script lang="ts">
	// Selfies, Portraits and Screenshots (recognised when the library is scanned).
	import { page } from '$app/state';
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const KINDS = {
		selfies: { title: 'Selfies', empty: 'Photos taken with the front camera show up here.' },
		portraits: { title: 'Portraits', empty: 'iPhone Portrait mode photos show up here.' },
		screenshots: { title: 'Screenshots', empty: 'Screenshots show up here.' }
	} as const;
	type Kind = keyof typeof KINDS;

	const selection = new Selection();
	const kind = $derived((page.params.kind ?? '') in KINDS ? (page.params.kind as Kind) : 'screenshots');
	const items = $derived(app.index[kind]);
	// newest first, like the Library
	const sections = $derived(
		groupByMonth(items.toReversed()).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
	$effect(() => {
		void kind;
		selection.clear();
	});
</script>

<TitleBar title={KINDS[kind].title} subtitle={String(items.length)} back="/albums">
	{#snippet actions()}
		{#if items.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && items.length === 0}
	<p class="empty muted">{KINDS[kind].empty}</p>
{:else}
	<PhotoBrowser {sections} {selection} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
