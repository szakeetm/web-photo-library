<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { replaceState } from '$app/navigation';
	import { api, objectName, type ObjectLabel } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import Icon from '#lib/components/Icon.svelte';

	const selection = new Selection();
	let q = $state(page.url.searchParams.get('q') ?? '');
	/** what the server found; shown once the catalog (still loading on a fresh start) has them */
	let found = $state<string[]>([]);
	const ids = $derived(found.filter((i) => app.byId.has(i)));
	let searched = $state(false);
	/** A search is on its way (from the moment the query changes until its results are in). */
	let searching = $state(false);
	let ctrl: AbortController | undefined;
	let input: HTMLInputElement;

	$effect(() => {
		const query = q.trim();
		ctrl?.abort();
		if (!query) {
			found = [];
			searched = false;
			searching = false;
			return;
		}
		searching = true;
		const c = (ctrl = new AbortController());
		const t = setTimeout(async () => {
			try {
				const r = await api.search(query, c.signal);
				found = r.ids;
				// a new search keeps only the selected photos it still shows
				const shown = new Set(r.ids);
				if ([...selection.ids].some((i) => !shown.has(i))) selection.ids = new Set([...selection.ids].filter((i) => shown.has(i)));
				searched = true;
				const url = new URL(location.href);
				url.searchParams.set('q', query);
				replaceState(url, page.state);
				searching = false;
			} catch {
				// aborted by a newer query (which is searching now); otherwise it failed
				if (!c.signal.aborted) searching = false;
			}
		}, 200);
		return () => clearTimeout(t);
	});
	const sections = $derived([{ key: 'results', label: null, items: ids }]);

	// ---- suggestions: what the search can find, from the library itself (most photos first)

	let objects = $state<ObjectLabel[]>([]);
	onMount(() => {
		if (net.online) api.objects().then((l) => (objects = l)).catch(() => {});
	});

	type Kind = 'people' | 'places' | 'objects' | 'albums' | 'folders';
	const kinds: { key: Kind; label: string; icon: string }[] = [
		{ key: 'people', label: 'People', icon: 'people' },
		{ key: 'places', label: 'Places', icon: 'map' },
		{ key: 'objects', label: 'Things', icon: 'tag' },
		{ key: 'albums', label: 'Albums', icon: 'albums' },
		{ key: 'folders', label: 'Folders', icon: 'folder' }
	];

	/** Every suggestion per kind, most photos first, names unique. */
	const all = $derived.by(() => {
		const rank = (m: Map<string, number>) => [...m].sort((a, b) => b[1] - a[1]).map(([n]) => n);
		const add = (m: Map<string, number>, name: string | null | undefined, n: number) => {
			const s = name?.trim();
			if (s) m.set(s, (m.get(s) ?? 0) + n);
		};
		const people = new Map<string, number>();
		for (const p of app.people) if (!p.hidden) add(people, p.name, p.count);
		const perPlace = new Map<number, number>();
		for (const a of app.assets) if (a.pl != null) perPlace.set(a.pl, (perPlace.get(a.pl) ?? 0) + 1);
		const places = new Map<string, number>();
		for (const p of app.places) add(places, p.name, perPlace.get(p.id) ?? 0);
		const things = new Map<string, number>();
		for (const o of objects) add(things, objectName(o.name), o.count);
		const albums = new Map<string, number>();
		for (const a of app.albums) add(albums, a.title, a.assetIds.length);
		const folders = new Map<string, number>();
		for (const f of app.folders) if (f.parentId != null) add(folders, f.name, f.count);
		return { people: rank(people), places: rank(places), objects: rank(things), albums: rank(albums), folders: rank(folders) } as Record<Kind, string[]>;
	});

	/** The word being typed (the search matches the start of words). */
	const last = $derived(/(\S*)$/.exec(q)?.[1].toLowerCase() ?? '');
	const startsWord = (name: string, w: string) => name.toLowerCase().split(/[^\p{L}\p{N}]+/u).some((x) => x.startsWith(w));

	/** Rows to show: examples while empty, completions of the word being typed after that. */
	const rows = $derived(
		kinds
			.map((k) => ({ ...k, items: (last ? all[k.key].filter((n) => startsWord(n, last)) : all[k.key]).slice(0, 12) }))
			.filter((r) => r.items.length && !(last && r.items.length === 1 && r.items[0].toLowerCase() === last))
	);

	function pick(name: string) {
		q = (q.replace(/\S*$/, '') + name).trimStart() + ' ';
		input?.focus();
	}
</script>

<TitleBar title="Search" subtitle={searching ? 'Searching…' : searched ? `${ids.length} ${ids.length === 1 ? 'photo' : 'photos'}` : undefined}>
	{#snippet actions()}
		{#if ids.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>
<div class="box">
	<!-- svelte-ignore a11y_autofocus -->
	<input type="search" placeholder="People, places, things, albums, folders, text in photos" bind:value={q} bind:this={input} autofocus
		autocapitalize="off" spellcheck="false" enterkeyhint="search" />
</div>

{#if !q.trim()}
	<p class="hint muted">
		Every word has to match, and words match from their start: <b>bea</b> finds beach. Combine them:
		<b>{all.people[0] ?? 'Anna'} {all.places[0] ?? 'Paris'}</b>. Text in photos and file names work too (<b>IMG_1234</b>).
	</p>
{/if}
{#if rows.length && !(searched && last === '')}
	<div class="rows" class:compact={!!q.trim()}>
		{#each rows as r (r.key)}
			<div class="row">
				{#if !q.trim()}<div class="label muted">{r.label}</div>{/if}
				<div class="chips">
					{#each r.items as name (name)}
						<button class="chip" onclick={() => pick(name)}><Icon name={r.icon} size={15} />{name}</button>
					{/each}
				</div>
			</div>
		{/each}
	</div>
{/if}

{#if searching}
	<div class="searching muted" role="status" aria-live="polite"><span class="spin"></span>Searching for “{q.trim()}”…</div>
{/if}
{#if searched && ids.length === 0 && !searching}
	<p class="empty muted">No photos match “{q.trim()}”.</p>
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
	.hint {
		margin: 0 14px 14px;
		font-size: 13px;
		line-height: 1.45;
	}
	.hint b {
		font-weight: 600;
		color: var(--fg);
	}
	.rows {
		display: flex;
		flex-direction: column;
		gap: 12px;
		margin-bottom: 14px;
	}
	.rows.compact {
		gap: 6px;
		margin-bottom: 10px;
	}
	.label {
		font-size: 12px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		padding: 0 14px 6px;
	}
	.chips {
		display: flex;
		gap: 8px;
		overflow-x: auto;
		padding: 0 14px;
		scrollbar-width: none;
	}
	.chips::-webkit-scrollbar {
		display: none;
	}
	.chip {
		flex: none;
		display: flex;
		align-items: center;
		gap: 6px;
		border: none;
		border-radius: 999px;
		padding: 6px 12px;
		background: var(--bg-elevated);
		color: inherit;
		font: inherit;
		font-size: 14px;
		white-space: nowrap;
		cursor: pointer;
	}
	.chip :global(svg) {
		opacity: 0.6;
	}
	.chip:hover {
		background: var(--separator);
	}
	.empty {
		text-align: center;
		padding: 60px 20px;
	}
	.searching {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 14px 20px;
		font-size: 14px;
	}
	.spin {
		width: 14px;
		height: 14px;
		border: 2px solid currentColor;
		border-right-color: transparent;
		border-radius: 50%;
		animation: spin 0.8s linear infinite;
	}
	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}
</style>
