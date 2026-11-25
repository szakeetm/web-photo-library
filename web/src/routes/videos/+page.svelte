<script lang="ts">
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const videos = $derived(app.assets.filter((a) => a.dur != null));
	const sections = $derived(
		groupByMonth(videos).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title="Videos" subtitle={String(videos.length)}>
	{#snippet actions()}
		{#if videos.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && videos.length === 0}
	<p class="empty muted">Videos in your library show up here.</p>
{:else}
	<PhotoBrowser {sections} {selection} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
