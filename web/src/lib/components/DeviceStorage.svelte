<script lang="ts">
	// Settings → This device: what the image cache holds, its size limit, downloaded albums and folders.
	import { onMount } from 'svelte';
	import { clearImages, evictToLimit, getLimit, setLimit, usage, type CacheUsage } from '#lib/imageCache.ts';
	import { pins, pinStatus } from '#lib/pins.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import type { PinRecord } from '#lib/db.ts';
	import { app } from '#lib/state.svelte.ts';

	const LIMITS = [0.5, 1, 2, 5, 10, 20].map((gb) => gb * 1024 ** 3);
	let u = $state<CacheUsage | null>(null);
	let limit = $state(2 * 1024 ** 3);
	let quota = $state<number | null>(null);
	let persisted = $state<boolean | null>(null);
	let busy = $state(false);

	const fmt = (n: number) =>
		n < 1e6 ? `${Math.round(n / 1e3)} KB` : n < 1e9 ? `${(n / 1e6).toFixed(n < 1e8 ? 1 : 0)} MB` : `${(n / 1e9).toFixed(2)} GB`;
	const fmtLimit = (n: number) => (n < 1024 ** 3 ? `${Math.round(n / 1024 ** 2)} MB` : `${n / 1024 ** 3} GB`);

	async function refresh() {
		try {
			[u, limit] = await Promise.all([usage(), getLimit()]);
			const est = await navigator.storage?.estimate?.();
			quota = est?.quota ?? null;
			persisted = (await navigator.storage?.persisted?.()) ?? null;
		} catch {
			u = null;
		}
	}

	onMount(() => {
		refresh();
		const t = setInterval(refresh, 3000);
		return () => clearInterval(t);
	});

	async function changeLimit(e: Event) {
		limit = Number((e.target as HTMLSelectElement).value);
		await setLimit(limit);
		await evictToLimit(limit);
		refresh();
	}

	/** Clears cached photos; downloaded albums stay unless `everything`. */
	async function clear(everything: boolean) {
		const msg = everything
			? 'Remove all photos saved on this device, including downloaded albums and folders?'
			: 'Clear photos cached on this device? Downloaded albums and folders are kept.';
		if (!confirm(msg)) return;
		busy = true;
		try {
			if (everything) for (const id of Object.keys(pins.records)) await pins.remove(Number(id));
			await clearImages(!everything);
		} finally {
			busy = false;
			refresh();
		}
	}

	const downloaded = $derived(Object.values(pins.records));
	const pinHref = (p: PinRecord) =>
		p.folder
			? `/${p.folder.root === 'uploads' ? 'uploads' : 'folders'}/${p.folder.relPath.split('/').filter(Boolean).map(encodeURIComponent).join('/')}`
			: `/albums/${p.albumId}`;
	const pct = $derived(u ? Math.min(100, (u.total / limit) * 100) : 0);
</script>

<div class="row">
	<div class="label">
		<div>Photos saved on this device</div>
		{#if u}
			<div class="meter" role="meter" aria-valuemin={0} aria-valuemax={limit} aria-valuenow={u.total}
				aria-label="Cache used"><div style="width: {pct}%"></div></div>
			<div class="muted small">
				{fmt(u.total)} of {fmtLimit(limit)} · thumbnails {fmt(u.thumbs)} · previews {fmt(u.previews)}
				{#if u.pinned}· downloads {fmt(u.pinned)}{/if}
			</div>
			{#if quota}<div class="muted small">The browser allows this app up to {fmt(quota)}.{persisted === false ? ' Storage may be cleared by the system when space is low.' : ''}</div>{/if}
		{:else}
			<div class="muted small">Not available in this browser window (private mode?).</div>
		{/if}
	</div>
</div>
<div class="row actions">
	<label class="muted small" for="cache-limit">Limit</label>
	<select id="cache-limit" class="select" value={limit} onchange={changeLimit}>
		{#each LIMITS as l (l)}<option value={l}>{fmtLimit(l)}</option>{/each}
	</select>
	<button class="btn" disabled={busy || !u} onclick={() => clear(false)}>Clear cache</button>
	{#if downloaded.length}
		<button class="btn danger" disabled={busy || !u} onclick={() => clear(true)}>Remove everything</button>
	{/if}
</div>
<p class="hint muted">
	Photos you look at are kept here so they open instantly and work offline; the oldest are removed when the limit is
	reached. Downloaded albums and folders are always kept (thumbnails and previews, not full resolution; a folder
	includes its subfolders). Download one from its ⋯ menu.
</p>
{#if downloaded.length}
	<ul class="albums">
		{#each downloaded as p (p.albumId)}
			<li>
				<a href={pinHref(p)}>{p.folder ? '' : (app.albums.find((a) => a.id === p.albumId)?.title ?? p.title)}{#if p.folder}<span class="kind muted">Folder</span> {p.title}{/if}</a>
				<span class="muted small">
					{#if p.state === 'downloading'}{pinStatus(p, net.online)}{:else}{fmt(u?.byAlbum.get(p.albumId) ?? p.bytes)}{/if}
				</span>
				<button class="btn" onclick={() => pins.remove(p.albumId).then(refresh)}>Remove</button>
			</li>
		{/each}
	</ul>
{/if}

<style>
	.meter {
		height: 6px;
		border-radius: 3px;
		background: var(--separator);
		margin: 6px 0 4px;
		overflow: hidden;
	}
	.meter div {
		height: 100%;
		background: var(--accent);
	}
	.select {
		font: inherit;
		padding: 5px 8px;
		border-radius: 8px;
		border: 0.5px solid var(--separator);
		background: var(--bg-elevated);
		color: var(--fg);
	}
	.albums {
		list-style: none;
		padding: 0;
		margin: 6px 0 0;
	}
	.albums li {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 6px 0;
		border-top: 0.5px solid var(--separator);
	}
	.kind {
		font-size: 11px;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		margin-right: 4px;
	}
	.albums a {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
</style>
