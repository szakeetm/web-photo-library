<script lang="ts">
	// Duplicates: photos that are the same picture (copies: re-saved, resized, converted); shots that
	// are only alike (bursts, crops) aren't listed. Keep one: it gets the others' albums and favourite, and the
	// other copies go to the Trash (uploads are moved there; copies in folders, Photos libraries and rclone
	// folders are only hidden — their files are never touched).
	import { onMount } from 'svelte';
	import { api, previewUrl, thumbUrl, type DuplicateGroup, type DuplicateItem } from '#lib/api.ts';
	import { app, deletePhotos } from '#lib/state.svelte.ts';
	import { captureLabel } from '#lib/dates.ts';
	import { formatBytes } from '#lib/video.ts';
	import { net } from '#lib/net.svelte.ts';
	import { LOCAL_FOLDERS } from '#lib/sources.ts';
	import TitleBar from '#lib/components/TitleBar.svelte';

	let groups = $state<DuplicateGroup[] | null>(null);
	let error = $state('');
	let busy = $state<string | null>(null);
	/** Chosen copy per group (default: the largest, then the oldest). */
	let keep = $state<Record<string, string>>({});
	/** Library copies still on disk after keeping one: shown until dismissed. */

	const best = (g: DuplicateGroup) =>
		g.items.slice().sort((a, b) => b.w * b.h - a.w * a.h || b.bytes - a.bytes || (a.t < b.t ? -1 : 1))[0].id;

	async function load() {
		error = '';
		try {
			groups = await api.duplicates();
			for (const g of groups) keep[g.key] ??= best(g);
		} catch (e) {
			error = (e as Error).message;
		}
	}
	onMount(load);

	const visible = $derived((groups ?? []).filter((g) => g.items.some((i) => app.byId.has(i.id))));
	const same = $derived(visible.filter((g) => g.kind === 'same'));

	// Hundreds of groups at once (thousands of thumbnails) ran an iPhone out of memory and the app was
	// restarted: groups are put on the page a batch at a time, as the end of the list comes near.
	const BATCH = 30;
	let shown = $state(BATCH);
	const rendered = $derived(same.slice(0, shown));

	/** Shows the next batch when this element (after the last group) comes within a screen or so. */
	function more(node: HTMLElement) {
		const io = new IntersectionObserver((entries) => {
			if (entries.some((e) => e.isIntersecting)) shown += BATCH;
		}, { rootMargin: '0px 0px 1200px 0px' });
		io.observe(node);
		return { destroy: () => io.disconnect() };
	}

	async function keepOne(g: DuplicateGroup) {
		const kept = keep[g.key] ?? best(g);
		const others = g.items.filter((i) => i.id !== kept);
		busy = g.key;
		try {
			await api.mergeDuplicates(kept, others.map((i) => i.id));
			await deletePhotos(others.map((i) => i.id));
			await api.dismissDuplicates(g.key);
			groups = (groups ?? []).filter((x) => x.key !== g.key);
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = null;
		}
	}

	async function notDuplicates(g: DuplicateGroup) {
		busy = g.key;
		try {
			await api.dismissDuplicates(g.key);
			groups = (groups ?? []).filter((x) => x.key !== g.key);
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = null;
		}
	}

	const format = (mime: string) => (mime.split('.').pop() ?? mime).toUpperCase().replace('JPEG', 'JPG');

	/** Where a copy is: Upload, Local folders, or the source's name. */
	function sourceName(root: string) {
		if (root === 'uploads') return 'Upload';
		if (root === 'library') return LOCAL_FOLDERS;
		return app.folders.find((f) => f.root === root && f.relPath === '')?.name || 'Source';
	}
	// ---- full screen: the copies of one group side by side, swiped through (arrows on desktop)
	let comparing = $state<{ g: DuplicateGroup; i: number } | null>(null);
	let strip = $state<HTMLDivElement>();
	function openCompare(g: DuplicateGroup, i: number) {
		comparing = { g, i };
	}
	function startAt(node: HTMLDivElement, i: number) {
		node.scrollLeft = i * node.clientWidth;
	}
	function onStrip() {
		if (!comparing || !strip) return;
		const i = Math.round(strip.scrollLeft / Math.max(1, strip.clientWidth));
		if (i !== comparing.i) comparing = { ...comparing, i };
	}
	function step(d: number) {
		if (!comparing || !strip) return;
		const i = Math.max(0, Math.min(comparing.g.items.length - 1, comparing.i + d));
		strip.scrollTo({ left: i * strip.clientWidth, behavior: 'smooth' });
	}
	function onKey(e: KeyboardEvent) {
		if (!comparing) return;
		if (e.key === 'Escape') comparing = null;
		else if (e.key === 'ArrowRight') step(1);
		else if (e.key === 'ArrowLeft') step(-1);
		else return;
		e.preventDefault();
	}
	const details = (it: DuplicateItem) => `${it.w} × ${it.h} · ${formatBytes(it.bytes)} · ${format(it.mime)}`;

	// On the phone Duplicates is a Collections tab: no way "back".
	const phone = typeof matchMedia !== 'undefined' && matchMedia('(max-width: 767px)').matches;
