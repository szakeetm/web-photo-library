<script lang="ts">
	import { reveal } from '#lib/reveal.ts';
	// The Trash, in two parts: deleted uploads (restorable, or deleted from disk by hand — nothing is deleted on
	// its own), and hidden photos from the other sources, by source (restorable only: their files are never touched).
	import { onMount } from 'svelte';
	import { isPhotosRoot } from '#lib/api.ts';
	import { LOCAL_FOLDERS } from '#lib/sources.ts';
	import { app, deleteForever } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import Icon from '#lib/components/Icon.svelte';

	const selection = new Selection();
	/** The source a hidden photo comes from (its first folder's source). */
	function sourceOf(folderIds: number[]) {
		const f = app.folders.find((x) => x.id === folderIds[0]);
		if (!f) return 'Other';
		if (f.root === 'library') return LOCAL_FOLDERS;
		const top = app.folders.find((x) => x.root === f.root && x.relPath === '');
		return (top?.name || (isPhotosRoot(f.root) ? 'Photos library' : 'Source')) as string;
	}
	const uploads = $derived(app.trash.filter((t) => !t.virtual));
	const hiddenBySource = $derived.by(() => {
		const m = new Map<string, string[]>();
		for (const t of app.trash.filter((x) => x.virtual)) {
			const k = sourceOf(t.asset.folders);
			m.set(k, [...(m.get(k) ?? []), t.asset.id]);
		}
		return [...m.entries()].sort((a, b) => a[0].localeCompare(b[0]));
	});
	const sections = $derived([
		...(uploads.length
			? [{ key: 'uploads', label: `Uploads · ${uploads.length} · can be deleted permanently`, items: uploads.map((t) => t.asset.id) }]
			: []),
		...hiddenBySource.map(([name, items]) => ({
			key: `hidden:${name}`,
			label: `${name} · ${items.length} hidden · files untouched, restore only`,
			items
		}))
	]);
	let busy = $state(false);

	onMount(() => {
		app.loadTrash();
	});

	/** Deleted uploads (only they can be deleted for good; the rest are only hidden). */
	const uploadCount = $derived(app.trash.filter((t) => !t.virtual).length);

	async function empty() {
		const hidden = app.trash.length - uploadCount;
		const rest = hidden ? ` ${hidden === 1 ? 'The hidden photo stays' : `The ${hidden} hidden photos stay`} in the Trash (restore ${hidden === 1 ? 'it' : 'them'} any time).` : '';
		if (!confirm(`Delete ${uploadCount === 1 ? 'the upload' : `the ${uploadCount} uploads`} in the Trash permanently? ${uploadCount === 1 ? 'Its file is' : 'Their files are'} deleted from disk; this can't be undone.${rest}`)) return;
		busy = true;
		try {
			await deleteForever();
			selection.clear();
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = false;
		}
	}
</script>

<TitleBar title="Trash" subtitle={String(app.trash.length)}>
	{#snippet actions()}
		{#if app.local}
			<button class="icon-btn" onclick={() => reveal({ place: 'trash' })} title="Reveal in Finder" aria-label="Reveal in Finder"
				><Icon name="finder" /></button>
		{/if}
		{#if app.trash.length}
			<button class="btn danger" onclick={empty} disabled={busy || !net.online || !uploadCount}
				title={uploadCount ? '' : 'Only uploads can be deleted; hidden photos can only be restored'}>Delete Uploads Permanently</button>
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if !net.online}
	<p class="empty muted">The Trash is available when the server can be reached.</p>
{:else if app.trash.length === 0}
	<p class="empty muted">No deleted photos.</p>
{:else}
	<p class="note muted">
		Nothing here is deleted on its own. <strong>Uploads</strong> can be restored, or deleted from disk with Delete Uploads
		Permanently. Photos from <strong>local folders, Photos libraries and pCloud</strong> are only hidden: their files are never
		touched, and they stay here until you restore them. Open a photo or select some to restore them.
	</p>
	<PhotoBrowser {sections} {selection} trash />
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
	.note {
		margin: 4px 16px 8px;
		font-size: 13px;
	}
</style>
