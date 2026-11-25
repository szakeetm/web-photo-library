<script lang="ts">
	import '../app.css';
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page, updated } from '$app/state';
	import Icon from '#lib/components/Icon.svelte';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { pins } from '#lib/pins.svelte.ts';
	import { applyUpdate, registerServiceWorker } from '#lib/sw.ts';
	import { uploads } from '#lib/uploadsInstance.svelte.ts';
	import DropZone from '#lib/components/DropZone.svelte';
	import UploadSheet from '#lib/components/UploadSheet.svelte';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	const tabs = [
		{ href: '/', label: 'Library', icon: 'photos' },
		{ href: '/albums', label: 'Collections', icon: 'collections' },
		{ href: '/search', label: 'Search', icon: 'search' },
		{ href: '/settings', label: 'Settings', icon: 'settings' }
	];
	// Albums, favourites, folders, uploads, people and places all live under Collections on the phone.
	const albumsSection = ['/albums', '/favorites', '/edited', '/videos', '/live', '/folders', '/uploads', '/people', '/places', '/trash'];
	const active = (href: string) =>
		href === '/'
			? page.url.pathname === '/'
			: href === '/albums'
				? albumsSection.some((p) => page.url.pathname.startsWith(p))
				: page.url.pathname.startsWith(href);
	const exact = (href: string) => page.url.pathname === href || page.url.pathname.startsWith(href + '/');
	const sidebarAlbums = $derived(app.albums.slice().sort((a, b) => a.title.localeCompare(b.title)));

	let updating = $state(false);

	onMount(async () => {
		registerServiceWorker();
		await app.init();
		pins.start();
		uploads.resume();
		if (!app.libraryConfigured && !page.url.pathname.startsWith('/settings')) goto('/settings');
	});
</script>


