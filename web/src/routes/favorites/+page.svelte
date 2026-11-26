<script lang="ts">
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const favs = $derived(app.index.favorites);
	const sections = $derived(
		groupByMonth(favs).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title="Favourites" subtitle={String(favs.length)}>
	{#snippet actions()}
		{#if favs.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && favs.length === 0}
	<p class="empty muted">Tap ♥ in a photo to add it to your favourites.</p>
{:else}
	<PhotoBrowser {sections} {selection} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
