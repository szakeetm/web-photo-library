<script lang="ts">
	import { inFolders } from '#lib/assetIndex.ts';
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';
	import { api, faceThumbUrl, objectName, thumbUrl, type CatalogAlbum, type DuplicateGroup, type ObjectLabel, type RootName } from '#lib/api.ts';
	import { app, createAlbum } from '#lib/state.svelte.ts';
	import Icon from '#lib/components/Icon.svelte';
	import MultiExportSheet from '#lib/components/MultiExportSheet.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import { pins, pinProgress, pinStatus } from '#lib/pins.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import type { PinRecord } from '#lib/db.ts';

	/** Recognised objects, most common first (the top ones are shown here). */
	let objects = $state<ObjectLabel[]>([]);
	const TOP_OBJECTS = 11;
	/** Duplicate groups (server only). */
	let duplicates = $state<DuplicateGroup[]>([]);
	onMount(() => {
		if (net.online) api.objects().then((l) => (objects = l)).catch(() => {});
		if (net.online) api.duplicates().then((g) => (duplicates = g)).catch(() => {});
	});

	const present = (al: CatalogAlbum) => al.assetIds.filter((i) => app.byId.has(i));
	const albums = $derived(app.albums.slice().sort((a, b) => a.title.localeCompare(b.title)));
	const libraryRoot = $derived(app.folders.find((f) => f.root === 'library' && f.relPath === ''));
	const uploadsRoot = $derived(app.folders.find((f) => f.root === 'uploads' && f.relPath === ''));
	/** Top folders of library sources on rclone remotes (named after the source). */
	const remoteRoots = $derived(
		app.folders
			.filter((f) => f.relPath === '' && f.root !== 'library' && f.root !== 'uploads')
			.sort((a, b) => a.name.localeCompare(b.name))
	);
	const firstIn = (root: RootName) =>
		app.folders.find((f) => f.root === root && f.coverId)?.coverId ?? null;
	const rootCount = (root: RootName) => {
		const ids = new Set(app.folders.filter((f) => f.root === root).map((f) => f.id));
		return inFolders(app.index, ids).length;
	};
	/** Face of the person with the most photos, as the People cover. */
	const topFace = $derived(app.people.find((p) => !p.hidden && p.name && p.coverFaceId != null)?.coverFaceId);
	const favCover = $derived(app.index.favorites.at(-1)?.id ?? null);
	const editedCover = $derived(app.index.edited.at(-1)?.id ?? null);
	const videoCount = $derived(app.index.videos.length);
	const videoCover = $derived(app.index.videos.at(-1)?.id ?? null);
	const liveCount = $derived(app.index.live.length);
	const liveCover = $derived(app.index.live.at(-1)?.id ?? null);
	const mediaKinds = $derived([
		{ key: 'selfies', title: 'Selfies', list: app.index.selfies },
		{ key: 'portraits', title: 'Portraits', list: app.index.portraits },
		{ key: 'screenshots', title: 'Screenshots', list: app.index.screenshots }
	]);

	// Selecting albums to export several at once (desktop: a phone shares one album at a time).
	const desktop = typeof matchMedia !== 'undefined' && !matchMedia('(pointer: coarse)').matches;
	let selecting = $state(false);
	let picking = $state(new Set<number>());
	let exportingAlbums = $state(false);
	function togglePick(id: number) {
		const next = new Set(picking);
		if (next.has(id)) next.delete(id);
		else next.add(id);
		picking = next;
	}
	function stopPicking() {
		selecting = false;
		picking = new Set();
	}

	async function newAlbum() {
		const title = prompt('New album name');
		if (!title?.trim()) return;
		const al = await createAlbum(title.trim());
		goto(`/albums/${al.id}`);
	}
</script>

