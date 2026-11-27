<script lang="ts">
	import { page } from '$app/state';
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const id = $derived(Number(page.params.id));
	const place = $derived(app.placeById.get(id));
	const photos = $derived(app.index.byPlace.get(id) ?? []);
	const sections = $derived(
		groupByMonth(photos).map((g) => ({ key: `${id}-${g.key}`, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
	$effect(() => {
		void id;
		selection.clear();
	});
</script>

<TitleBar title={place?.name ?? 'Place'} subtitle={place ? `${[place.region, place.country].filter(Boolean).join(', ')} · ${photos.length}` : undefined} back="/places">
	{#snippet actions()}
		{#if photos.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>{selection.active ? 'Cancel' : 'Select'}</button>
		{/if}
	{/snippet}
</TitleBar>
{#if app.loaded && !place}
	<p class="empty muted">No photos here any more.</p>
{:else}
	<PhotoBrowser {sections} {selection} order={{ initial: 'newest' }} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
