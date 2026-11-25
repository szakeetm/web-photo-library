<script lang="ts">
	import { app } from '#lib/state.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';

	const sections = $derived(
		groupByMonth(app.assets).map((g) => ({ key: g.key, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);
</script>

<header class="titlebar">
	<h1>Library</h1>
	{#if app.loaded}<span class="muted">{app.assets.length.toLocaleString()} photos</span>{/if}
</header>

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
	<PhotoBrowser {sections} startAtEnd />
{/if}

<style>
	.titlebar {
		position: sticky;
		top: 0;
		z-index: 10;
		display: flex;
		align-items: baseline;
		gap: 10px;
		padding: calc(env(safe-area-inset-top) + 10px) 14px 8px;
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
	}
	h1 {
		margin: 0;
		font-size: 24px;
	}
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
