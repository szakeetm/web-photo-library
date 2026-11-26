<script lang="ts">
	// Bottom bar for a multi-photo selection.
	import { app, setFavorite, rotatePhotos, addToAlbum, createAlbum, removeFromAlbum, restoreFromTrash, deleteForever } from '#lib/state.svelte.ts';
	import { deleteFlow } from '#lib/deleteFlow.svelte.ts';
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
	/** Uploads are moved to the Trash; other photos are only hidden there (their files stay where they are). */
	const allUploads = $derived(ids.length > 0 && ids.every((i) => app.isUpload(i)));
	/** Videos can't be rotated here (only photos). */
	const hasPhotos = $derived(ids.some((i) => app.byId.get(i)?.dur == null));
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
		const uploads = ids.filter((i) => app.isUpload(i)).length;
		const others = n - uploads;
		const parts = [
			uploads &&
				`${uploads === 1 ? 'The upload stays' : `${uploads} uploads stay`} in the Trash until you delete ${uploads === 1 ? 'it' : 'them'} there (then ${uploads === 1 ? "it's" : "they're"} deleted from disk).`,
			others &&
				`${others === 1 ? 'The other photo is' : `${others} photos are`} only hidden: ${others === 1 ? 'its file stays' : 'their files stay'} where they are (local folders, Photos libraries, pCloud…) and can be restored from the Trash any time.`
		].filter(Boolean);
		const chosen = [...ids];
		run(async () => {
			const done = await deleteFlow.remove(chosen, `Delete ${n === 1 ? 'this photo' : `${n} photos`}?`, parts.join('\n\n'));
			if (done) selection.clear();
		});
	}

	function restore() {
		run(async () => {
			await restoreFromTrash(ids);
			selection.clear();
		});
	}

	/** In the Trash, only uploads can be deleted for good (other photos are only hidden). */
	const allTrashUploads = $derived(ids.length > 0 && ids.every((i) => app.trash.find((t) => t.asset.id === i)?.virtual === false));
	function removeForever() {
		const n = ids.length;
		if (!confirm(`Delete ${n === 1 ? 'this upload' : `${n} uploads`} permanently? The files are deleted from disk; this can't be undone.`)) return;
		run(async () => {
			await deleteForever(ids);
			selection.clear();
		});
	}
</script>

<div class="bar" role="toolbar" aria-label="Selection">
	<button class="btn" onclick={() => selection.clear()}>Done</button>
	<!-- on a phone only the number shows, so every action fits -->
	<span class="count">{#if selection.count}{selection.count}<span class="long"> selected</span>{:else}Select<span class="long"> photos</span>{/if}</span>
	<button class="link" onclick={() => selection.selectAll(order)}>All</button>
	<div class="actions">
		{#if trash}
		<button class="btn" disabled={!selection.count || busy || !net.online} onclick={restore}>Restore</button>
		<button class="icon-btn danger" disabled={!allTrashUploads || busy || !net.online}
			title={allTrashUploads || !selection.count ? 'Delete permanently' : 'Only uploads can be deleted permanently; other photos can only be restored'}
			aria-label="Delete permanently" onclick={removeForever}><Icon name="trash" /></button>
		{:else}
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title={favNext ? 'Favourite' : 'Unfavourite'}
			aria-label={favNext ? 'Favourite' : 'Unfavourite'}
			onclick={() => run(() => setFavorite(ids, favNext))}>
			<span class="heart" class:filled={!favNext}><Icon name="heart" /></span>
		</button>
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title="Add to album" aria-label="Add to album"
			onclick={() => (picking = true)}><Icon name="albumAdd" /></button>
		<button class="icon-btn" disabled={!hasPhotos || busy || !net.online} title="Rotate left" aria-label="Rotate left"
			onclick={() => run(() => rotatePhotos(ids, false))}><Icon name="rotate" /></button>
		<button class="icon-btn" disabled={!hasPhotos || busy || !net.online} title="Rotate right" aria-label="Rotate right"
			onclick={() => run(() => rotatePhotos(ids, true))}><span class="mirror"><Icon name="rotate" /></span></button>
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title="Adjust date & time"
			aria-label="Adjust date and time" onclick={() => (dating = true)}><Icon name="clock" /></button>
		{#if albumId != null}
			<button class="icon-btn danger" disabled={!selection.count || busy || !net.online} title="Remove from album" aria-label="Remove from album"
				onclick={() => run(async () => { await removeFromAlbum(albumId, ids); selection.clear(); })}><Icon name="minus" /></button>
		{/if}
		<button class="icon-btn danger" disabled={!selection.count || busy || !net.online} title="Delete" aria-label="Delete"
			onclick={remove}><Icon name="trash" /></button>
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
	@media (max-width: 480px) {
		.bar {
			gap: 6px;
		}
		.long {
			display: none;
		}
		.actions .icon-btn {
			width: 30px;
		}
	}
	.icon-btn:disabled {
		opacity: 0.35;
	}
	.danger {
		color: var(--danger);
	}
	/* the rotate icon points counter-clockwise; mirrored it points clockwise */
	.mirror {
		display: inline-flex;
		transform: scaleX(-1);
	}
	.heart.filled :global(path) {
		fill: currentColor;
	}
</style>
