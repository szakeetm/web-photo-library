<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { api } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const id = $derived(Number(page.params.id));
	const album = $derived(app.albums.find((a) => a.id === id));
	const items = $derived(album ? album.assetIds.filter((i) => app.byId.has(i)) : []);
	const sections = $derived([{ key: `album-${id}`, label: null, items }]);

	async function rename() {
		if (!album) return;
		const title = prompt('Album name', album.title);
		if (!title?.trim() || title.trim() === album.title) return;
		await api.updateAlbum(album.id, { title: title.trim() });
		await app.reload();
	}
	async function remove() {
		if (!album || !confirm(`Delete the album “${album.title}”?\nThe photos themselves are not deleted.`)) return;
		await api.deleteAlbum(album.id);
		await app.reload();
		goto('/albums');
	}
</script>

<TitleBar title={album?.title ?? 'Album'} subtitle={album ? `${items.length}` : undefined} back="/albums">
	{#snippet actions()}
		{#if album}
			{#if items.length}
				<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
					{selection.active ? 'Cancel' : 'Select'}
				</button>
			{/if}
			<button class="btn" onclick={rename}>Rename</button>
			<button class="btn danger" onclick={remove}>Delete</button>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && !album}
	<p class="empty muted">Album not found.</p>
{:else if album && items.length === 0}
	<p class="empty muted">No photos yet. Select photos in the Library and choose “Add to album”.</p>
{:else}
	<PhotoBrowser {sections} {selection} albumId={id} />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
