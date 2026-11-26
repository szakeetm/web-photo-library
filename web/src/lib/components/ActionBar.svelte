<script lang="ts">
	// Bottom bar for a multi-photo selection.
	import { app, setFavorite, rotatePhotos, addToAlbum, createAlbum, removeFromAlbum, restoreFromTrash, deleteForever } from '#lib/state.svelte.ts';
	import { deleteFlow, deleteKey, deleteQuestion } from '#lib/deleteFlow.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { nextFavoriteValue, SELECT_ALL_MAX, selectAllRefused, type Selection } from '#lib/selection.svelte.ts';
	import { hint } from '#lib/hint.svelte.ts';
	import AlbumPicker from './AlbumPicker.svelte';
	import MultiExportSheet from './MultiExportSheet.svelte';
	import AdjustDateSheet from './AdjustDateSheet.svelte';
	import Icon from './Icon.svelte';
	import { page } from '$app/state';

	let {
		selection,
		order,
		albumId,
		trash = false,
		hidden = false
	}: {
		selection: Selection;
		order: string[];
		albumId?: number;
		trash?: boolean;
		/** one photo selected on a desktop: no bar, only its keys (⌫, L/R) */
		hidden?: boolean;
	} = $props();
	let picking = $state(false);
	let dating = $state(false);
	let busy = $state(false);
	const ids = $derived([...selection.ids]);
	/** Uploads are moved to the Trash; other photos are only hidden there (their files stay where they are). */
	const allUploads = $derived(ids.length > 0 && ids.every((i) => app.isUpload(i)));
	/** Videos can't be rotated here (only photos). */
	const hasPhotos = $derived(ids.some((i) => app.byId.get(i)?.dur == null));
	const favNext = $derived(nextFavoriteValue(ids.map((i) => app.byId.get(i)?.fav ?? false)));

	/** Above this many photos, a batch action that changes them asks first (a select all, then rotate or
	 *  delete by mistake). Adding to an album asks from ALBUM_MANY on. Downloads and the date sheet (which
	 *  shows what it will change) never ask. */
	const MANY = 100;
	const ALBUM_MANY = 500;
	/** True to go ahead: `what` is the action ("Rotate left"), asked only for more than `limit` photos. */
	function okForMany(what: string, limit = MANY) {
		const n = ids.length;
		if (n <= limit) return true;
		return confirm(`${what} ${n.toLocaleString()} photos?\n\nThat's more than ${limit}: check you meant to select them all.`);
	}

	function rotate(clockwise: boolean) {
		if (!okForMany(clockwise ? 'Rotate right' : 'Rotate left')) return;
		run(() => rotatePhotos(ids, clockwise));
	}

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

	// L / R rotate the selected photos (not while the viewer, a sheet or a text field has the keys).
	$effect(() => {
		const onKey = (e: KeyboardEvent) => {
			// Backspace/Delete: delete the selected photos (asking first); with ⌘ or Ctrl at once, with Undo
			const del = deleteKey(e);
			if (del) {
				if (trash || page.state.viewer || picking || dating || downloading || busy || !selection.count || !net.online) return;
				if (document.querySelector('[role=dialog], [role=alertdialog]')) return;
				e.preventDefault();
				remove(del === 'now');
				return;
			}
			const k = e.key.toLowerCase();
			if ((k !== 'l' && k !== 'r') || e.metaKey || e.ctrlKey || e.altKey || trash) return;
			if ((e.target as HTMLElement).closest?.('input, select, textarea') || document.querySelector('[role=dialog]')) return;
			if (page.state.viewer || picking || dating || downloading || busy || !hasPhotos || !net.online) return;
			e.preventDefault();
			rotate(k === 'r');
		};
		window.addEventListener('keydown', onKey);
		return () => window.removeEventListener('keydown', onKey);
	});

	/** The download sheet (originals or edits, Live Photo videos) is open. */
	let downloading = $state(false);
	function download() {
		downloading = true;
	}

	function remove(immediate = false) {
		if (!okForMany('Delete')) return;
		const chosen = [...ids];
		const q = deleteQuestion(chosen, (i) => app.isUpload(i));
		run(async () => {
			const done = await deleteFlow.remove(chosen, q.title, q.message, undefined, immediate);
			if (done) selection.clear();
		});
	}

	function restore() {
		if (!okForMany('Restore')) return;
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

{#if !hidden}
<div class="bar" role="toolbar" aria-label="Selection">
	<button class="btn" onclick={() => selection.clear()}>Done</button>
	<!-- on a phone only the number shows, so every action fits -->
	<span class="count">{#if selection.count}{selection.count}<span class="long">{' '}selected</span>{:else}Select<span class="long">{' '}photos</span>{/if}</span>
	<!-- dimmed (not disabled) in big views: a click says why it doesn't select -->
	<button class="link" class:dim={order.length > SELECT_ALL_MAX} title="Select all"
		onclick={() => (order.length > SELECT_ALL_MAX ? hint.show(selectAllRefused(order.length)) : selection.selectAll(order))}>All</button>
	<div class="actions">
		{#if trash}
		<button class="btn" disabled={!selection.count || busy || !net.online} onclick={restore}>Restore</button>
		<button class="icon-btn danger" disabled={!allTrashUploads || busy || !net.online}
			title={allTrashUploads || !selection.count ? 'Delete permanently' : 'Only uploads can be deleted permanently; other photos can only be restored'}
			aria-label="Delete permanently" onclick={removeForever}><Icon name="trash" /></button>
		{:else}
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title={favNext ? 'Favourite' : 'Unfavourite'}
			aria-label={favNext ? 'Favourite' : 'Unfavourite'}
			onclick={() => okForMany(favNext ? 'Favourite' : 'Unfavourite') && run(() => setFavorite(ids, favNext))}>
			<span class="heart" class:filled={!favNext}><Icon name="heart" /></span>
		</button>
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title="Add to album" aria-label="Add to album"
			onclick={() => (picking = true)}><Icon name="albumAdd" /></button>
		<button class="icon-btn" disabled={!hasPhotos || busy || !net.online} title="Rotate left (L)" aria-label="Rotate left"
			onclick={() => rotate(false)}><Icon name="rotate" /></button>
		<button class="icon-btn" disabled={!hasPhotos || busy || !net.online} title="Rotate right (R)" aria-label="Rotate right"
			onclick={() => rotate(true)}><span class="mirror"><Icon name="rotate" /></span></button>
		<button class="icon-btn" disabled={!selection.count || busy || !net.online} title="Adjust date & time"
			aria-label="Adjust date and time" onclick={() => (dating = true)}><Icon name="clock" /></button>
		{#if albumId != null}
			<button class="icon-btn danger" disabled={!selection.count || busy || !net.online} title="Remove from album" aria-label="Remove from album"
				onclick={() => okForMany('Remove from the album') && run(async () => { await removeFromAlbum(albumId, ids); selection.clear(); })}><Icon name="minus" /></button>
		{/if}
		<button class="icon-btn danger" disabled={!selection.count || busy || !net.online} title="Delete" aria-label="Delete"
			onclick={() => remove()}><Icon name="trash" /></button>
		<button class="icon-btn" disabled={!selection.count || !net.online} title="Export / download" aria-label="Export"
			onclick={download}><Icon name="download" /></button>
		{/if}
	</div>
</div>

{/if}

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
		onPick={(id) => okForMany('Add to the album', ALBUM_MANY) && run(async () => { picking = false; await addToAlbum(id, ids); selection.clear(); })}
		onCreate={(title) => okForMany(`Make the album “${title}” with`, ALBUM_MANY) && run(async () => { picking = false; await createAlbum(title, ids); selection.clear(); })}
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
	.link.dim {
		opacity: 0.35;
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
