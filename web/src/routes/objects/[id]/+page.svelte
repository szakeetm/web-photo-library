<script lang="ts">
	// The photos and videos showing one recognised object.
	import { page } from '$app/state';
	import { api, objectName } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const id = $derived(Number(page.params.id));
	let name = $state('');
	let ids = $state<string[] | null>(null);
	let error = $state('');

	$effect(() => {
		const current = id;
		ids = null;
		error = '';
		api.objectAssets(current)
			.then((r) => {
				if (current !== id) return;
				name = objectName(r.label.name);
				ids = r.ids;
			})
			.catch((e) => (error = (e as Error).message));
	});

	// in library order (oldest first, like the other collections), grouped by month
	const photos = $derived(
		ids ? ids.map((i) => app.byId.get(i)).filter((a) => a != null).sort((x, y) => app.index.pos.get(x.id)! - app.index.pos.get(y.id)!) : []
	);
	const sections = $derived(
		groupByMonth(photos).map((g) => ({ key: `${id}-${g.key}`, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title={name || 'Object'} subtitle={ids ? String(photos.length) : undefined} back="/objects">
	{#snippet actions()}
		{#if photos.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if error}
	<p class="empty muted">{error}</p>
{:else if ids}
	<PhotoBrowser {sections} {selection} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
