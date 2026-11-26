<script lang="ts">
	import { page } from '$app/state';
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const cc = $derived(page.params.cc ?? '');
	const ids = $derived(new Set(app.places.filter((p) => p.cc === cc).map((p) => p.id)));
	const country = $derived(app.places.find((p) => p.cc === cc)?.country ?? cc);
	const photos = $derived([...ids].flatMap((p) => app.index.byPlace.get(p) ?? []).sort((x, y) => app.index.pos.get(x.id)! - app.index.pos.get(y.id)!));
	const sections = $derived(
		groupByMonth(photos).map((g) => ({ key: `${cc}-${g.key}`, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title={country} subtitle={String(photos.length)} back="/places">
	{#snippet actions()}
		{#if photos.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>{selection.active ? 'Cancel' : 'Select'}</button>
		{/if}
	{/snippet}
</TitleBar>
<PhotoBrowser {sections} {selection} />
