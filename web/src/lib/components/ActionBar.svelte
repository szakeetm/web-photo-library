<script lang="ts">
	// Bottom bar for a multi-photo selection.
	import { TRASH_KEEP_DAYS } from '#lib/api.ts';
	import { app, setFavorite, addToAlbum, createAlbum, removeFromAlbum, deleteUploads, restoreFromTrash, deleteForever } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { nextFavoriteValue, type Selection } from '#lib/selection.svelte.ts';
	import AlbumPicker from './AlbumPicker.svelte';
	import MultiExportSheet from './MultiExportSheet.svelte';
	import AdjustDateSheet from './AdjustDateSheet.svelte';
	import Icon from './Icon.svelte';

	let {
		selection,
		order,
		albumId,
		trash = false
	}: { selection: Selection; order: string[]; albumId?: number; trash?: boolean } = $props();
	let picking = $state(false);
	let dating = $state(false);
	let busy = $state(false);
	const ids = $derived([...selection.ids]);
	/** Only uploads can be deleted: the button shows when every selected photo is one. */
	const allUploads = $derived(ids.length > 0 && ids.every((i) => app.isUpload(i)));
	const favNext = $derived(nextFavoriteValue(ids.map((i) => app.byId.get(i)?.fav ?? false)));

	async function run(work: () => Promise<unknown>) {
		busy = true;
		try {
			await work();
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = false;
		}
	}

	/** The download sheet (originals or edits, Live Photo videos) is open. */
	let downloading = $state(false);
	function download() {
		downloading = true;
	}

	function remove() {
		const n = ids.length;
		if (!confirm(`Delete ${n === 1 ? 'this uploaded photo' : `${n} uploaded photos`}? ${n === 1 ? 'It stays' : 'They stay'} in Trash (in Collections) for ${TRASH_KEEP_DAYS} days.`)) return;
		run(async () => {
			await deleteUploads(ids);
			selection.clear();
		});
	}

	function restore() {
		run(async () => {
			await restoreFromTrash(ids);
			selection.clear();
		});
	}

	function removeForever() {
		const n = ids.length;
		if (!confirm(`Delete ${n === 1 ? 'this photo' : `${n} photos`} permanently? The files are deleted from disk; this can't be undone.`)) return;
		run(async () => {
			await deleteForever(ids);
			selection.clear();
		});
	}
</script>

<div class="bar" role="toolbar" aria-label="Selection">
	<button class="btn" onclick={() => selection.clear()}>Done</button>
	<span class="count">{selection.count ? `${selection.count} selected` : 'Select photos'}</span>
	<button class="link" onclick={() => selection.selectAll(order)}>All</button>
	<div class="actions">
		{#if trash}
		<button class="btn" disabled={!selection.count || busy || !net.online} onclick={restore}>Restore</button>
		<button class="icon-btn danger" disabled={!selection.count || busy || !net.online} title="Delete permanently"
			aria-label="Delete permanently" onclick={removeForever}><Icon name="trash" /></button>
		{:else}
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title={favNext ? 'Favourite' : 'Unfavourite'}
			aria-label={favNext ? 'Favourite' : 'Unfavourite'}
			onclick={() => run(() => setFavorite(ids, favNext))}>
			<span class="heart" class:filled={!favNext}><Icon name="heart" /></span>
		</button>
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title="Add to album" aria-label="Add to album"
			onclick={() => (picking = true)}><Icon name="albumAdd" /></button>
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title="Adjust date & time"
			aria-label="Adjust date and time" onclick={() => (dating = true)}><Icon name="clock" /></button>
		{#if albumId != null}
			<button class="icon-btn danger" disabled={!selection.count || busy || !net.online} title="Remove from album" aria-label="Remove from album"
				onclick={() => run(async () => { await removeFromAlbum(albumId, ids); selection.clear(); })}><Icon name="minus" /></button>
		{/if}
		{#if allUploads}
			<button class="icon-btn danger" disabled={busy || !net.online} title="Delete uploads" aria-label="Delete uploads"
				onclick={remove}><Icon name="trash" /></button>
		{/if}
		<button class="icon-btn" disabled={!selection.count || !net.online} title="Export / download" aria-label="Export"
			onclick={download}><Icon name="download" /></button>
		{/if}
	</div>
</div>

{#if downloading}
	<MultiExportSheet {ids} onClose={() => (downloading = false)} />
{/if}

{#if dating}
	<AdjustDateSheet {ids} onClose={() => (dating = false)} />
{/if}

{#if picking}
	<AlbumPicker
		count={selection.count}
		onCancel={() => (picking = false)}
		onPick={(id) => run(async () => { picking = false; await addToAlbum(id, ids); selection.clear(); })}
		onCreate={(title) => run(async () => { picking = false; await createAlbum(title, ids); selection.clear(); })}
	/>
{/if}

<style>
	.bar {
		position: fixed;
		z-index: 30;
		left: 0;
		right: 0;
		bottom: 0;
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 8px 12px calc(8px + env(safe-area-inset-bottom));
		/* solid: it replaces the tab bar while selecting */
		background: var(--bg-elevated);
		border-top: 0.5px solid var(--separator);
		min-height: calc(var(--tabbar-h) + env(safe-area-inset-bottom));
	}
	@media (min-width: 768px) {
		.bar {
			left: var(--sidebar-w);
		}
	}
	.count {
		font-weight: 600;
		font-size: 14px;
	}
	.link {
		border: none;
		background: none;
		color: var(--accent);
		cursor: pointer;
		padding: 4px;
	}
	.actions {
		margin-left: auto;
		display: flex;
		gap: 2px;
	}
	.icon-btn:disabled {
		opacity: 0.35;
	}
	.danger {
		color: var(--danger);
	}
	.heart.filled :global(path) {
		fill: currentColor;
	}
</style>
