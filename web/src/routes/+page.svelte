<script lang="ts">
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import UploadButton from '#lib/components/UploadButton.svelte';
	import MultiExportSheet from '#lib/components/MultiExportSheet.svelte';
	import Icon from '#lib/components/Icon.svelte';
	import { net } from '#lib/net.svelte.ts';

	/** Exporting the whole library (desktop only: a phone can't hold it). */
	let exporting = $state(false);
	const desktop = typeof matchMedia !== 'undefined' && !matchMedia('(pointer: coarse)').matches;

	const selection = new Selection();
	// Newest first: the latest month on top, newest photo first within each month.
	const sections = $derived(
		groupByMonth(app.assets.toReversed()).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title="Library" subtitle={app.loaded ? `${app.assets.length.toLocaleString()} photos` : undefined}>
	{#snippet actions()}
		{#if app.local}
			<a class="local-pill" href="/settings" title="This browser runs on the Mac with the library: photos and videos come straight from its disk.">Local mode</a>
		{/if}
		<UploadButton />
		{#if desktop && net.online && app.assets.length}
			<button class="icon-btn" title="Export library…" aria-label="Export library" onclick={() => (exporting = true)}><Icon name="download" /></button>
		{/if}
		{#if app.assets.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && app.assets.length === 0}
	<div class="empty">
		{#if !app.libraryConfigured}
			<p>No photos yet: add a folder or choose an uploads folder.</p>
			<a class="btn primary" href="/settings">Open Settings</a>
		{:else}
			<p class="muted">No photos yet. Run “Detect changes” in Settings.</p>
		{/if}
	</div>
{:else}
	<PhotoBrowser {sections} {selection} />
{/if}

{#if exporting}
	<MultiExportSheet library onClose={() => (exporting = false)} />
{/if}

<style>
	.local-pill {
		align-self: center;
		padding: 3px 9px;
		border-radius: 999px;
		font-size: 12px;
		font-weight: 600;
		color: var(--accent);
		background: color-mix(in srgb, var(--accent) 14%, transparent);
		white-space: nowrap;
	}

	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
