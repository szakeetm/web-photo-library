<script lang="ts">
	import { page } from '$app/state';
	import { replaceState } from '$app/navigation';
	import { api } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import Icon from '#lib/components/Icon.svelte';
	import { folderHref } from '#lib/sources.ts';

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

	type Kind = 'people' | 'places' | 'albums' | 'folders';
	const kinds: { key: Kind; label: string; icon: string }[] = [
		{ key: 'people', label: 'People', icon: 'people' },
		{ key: 'places', label: 'Places', icon: 'map' },
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
		const places = new Map<string, number>();
		for (const p of app.places) add(places, p.name, perPlace.get(p.id) ?? 0);
		const albums = new Map<string, number>();
		for (const a of app.albums) add(albums, a.title, a.assetIds.length);
		const folders = new Map<string, number>();
		for (const f of app.folders) if (f.parentId != null) add(folders, f.name, f.count);
		return { people: rank(people), places: rank(places), albums: rank(albums), folders: rank(folders) } as Record<Kind, string[]>;
	});

	/** Photos per place. */
	const perPlace = $derived.by(() => {
		const m = new Map<number, number>();
		for (const a of app.assets) if (a.pl != null) m.set(a.pl, (m.get(a.pl) ?? 0) + 1);
		return m;
	});

	/** Where a chip goes: the person's, place's, album's or folder's own page (the one with the most
	 *  photos when several share the name). */
	const pages = $derived.by(() => {
		const out: Partial<Record<Kind, Map<string, { href: string; n: number }>>> = {};
		const add = (k: Kind, name: string | null | undefined, href: string, n: number) => {
			const s = name?.trim();
			if (!s) return;
			const m = (out[k] ??= new Map());
			const had = m.get(s);
			if (!had || n > had.n) m.set(s, { href, n });
		};
		for (const p of app.people) if (!p.hidden) add('people', p.name, `/people/${p.id}`, p.count);
		for (const p of app.places) add('places', p.name, `/places/${p.id}`, perPlace.get(p.id) ?? 0);
		for (const a of app.albums) add('albums', a.title, `/albums/${a.id}`, a.assetIds.length);
		for (const f of app.folders) if (f.parentId != null) add('folders', f.name, folderHref(f.root, f.relPath), f.count);
		return out;
	});

	const startsWord = (name: string, w: string) => name.toLowerCase().split(/[^\p{L}\p{N}]+/u).some((x) => x.startsWith(w));

	const typing = $derived(!!q.trim());
	/** Every word typed (a name matches when each starts one of its words, like the search). */
	const words = $derived(q.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean));
	/** Chips shown per kind while typing, until its "+N more" is tapped. */
	const FIRST = 8;
	let expanded = $state<Set<Kind>>(new Set());
	$effect(() => {
		void q;
		expanded = new Set();
	});

	/** Rows to show: examples while empty; while typing, the people, places, albums and folders matching
	 *  every word, each kind a section of its own (what's searched for most: they open their pages). */
	const rows = $derived(
		kinds
			.map((k) => {
				const matching = typing ? all[k.key].filter((n) => words.every((w) => startsWord(n, w))) : all[k.key];
				const limit = typing ? (expanded.has(k.key) ? Infinity : FIRST) : 12;
				return { ...k, total: matching.length, items: matching.slice(0, limit) };
			})
			.filter((r) => r.items.length)
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
	<input type="search" placeholder="People, places, albums, folders, text in photos" bind:value={q} bind:this={input} autofocus
		autocapitalize="off" spellcheck="false" enterkeyhint="search" />
</div>

{#if !q.trim()}
	<p class="hint muted">
		Every word has to match, and words match from their start: <b>bea</b> finds beach. Combine them:
		<b>{all.people[0] ?? 'Anna'} {all.places[0] ?? 'Paris'}</b>. Text in photos and file names work too (<b>IMG_1234</b>).
	</p>
{/if}
{#if rows.length}
	<div class="rows" class:typing>
		{#each rows as r (r.key)}
			<div class="row">
				<div class="label muted">{r.label}{#if typing}{` · ${r.total}`}{/if}</div>
				<div class="chips">
					{#each r.items as name (name)}
						{@const to = pages[r.key]?.get(name)}
						{#if to}
							<a class="chip" href={to.href}><Icon name={r.icon} size={15} /><span class="name">{name}</span></a>
						{:else}
							<button class="chip" onclick={() => pick(name)}><Icon name={r.icon} size={15} /><span class="name">{name}</span></button>
						{/if}
					{/each}
					{#if typing && r.items.length < r.total}
						<button class="chip more" onclick={() => (expanded = new Set([...expanded, r.key]))}>+{r.total - r.items.length} more</button>
					{/if}
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
	{#if typing && rows.length}<div class="label muted photos">Photos · {ids.length}</div>{/if}
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
	/* while typing: the matches wrap onto as many lines as they need, long names cut short */
	.rows.typing .chips {
		flex-wrap: wrap;
		overflow-x: visible;
	}
	.rows.typing .chip {
		max-width: 100%;
	}
	.rows.typing .chip > :global(svg) {
		flex: none;
	}
	.chip .name {
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.chip.more {
		color: var(--accent);
	}
	.label.photos {
		padding-top: 2px;
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
		text-decoration: none;
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
