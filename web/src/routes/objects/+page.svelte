<script lang="ts">
	// Everything recognised in the library (Vision's classifier on the Mac), most common first.
	import { onMount } from 'svelte';
	import { api, objectName, thumbUrl, type ObjectLabel } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import TitleBar from '#lib/components/TitleBar.svelte';

	let labels = $state<ObjectLabel[] | null>(null);
	onMount(() => {
		api.objects().then((l) => (labels = l)).catch(() => (labels = []));
	});
</script>

<TitleBar title="Objects" subtitle={labels ? String(labels.length) : undefined} back="/albums" />

{#if !net.online}
	<p class="empty muted">Objects are available when the server can be reached.</p>
{:else if labels && labels.length === 0}
	<p class="empty muted">Nothing recognised yet. Settings → Objects → Find objects looks through the library.</p>
{:else if labels}
	<div class="cards">
		{#each labels as l (l.id)}
			{@const c = l.coverId ? app.byId.get(l.coverId) : undefined}
			<a class="card" href="/objects/{l.id}">
				<div class="cover">{#if c}<img src={thumbUrl(c.id, c.ev, app.fmt)} alt="" loading="lazy" />{/if}</div>
				<div class="name">{objectName(l.name)}</div>
				<div class="count muted">{l.count.toLocaleString()}</div>
			</a>
		{/each}
	</div>
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
	.cards {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(130px, 1fr));
		gap: 16px 12px;
		padding: 8px 14px 24px;
	}
	.card {
		color: inherit;
	}
	.cover {
		aspect-ratio: 1;
		border-radius: 10px;
		overflow: hidden;
		background: var(--bg-elevated);
	}
	.cover img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}
	.name {
		margin-top: 6px;
		font-size: 14px;
		font-weight: 500;
	}
	.count {
		font-size: 12px;
	}
</style>
