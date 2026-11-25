<script lang="ts">
	import { goto } from '$app/navigation';
	import { faceThumbUrl, thumbUrl, type CatalogAlbum } from '#lib/api.ts';
	import { app, createAlbum } from '#lib/state.svelte.ts';
	import Icon from '#lib/components/Icon.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import { pins, pinProgress, pinStatus } from '#lib/pins.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import type { PinRecord } from '#lib/db.ts';

	const present = (al: CatalogAlbum) => al.assetIds.filter((i) => app.byId.has(i));
	const albums = $derived(app.albums.slice().sort((a, b) => a.title.localeCompare(b.title)));
	const libraryRoot = $derived(app.folders.find((f) => f.root === 'library' && f.relPath === ''));
	const uploadsRoot = $derived(app.folders.find((f) => f.root === 'uploads' && f.relPath === ''));
	const firstIn = (root: 'library' | 'uploads') =>
		app.folders.find((f) => f.root === root && f.coverId)?.coverId ?? null;
	const rootCount = (root: 'library' | 'uploads') => {
		const ids = new Set(app.folders.filter((f) => f.root === root).map((f) => f.id));
		return app.assets.filter((a) => a.folders.some((f) => ids.has(f))).length;
	};
	/** Face of the person with the most photos, as the People cover. */
	const topFace = $derived(app.people.find((p) => !p.hidden && p.name && p.coverFaceId != null)?.coverFaceId);
	const favCover = $derived(app.assets.findLast((a) => a.fav)?.id ?? null);
	const editedCover = $derived(app.assets.findLast((a) => a.ev > 0)?.id ?? null);

	async function newAlbum() {
		const title = prompt('New album name');
		if (!title?.trim()) return;
		const al = await createAlbum(title.trim());
		goto(`/albums/${al.id}`);
	}
</script>

{#snippet card(href: string, title: string, count: number, cover: string | null, icon: string, image: string | null = null, pin: PinRecord | undefined = undefined)}
	{@const ca = cover ? app.byId.get(cover) : undefined}
	<a class="card" {href}>
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

<TitleBar title="Collections">
	{#snippet actions()}
		<button class="btn" onclick={newAlbum}>New Album</button>
	{/snippet}
</TitleBar>

<h2 class="section">Albums</h2>
<div class="cards">
	{@render card('/favorites', 'Favourites', app.assets.filter((a) => a.fav).length, favCover, 'heart')}
	{@render card('/edited', 'Edited', app.assets.filter((a) => a.ev > 0).length, editedCover, 'edit')}
	{#each albums as al (al.id)}
		{@const p = present(al)}
		{@render card(`/albums/${al.id}`, al.title, p.length, al.coverId && app.byId.has(al.coverId) ? al.coverId : (p[0] ?? null), 'albums', null, pins.records[al.id])}
	{/each}
</div>

<h2 class="section">People & Places</h2>
<div class="cards">
	{@render card('/people', 'People', app.people.filter((p) => !p.hidden && p.name).length, null, 'people', topFace != null ? faceThumbUrl(topFace) : null)}
	{@render card('/places', 'Places', app.places.length, app.assets.findLast((a) => a.pl != null)?.id ?? null, 'map')}
</div>

<h2 class="section">Folders</h2>
<div class="cards">
	{#if libraryRoot}{@render card('/folders', 'Library folders', rootCount('library'), firstIn('library'), 'folder', null, pins.folderPin(libraryRoot))}{/if}
	{#if uploadsRoot}
		{@render card('/uploads', 'Uploads', rootCount('uploads'), firstIn('uploads'), 'upload', null, pins.folderPin(uploadsRoot))}
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
