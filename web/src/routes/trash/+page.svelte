<script lang="ts">
	// Deleted uploads, restorable until they are deleted for good (by hand or after TRASH_KEEP_DAYS).
	import { onMount } from 'svelte';
	import { TRASH_KEEP_DAYS } from '#lib/api.ts';
	import { app, deleteForever } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	const sections = $derived(app.trash.length ? [{ key: 'trash', label: null, items: app.trash.map((t) => t.asset.id) }] : []);
	let busy = $state(false);

	onMount(() => {
		app.loadTrash();
	});

	async function empty() {
		const n = app.trash.length;
		if (!confirm(`Delete ${n === 1 ? 'this photo' : `all ${n} photos`} permanently? This can't be undone in the app (the files go to the Mac's Trash).`)) return;
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
		{#if app.trash.length}
			<button class="btn danger" onclick={empty} disabled={busy || !net.online}>Empty Trash</button>
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if !net.online}
	<p class="empty muted">The Trash is available when the server can be reached.</p>
{:else if app.trash.length === 0}
	<p class="empty muted">No deleted photos. Deleted uploads are kept here for {TRASH_KEEP_DAYS} days.</p>
{:else}
	<p class="note muted">Deleted uploads are kept here for {TRASH_KEEP_DAYS} days, then deleted for good. Open a photo or select some to restore them.</p>
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