</script>

<TitleBar title="Duplicates" subtitle={groups ? `${visible.length} ${visible.length === 1 ? 'group' : 'groups'}` : undefined} back={phone ? undefined : '/albums'} />

{#if !net.online}
	<p class="empty muted">Duplicates need the server: you're offline.</p>
{:else if error}
	<p class="empty error">{error}</p>
{:else if groups == null}
	<p class="empty muted">Looking for duplicates…</p>
{:else if visible.length === 0}
	<p class="empty muted">No duplicates found. Photos are compared after “Analyse photos” (Settings) has run.</p>
{:else}
	{#snippet group(g: DuplicateGroup)}
		<section class="group">
			<div class="ghead muted">
				{captureLabel(g.items[0].t, g.items[0].tz)} · {g.items.length} copies
			</div>
			<div class="items">
				{#each g.items as it, i (it.id)}
					{@const a = app.byId.get(it.id)}
					{@const kept = keep[g.key] === it.id}
					<div class="item" class:kept>
						<button class="thumb" onclick={() => openCompare(g, i)} aria-label="Show full screen">
							{#if a}<img src={thumbUrl(a.id, a.ev, app.fmt)} alt="" loading="lazy" />{/if}
							{#if it.fav}<span class="fav" title="Favourite">♥</span>{/if}
						</button>
						<button class="pick" aria-pressed={kept} onclick={() => (keep[g.key] = it.id)}>
							<span class="dot"></span>{kept ? 'Keep' : 'Keep this'}
						</button>
						<div class="meta">
							<div><b>{it.w}×{it.h}</b> · {formatBytes(it.bytes)}</div>
							<div class="muted">
								{format(it.mime)} · <span class="root">{sourceName(it.root)}</span>{#if it.albums}{` · ${it.albums} ${it.albums === 1 ? 'album' : 'albums'}`}{/if}
							</div>
						</div>
					</div>
				{/each}
			</div>
			<div class="actions">
				<button class="btn" disabled={busy === g.key} onclick={() => notDuplicates(g)}>Not Duplicates</button>
				<button class="btn primary" disabled={busy === g.key} onclick={() => keepOne(g)}>Keep Selected</button>
			</div>
		</section>
	{/snippet}

	<p class="intro muted">
		Keep one photo of each group: it gets the others' albums and favourite, and the other copies go to the Trash. Uploads
		are deleted from disk when the Trash is emptied; copies in folders, Photos libraries and pCloud are only hidden here.
	</p>
	{#each rendered as g (g.key)}{@render group(g)}{/each}
	{#if rendered.length < same.length}
		<!-- re-created after each batch, so the observer fires again if it's still in view -->
		{#key shown}<div class="more muted" use:more>Showing {rendered.length} of {same.length} groups…</div>{/key}
	{/if}
{/if}

<svelte:window onkeydown={onKey} />
{#if comparing}
	{@const g = comparing.g}
	{@const it = g.items[comparing.i]}
	<div class="compare" role="dialog" aria-modal="true" aria-label="Copies of this photo">
		<div class="cbar">
			<span>{comparing.i + 1} of {g.items.length}</span>
			<button class="cclose" onclick={() => (comparing = null)} aria-label="Close">✕</button>
		</div>
		<div class="strip" bind:this={strip} use:startAt={comparing.i} onscroll={onStrip}>
			{#each g.items as c (c.id)}
				{@const a = app.byId.get(c.id)}
				<div class="slide">{#if a}<img src={previewUrl(a.id, a.ev, app.fmt)} alt="" />{/if}</div>
			{/each}
		</div>
		{#if g.items.length > 1}
			<button class="nav prev" disabled={comparing.i === 0} onclick={() => step(-1)} aria-label="Previous copy">‹</button>
			<button class="nav next" disabled={comparing.i === g.items.length - 1} onclick={() => step(1)} aria-label="Next copy">›</button>
		{/if}
		<div class="cinfo">
			<div><b>{details(it)}</b>{#if it.fav} · ♥{/if}</div>
			<div class="muted">{captureLabel(it.t, it.tz)}</div>
			<div class="muted cpath"><span class="root">{sourceName(it.root)}</span> {it.path}</div>
			{#if it.albums}<div class="muted">In {it.albums} {it.albums === 1 ? 'album' : 'albums'}</div>{/if}
			<button class="btn primary keep" disabled={keep[g.key] === it.id} onclick={() => (keep[g.key] = it.id)}>
				{keep[g.key] === it.id ? 'Kept ✓' : 'Keep This One'}
			</button>
		</div>
	</div>
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
	.error {
		color: var(--danger);
	}
	.intro {
		margin: 4px 16px 8px;
		font-size: 13px;
	}
	.group {
		margin: 0 12px 14px;
		padding: 10px;
		border-radius: 12px;
		background: var(--bg-elevated);
		/* groups off screen aren't laid out or painted */
		content-visibility: auto;
		contain-intrinsic-size: auto 300px;
	}
	.more {
		text-align: center;
		padding: 16px 0 32px;
		font-size: 13px;
	}
	.ghead {
		font-size: 12px;
		margin: 0 2px 8px;
	}
	/* two side by side on a phone, more on wider screens */
	.items {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
		gap: 10px;
	}
	.item {
		min-width: 0;
		font-size: 12px;
	}
	.thumb {
		position: relative;
		display: block;
		width: 100%;
		padding: 0;
		border: 2px solid transparent;
		border-radius: 10px;
		overflow: hidden;
		background: var(--bg);
		cursor: zoom-in;
	}
	.item.kept .thumb {
		border-color: var(--accent);
	}
	.thumb img {
		display: block;
		width: 100%;
		aspect-ratio: 1;
		object-fit: cover;
	}
	.fav {
		position: absolute;
		left: 6px;
		bottom: 4px;
		color: white;
		text-shadow: 0 0 3px rgba(0, 0, 0, 0.7);
	}
	.pick {
		display: flex;
		align-items: center;
		gap: 6px;
		margin: 6px 0 2px;
		padding: 2px 0;
		border: none;
		background: none;
		color: inherit;
		font: inherit;
		font-weight: 600;
		cursor: pointer;
	}
	.dot {
		width: 14px;
		height: 14px;
		border-radius: 50%;
		border: 2px solid var(--fg-secondary);
		flex: none;
	}
	.pick[aria-pressed='true'] {
		color: var(--accent);
	}
	.pick[aria-pressed='true'] .dot {
		border-color: var(--accent);
		background: radial-gradient(var(--accent) 45%, transparent 50%);
	}
	.meta {
		display: flex;
		flex-direction: column;
		gap: 1px;
	}
	.meta > div {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.root {
		font-weight: 600;
		color: var(--accent);
	}
	.compare {
		position: fixed;
		inset: 0;
		z-index: 300;
		background: #000;
		color: #fff;
		display: flex;
		flex-direction: column;
	}
	.cbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: calc(env(safe-area-inset-top) + 8px) 14px 8px;
		font-size: 14px;
	}
	.cclose {
		border: none;
		background: rgba(255, 255, 255, 0.15);
		color: #fff;
		width: 32px;
		height: 32px;
		border-radius: 50%;
		font-size: 15px;
		cursor: pointer;
	}
	.strip {
		flex: 1;
		min-height: 0;
		display: flex;
		overflow-x: auto;
		scroll-snap-type: x mandatory;
		scrollbar-width: none;
	}
	.strip::-webkit-scrollbar {
		display: none;
	}
	.slide {
		flex: 0 0 100%;
		scroll-snap-align: center;
		display: flex;
		align-items: center;
		justify-content: center;
	}
	.slide img {
		max-width: 100%;
		max-height: 100%;
		object-fit: contain;
	}
	.nav {
		position: absolute;
		top: 50%;
		transform: translateY(-50%);
		border: none;
		background: rgba(255, 255, 255, 0.15);
		color: #fff;
		width: 40px;
		height: 40px;
		border-radius: 50%;
		font-size: 26px;
		line-height: 1;
		cursor: pointer;
	}
	.nav:disabled {
		opacity: 0.25;
	}
	.nav.prev {
		left: 10px;
	}
	.nav.next {
		right: 10px;
	}
	.cinfo {
		padding: 10px 16px calc(env(safe-area-inset-bottom) + 14px);
		font-size: 13px;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}
	.cinfo .muted {
		color: rgba(255, 255, 255, 0.65);
	}
	.cpath {
		overflow-wrap: anywhere;
	}
	.keep {
		margin-top: 8px;
		width: 100%;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 8px;
	}
</style>
