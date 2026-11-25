<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { api } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { confirmDownload, pins, pinStatus } from '#lib/pins.svelte.ts';
	import DownloadBar from '#lib/components/DownloadBar.svelte';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import Icon from '#lib/components/Icon.svelte';

	let menu = $state(false);

	const selection = new Selection();
	const id = $derived(Number(page.params.id));
	// SvelteKit reuses this page between albums: never carry a selection over.
	$effect(() => {
		void id;
		selection.clear();
		menu = false;
	});
	const album = $derived(app.albums.find((a) => a.id === id));
	const items = $derived(album ? album.assetIds.filter((i) => app.byId.has(i)) : []);
	const sections = $derived([{ key: `album-${id}`, label: null, items }]);
	const pin = $derived(pins.records[id]);

	async function toggleDownload() {
		if (!album) return;
		if (pin) {
			if (confirm(`Remove the downloaded copy of “${album.title}” from this device?\nThe album stays on the server.`)) await pins.remove(album.id);
		} else if (confirmDownload(album.title, items.length)) {
			await pins.download(album);
		}
	}

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

<TitleBar
	title={album?.title ?? 'Album'}
	subtitle={album ? `${items.length}` + (pin ? ` · ${pinStatus(pin, net.online)}` : '') : undefined}
	back="/albums"
>
	{#snippet actions()}
		{#if album}
			{#if items.length}
				<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
					{selection.active ? 'Cancel' : 'Select'}
				</button>
			{/if}
			<div class="menuwrap">
				<button class="icon-btn" aria-label="More" aria-expanded={menu} onclick={() => (menu = !menu)}><Icon name="more" /></button>
				{#if menu}
					<div class="menu" role="menu">
						<button role="menuitem" disabled={!pin && !net.online} onclick={() => { menu = false; toggleDownload(); }}
							>{pin ? 'Remove Download' : 'Download to This Device'}</button>
						<button role="menuitem" disabled={!net.online} onclick={() => { menu = false; rename(); }}>Rename</button>
						<button role="menuitem" class="danger" disabled={!net.online} onclick={() => { menu = false; remove(); }}>Delete Album</button>
					</div>
				{/if}
			</div>
		{/if}
	{/snippet}
</TitleBar>

<DownloadBar {pin} />

{#if app.loaded && !album}
	<p class="empty muted">Album not found.</p>
{:else if album && items.length === 0}
	<p class="empty muted">No photos yet. Select photos in the Library and choose “Add to album”.</p>
{:else}
	<PhotoBrowser {sections} {selection} albumId={id} />
{/if}

<style>
	.menuwrap {
		position: relative;
	}
	.menu {
		position: absolute;
		right: 0;
		top: 36px;
		min-width: 170px;
		background: var(--bg);
		border-radius: 10px;
		box-shadow: 0 8px 30px rgba(0, 0, 0, 0.2);
		border: 0.5px solid var(--separator);
		padding: 4px;
		z-index: 40;
	}
	.menu button {
		display: block;
		width: 100%;
		text-align: left;
		border: none;
		background: none;
		padding: 9px 12px;
		border-radius: 7px;
		cursor: pointer;
	}
	.menu button:hover {
		background: var(--bg-elevated);
	}
	.menu button:disabled {
		opacity: 0.4;
	}
	.menu .danger {
		color: var(--danger);
	}
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