{#if app.updateRequired || updated.current}
	<div class="update" role="alertdialog" aria-modal="true" aria-labelledby="update-title">
		<div class="update-card">
			<h2 id="update-title">Update required</h2>
			<p class="muted">A new version of Photos is installed on the server. Update to continue.</p>
			<button class="btn primary" disabled={updating} onclick={() => { updating = true; applyUpdate(); }}
				>{updating ? 'Updating…' : 'Update now'}</button>
		</div>
	</div>
{/if}

<DropZone />
<UploadSheet />

<div class="shell">
	<nav class="sidebar" aria-label="Sections">
		<div class="brand">Photos</div>
		<a href="/" class:active={page.url.pathname === '/'}><Icon name="photos" size={20} /> Library</a>
		<a href="/favorites" class:active={exact('/favorites')}><Icon name="heart" size={20} /> Favourites</a>
		<a href="/edited" class:active={exact('/edited')}><Icon name="edit" size={20} /> Edited</a>
		<a href="/videos" class:active={exact('/videos')}><Icon name="video" size={20} /> Videos</a>
		<a href="/live" class:active={exact('/live')}><Icon name="live" size={20} /> Live Photos</a>
		<a href="/folders" class:active={exact('/folders')}><Icon name="folder" size={20} /> Folders</a>
		{#if app.uploadsConfigured}
			<a href="/uploads" class:active={exact('/uploads')}><Icon name="upload" size={20} /> Uploads</a>
		{/if}
		<a href="/people" class:active={exact('/people')}><Icon name="people" size={20} /> People</a>
		<a href="/places" class:active={exact('/places')}><Icon name="map" size={20} /> Places</a>
		<a href="/search" class:active={exact('/search')}><Icon name="search" size={20} /> Search</a>
		{#if app.trash.length}
			<a href="/trash" class:active={exact('/trash')}><Icon name="trash" size={20} /> Trash</a>
		{/if}
		<div class="group"><a class="grouplink" href="/albums">Albums</a></div>
		<div class="albumlist">
			{#each sidebarAlbums as al (al.id)}
				<a href="/albums/{al.id}" class:active={page.url.pathname === `/albums/${al.id}`}><Icon name="albums" size={18} /> <span>{al.title}</span></a>
			{/each}
		</div>
		<a class="bottom" href="/settings" class:active={exact('/settings')}><Icon name="settings" size={20} /> Settings</a>
	</nav>
	<main>
		{#if !net.online}
			<div class="banner offline" role="status">
				Offline — showing what's saved on this device. Editing, favourites and albums are paused.
			</div>
		{:else if app.error}
			<div class="banner">Can't reach the server: {app.error}</div>
		{/if}
		{@render children()}
	</main>
	<nav class="tabbar" aria-label="Sections">
		{#each tabs as t (t.href)}
			<a href={t.href} class:active={active(t.href)}><Icon name={t.icon} size={24} /><span>{t.label}</span></a>
		{/each}
	</nav>
</div>

<style>
	.shell {
		min-height: 100dvh;
	}
	main {
		min-height: 100dvh;
		padding-bottom: calc(var(--tabbar-h) + env(safe-area-inset-bottom));
	}
	.sidebar {
		display: none;
	}
	.tabbar {
		position: fixed;
		z-index: 20;
		left: 0;
		right: 0;
		bottom: 0;
		height: calc(var(--tabbar-h) + env(safe-area-inset-bottom));
		padding-bottom: env(safe-area-inset-bottom);
		display: flex;
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
		border-top: 0.5px solid var(--separator);
	}
	.tabbar a {
		flex: 1;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 2px;
		font-size: 10px;
		color: var(--fg-secondary);
	}
	.tabbar a.active {
		color: var(--accent);
	}
	.update {
		position: fixed;
		inset: 0;
		z-index: 1000;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 24px;
		background: rgba(0, 0, 0, 0.45);
		backdrop-filter: blur(8px);
		-webkit-backdrop-filter: blur(8px);
	}
	.update-card {
		background: var(--bg);
		border-radius: 14px;
		padding: 22px;
		max-width: 340px;
		text-align: center;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
	}
	.update-card h2 {
		margin: 0 0 8px;
		font-size: 18px;
	}
	.banner {
		background: #ff9f0a;
		color: black;
		padding: 8px 16px;
		font-size: 13px;
	}
	.banner.offline {
		position: sticky;
		top: 0;
		z-index: 25;
		background: var(--bg-elevated);
		color: var(--fg-secondary);
		border-bottom: 0.5px solid var(--separator);
		padding-top: calc(8px + env(safe-area-inset-top));
	}
	@media (min-width: 768px) {
		.tabbar {
			display: none;
		}
		main {
			margin-left: var(--sidebar-w);
			padding-bottom: 0;
		}
		.sidebar {
			display: flex;
			flex-direction: column;
			gap: 2px;
			position: fixed;
			top: 0;
			bottom: 0;
			left: 0;
			width: var(--sidebar-w);
			padding: 16px 10px;
			background: var(--bg-elevated);
			border-right: 0.5px solid var(--separator);
		}
		.brand {
			font-weight: 700;
			font-size: 20px;
			padding: 6px 10px 14px;
		}
		.sidebar a {
			display: flex;
			align-items: center;
			gap: 10px;
			padding: 7px 10px;
			border-radius: 8px;
			color: var(--fg);
		}
		.sidebar a :global(svg) {
			color: var(--accent);
		}
		.sidebar a.active {
			background: rgba(127, 127, 127, 0.18);
		}
		.sidebar a span {
			white-space: nowrap;
			overflow: hidden;
			text-overflow: ellipsis;
		}
		.group {
			margin: 14px 10px 2px;
			font-size: 12px;
			font-weight: 600;
			color: var(--fg-secondary);
		}
		.sidebar .grouplink {
			padding: 0;
			color: inherit;
		}
		.albumlist {
			overflow: auto;
			flex: 1;
			min-height: 0;
		}
		.bottom {
			margin-top: 8px;
		}
	}
</style>
