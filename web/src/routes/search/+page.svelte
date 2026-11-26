<script lang="ts">
	import { page } from '$app/state';
	import { replaceState } from '$app/navigation';
	import { api } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	const selection = new Selection();
	let q = $state(page.url.searchParams.get('q') ?? '');
	let ids = $state<string[]>([]);
	let searched = $state(false);
	let ctrl: AbortController | undefined;

	$effect(() => {
		const query = q.trim();
		ctrl?.abort();
		if (!query) {
			ids = [];
			searched = false;
			return;
		}
		const c = (ctrl = new AbortController());
		const t = setTimeout(async () => {
			try {
				const r = await api.search(query, c.signal);
				ids = r.ids.filter((i) => app.byId.has(i));
				searched = true;
				const url = new URL(location.href);
				url.searchParams.set('q', query);
				replaceState(url, page.state);
			} catch {
				/* aborted */
			}
		}, 200);
		return () => clearTimeout(t);
	});
	const sections = $derived([{ key: 'results', label: null, items: ids }]);
</script>

<TitleBar title="Search" subtitle={searched ? `${ids.length} ${ids.length === 1 ? 'photo' : 'photos'}` : undefined} />
<div class="box">
	<!-- svelte-ignore a11y_autofocus -->
	<input type="search" placeholder="Places, people, things, text in photos, file names" bind:value={q} autofocus
		autocapitalize="off" spellcheck="false" enterkeyhint="search" />
</div>
{#if searched && ids.length === 0}
	<p class="empty muted">No photos match “{q}”.</p>
{:else if ids.length}
	<PhotoBrowser {sections} {selection} />
{/if}

<style>
	.box {
		padding: 4px 14px 12px;
	}
	input {
		width: 100%;
		border: none;
		background: var(--bg-elevated);
		border-radius: 10px;
		padding: 10px 12px;
		font: inherit;
		font-size: 16px;
		color: inherit;
	}
	.empty {
		text-align: center;
		padding: 60px 20px;
	}
</style>
