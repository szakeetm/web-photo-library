<script lang="ts">
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import UploadButton from '#lib/components/UploadButton.svelte';
	import Icon from '#lib/components/Icon.svelte';

	const selection = new Selection();
	const sections = $derived(
		groupByMonth(app.assets).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<TitleBar title="Library" subtitle={app.loaded ? `${app.assets.length.toLocaleString()} photos` : undefined}>
	{#snippet actions()}
		<UploadButton />
		{#if app.assets.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
		<a class="icon-btn settings-link" href="/settings" aria-label="Settings" title="Settings"><Icon name="settings" /></a>
	{/snippet}
</TitleBar>

{#if app.loaded && app.assets.length === 0}
	<div class="empty">
		{#if !app.libraryConfigured}
			<p>No library folder yet.</p>
			<a class="btn primary" href="/settings">Choose library folder</a>
		{:else}
			<p class="muted">No photos yet. Run “Detect changes” in Settings.</p>
		{/if}
	</div>
{:else}
	<PhotoBrowser {sections} {selection} startAtEnd />
{/if}

<style>
	.settings-link {
		display: inline-flex;
	}
	@media (min-width: 768px) {
		.settings-link {
			display: none;
		}
	}
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
