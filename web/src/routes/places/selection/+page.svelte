<script lang="ts">
	// Photos of one map pin.
	import { app } from '#lib/state.svelte.ts';
	import { mapPick } from '#lib/places.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const picked = $derived(new Set(mapPick.ids));
	const photos = $derived(app.assets.filter((a) => picked.has(a.id)));
	const names = $derived([...new Set(photos.map((a) => (a.pl != null ? app.placeById.get(a.pl)?.name : undefined)).filter(Boolean))]);
	const sections = $derived(
		groupByMonth(photos).map((g) => ({ key: `sel-${g.key}`, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title={names.length === 1 ? names[0]! : names.length ? `${names[0]} and nearby` : 'Photos'} subtitle={String(photos.length)} back="/places" />
{#if photos.length === 0}
	<p class="empty muted">Choose a place on the <a href="/places">map</a>.</p>
{:else}
	<PhotoBrowser {sections} {selection} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
