<script lang="ts">
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	// Archived photos: not in the Library, still in albums, folders, search and the other collections.
	const selection = new Selection();
	const archived = $derived(app.index.archived);
	const sections = $derived(
		groupByMonth(archived.toReversed()).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title="Archive" subtitle={String(archived.length)}>
	{#snippet actions()}
		{#if archived.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && archived.length === 0}
	<p class="empty muted">
		Archive photos to keep them out of the Library. They stay in their albums and folders, and search still finds them.
	</p>
{:else}
	<PhotoBrowser {sections} {selection} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
		max-width: 520px;
		margin: 0 auto;
	}
</style>
