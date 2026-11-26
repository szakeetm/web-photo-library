<script lang="ts">
	import { reveal } from '#lib/reveal.ts';
	// Deleted uploads, restorable until they are deleted for good (by hand or after TRASH_KEEP_DAYS).
	import { onMount } from 'svelte';
	import { TRASH_KEEP_DAYS } from '#lib/api.ts';
	import { app, deleteForever } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import Icon from '#lib/components/Icon.svelte';

	const selection = new Selection();
	const sections = $derived(app.trash.length ? [{ key: 'trash', label: null, items: app.trash.map((t) => t.asset.id) }] : []);
	let busy = $state(false);

	onMount(() => {
		app.loadTrash();
	});

	async function empty() {
		const n = app.trash.length;
		const uploads = app.trash.filter((t) => !t.virtual).length;
		const hidden = n - uploads;
		const parts = [
			uploads && `${uploads === 1 ? 'The upload is' : `${uploads} uploads are`} deleted from disk`,
			hidden && `${hidden === 1 ? 'the other photo stays' : `${hidden} other photos stay`} hidden for good (${hidden === 1 ? 'its file is' : 'their files are'} not touched)`
		].filter(Boolean);
		if (!confirm(`Delete ${n === 1 ? 'this photo' : `all ${n} photos`} permanently? ${parts.join('; ')}. This can't be undone.`)) return;
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