{#snippet card(href: string, title: string, count: number, cover: string | null, icon: string, image: string | null = null, pin: PinRecord | undefined = undefined, albumId: number | undefined = undefined)}
	{@const ca = cover ? app.byId.get(cover) : undefined}
	{@const picked = albumId != null && picking.has(albumId)}
	<a
		class="card"
		class:dimmed={selecting && albumId == null}
		class:picked
		{href}
		aria-current={picked ? 'true' : undefined}
		onclick={(e) => {
			if (!selecting) return;
			e.preventDefault();
			if (albumId != null) togglePick(albumId);
		}}
	>
		<div class="cover">
			{#if image}<img src={image} alt="" loading="lazy" />{:else if ca}<img src={thumbUrl(ca.id, ca.ev, app.fmt)} alt="" loading="lazy" />{:else}<Icon name={icon} size={40} />{/if}
		</div>
		<div class="name">{title}</div>
		<div class="count muted">
			{count.toLocaleString()}
			{#if pin}<span class="dl" title={pinStatus(pin, net.online)}
					>· {pin.state === 'done' ? 'Downloaded' : `${Math.floor(pinProgress(pin) * 100)}%`}</span
				>{/if}
		</div>
	</a>
{/snippet}

<TitleBar title="Collections" subtitle={selecting ? `${picking.size} ${picking.size === 1 ? 'album' : 'albums'} selected` : undefined}>
	{#snippet actions()}
		{#if desktop && albums.length && net.online}
			<button class="btn" onclick={() => (selecting ? stopPicking() : (selecting = true))}>{selecting ? 'Cancel' : 'Select'}</button>
		{/if}
		{#if selecting}
			<button class="btn primary" disabled={!picking.size} onclick={() => (exportingAlbums = true)}>Export…</button>
		{:else}
			<button class="btn" onclick={newAlbum}>New Album</button>
		{/if}
	{/snippet}
</TitleBar>
{#if exportingAlbums}
	<MultiExportSheet albums={[...picking]} onClose={() => { exportingAlbums = false; stopPicking(); }} />
{/if}

<h2 class="section">Albums</h2>
<div class="cards">
	{@render card('/favorites', 'Favourites', app.index.favorites.length, favCover, 'heart')}
	{@render card('/edited', 'Edited', app.index.edited.length, editedCover, 'edit')}
	{#each albums as al (al.id)}
		{@const p = present(al)}
		{@render card(`/albums/${al.id}`, al.title, p.length, al.coverId && app.byId.has(al.coverId) ? al.coverId : (p[0] ?? null), 'albums', null, pins.records[al.id], al.id)}
	{/each}
</div>

{#if videoCount || liveCount || duplicates.length || mediaKinds.some((k) => k.list.length)}
	<h2 class="section">Media Types</h2>
	<div class="cards">
		{#if videoCount}{@render card('/videos', 'Videos', videoCount, videoCover, 'video')}{/if}
		{#if liveCount}{@render card('/live', 'Live Photos', liveCount, liveCover, 'live')}{/if}
		{#each mediaKinds as k (k.key)}
			{#if k.list.length}{@render card(`/media/${k.key}`, k.title, k.list.length, k.list.at(-1)?.id ?? null, 'photos')}{/if}
		{/each}
		{#if duplicates.length}{@render card('/duplicates', 'Duplicates', duplicates.length, duplicates[0].items[0]?.id ?? null, 'photos')}{/if}
	</div>
{/if}

{#if objects.length}
	<h2 class="section">Objects</h2>
	<div class="cards">
		{#each objects.slice(0, TOP_OBJECTS) as o (o.id)}
			{@render card(`/objects/${o.id}`, objectName(o.name), o.count, o.coverId && app.byId.has(o.coverId) ? o.coverId : null, 'search')}
		{/each}
		{#if objects.length > TOP_OBJECTS}
			{@render card('/objects', 'All Objects', objects.length, null, 'albums')}
		{/if}
	</div>
{/if}

<h2 class="section">People & Places</h2>
<div class="cards">
	{@render card('/people', 'People', app.people.filter((p) => !p.hidden && p.name).length, null, 'people', topFace != null ? faceThumbUrl(topFace) : null)}
	{@render card('/places', 'Places', app.places.length, app.index.located.at(-1)?.id ?? null, 'map')}
</div>

<h2 class="section">Folders</h2>
<div class="cards">
	{#if libraryRoot}{@render card('/folders', 'Library folders', rootCount('library'), firstIn('library'), 'folder', null, pins.folderPin(libraryRoot))}{/if}
	{#each remoteRoots as r (r.id)}
		{@render card(`/sources/${r.root}`, r.name || 'Source', rootCount(r.root), firstIn(r.root), r.root.startsWith('photos-') ? 'photos' : 'folder', null, pins.folderPin(r))}
	{/each}
	{#if uploadsRoot}
		{@render card('/uploads', 'Uploads', rootCount('uploads'), firstIn('uploads'), 'upload', null, pins.folderPin(uploadsRoot))}
	{/if}
	{#if uploadsRoot || app.trash.length}
		{@const t = app.trash[0]?.asset}
		{@render card('/trash', 'Trash', app.trash.length, null, 'trash', t ? thumbUrl(t.id, t.ev, app.fmt) : null)}
	{/if}
</div>

<style>

	.dl {
		color: var(--accent);
	}
	.section {
		font-size: 19px;
		margin: 14px 14px 8px;
	}
	.cards {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 18px 14px;
		padding: 4px 14px 16px;
	}
	@media (max-width: 500px) {
		.cards {
			grid-template-columns: repeat(2, 1fr);
		}
	}
	.card {
		color: var(--fg);
		min-width: 0;
	}
	.card.dimmed {
		opacity: 0.35;
		pointer-events: none;
	}
	.card.picked .cover {
		outline: 3px solid var(--accent);
		outline-offset: 2px;
	}
	.cover {
		aspect-ratio: 1;
		border-radius: 10px;
		overflow: hidden;
		background: var(--bg-elevated);
		display: flex;
		align-items: center;
		justify-content: center;
		color: var(--fg-secondary);
	}
	.cover img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}
	.name {
		margin-top: 6px;
		font-weight: 500;
		font-size: 14px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.count {
		font-size: 13px;
	}
</style>
