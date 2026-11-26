<script lang="ts">
	import '../app.css';
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page, updated } from '$app/state';
	import Icon from '#lib/components/Icon.svelte';
	import { app } from '#lib/state.svelte.ts';
	import { gridView, type ViewFilter } from '#lib/gridView.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { pins } from '#lib/pins.svelte.ts';
	import { applyUpdate, registerServiceWorker } from '#lib/sw.ts';
	import { uploads } from '#lib/uploadsInstance.svelte.ts';
	import DropZone from '#lib/components/DropZone.svelte';
	import UploadSheet from '#lib/components/UploadSheet.svelte';
	import DeleteFlow from '#lib/components/DeleteFlow.svelte';
	import LibraryDownload from '#lib/components/LibraryDownload.svelte';
	import ShortcutsSheet from '#lib/components/ShortcutsSheet.svelte';
	import Hint from '#lib/components/Hint.svelte';
	import type { LayoutProps } from './$types';
	import type { FolderNode } from '#lib/api.ts';
	import { isFlat, kindIcon, sources } from '#lib/sources.ts';
	import { sidebarTree } from '#lib/sidebarTree.svelte.ts';
	import SidebarFolder from '#lib/components/SidebarFolder.svelte';

	let { children }: LayoutProps = $props();

	const tabs = [
		{ href: '/', label: 'Library', icon: 'photos' },
		{ href: '/albums', label: 'Collections', icon: 'collections' },
		{ href: '/search', label: 'Search', icon: 'search' },
		{ href: '/settings', label: 'Settings', icon: 'settings' }
	];
	// Albums, favourites, folders, uploads, people and places all live under Collections on the phone.
	const albumsSection = ['/albums', '/favorites', '/edited', '/videos', '/live', '/folders', '/uploads', '/people', '/places', '/trash', '/objects'];
	const active = (href: string) =>
		href === '/'
			? page.url.pathname === '/'
			: href === '/albums'
				? albumsSection.some((p) => page.url.pathname.startsWith(p)) || collectionTab != null
				: page.url.pathname.startsWith(href);
	// On the phone, Collections has its own tabs (a second bar above the main one).
	const collectionTabs = [
		{ href: '/albums', label: 'Albums', icon: 'albums', also: ['/favorites', '/edited', '/videos', '/live', '/media', '/objects'] },
		{ href: '/folders', label: 'Folders', icon: 'folder', also: ['/uploads', '/sources'] },
		{ href: '/people', label: 'People', icon: 'people', also: [] },
		{ href: '/places', label: 'Places', icon: 'map', also: [] },
		{ href: '/duplicates', label: 'Duplicates', icon: 'duplicate', also: [] },
		{ href: '/trash', label: 'Trash', icon: 'trash', also: [] }
	];
	const under = (p: string) => page.url.pathname === p || page.url.pathname.startsWith(p + '/');
	const collectionTab = $derived(collectionTabs.find((t) => [t.href, ...t.also].some(under)));
	const exact = (href: string) => page.url.pathname === href || page.url.pathname.startsWith(href + '/');
	/** Desktop sidebar filters: each shows the Library filtered (media types only when there are any). */
	const filterLinks = $derived(
		[
			{ f: 'favorites' as ViewFilter, label: 'Favourites', icon: 'heart', show: true },
			{ f: 'edited' as ViewFilter, label: 'Edited', icon: 'edit', show: true },
			{ f: 'videos' as ViewFilter, label: 'Videos', icon: 'video', show: true },
			{ f: 'live' as ViewFilter, label: 'Live Photos', icon: 'live', show: true },
			{ f: 'selfies' as ViewFilter, label: 'Selfies', icon: 'photos', show: app.index.selfies.length > 0 },
			{ f: 'portraits' as ViewFilter, label: 'Portraits', icon: 'photos', show: app.index.portraits.length > 0 },
			{ f: 'screenshots' as ViewFilter, label: 'Screenshots', icon: 'photos', show: app.index.screenshots.length > 0 }
		].filter((l) => l.show)
	);
	const onLibrary = $derived(page.url.pathname === '/');
	const libraryFilter = $derived(onLibrary && gridView.enabled ? gridView.filter : 'all');

	/** Shows the Library with this filter (keeping its sort). */
	function showLibrary(f: ViewFilter, e: MouseEvent) {
		if (e.metaKey || e.ctrlKey || e.shiftKey) return; // new tab/window: plain link
		e.preventDefault();
		if (onLibrary && gridView.enabled) return gridView.set(f, gridView.sort);
		let sort = null;
		try {
			sort = JSON.parse(sessionStorage.getItem('view:/') ?? 'null')?.sort ?? null;
			sessionStorage.setItem('view:/', JSON.stringify({ filter: f, sort }));
		} catch {
			/* private mode */
		}
		goto('/');
	}
	const sidebarAlbums = $derived(app.albums.slice().sort((a, b) => a.title.localeCompare(b.title)));

	let updating = $state(false);
	/** The keyboard shortcuts list is open (sidebar info button, or ?). */
	let shortcuts = $state(false);
	function onShortcutKey(e: KeyboardEvent) {
		if (e.key !== '?' || e.metaKey || e.ctrlKey || e.altKey) return;
		if ((e.target as HTMLElement).closest?.('input, select, textarea, [contenteditable]')) return;
		shortcuts = !shortcuts;
	}

	onMount(async () => {
		registerServiceWorker();
		await app.init();
		pins.start();
		uploads.resume();
		if (!app.libraryConfigured && !page.url.pathname.startsWith('/settings')) goto('/settings');
	});

	/** Sources shown under Folders: more folders on the Mac, Photos libraries, rclone folders. */
	/** Sources (the library folder, more folders on the Mac, Photos libraries, rclone folders) and the folder tree. */
	const sidebarSources = $derived(sources(app.folders));
	const childrenOf = $derived.by(() => {
		const m = new Map<number, FolderNode[]>();
		for (const f of app.folders) if (f.parentId != null) m.set(f.parentId, [...(m.get(f.parentId) ?? []), f]);
		for (const l of m.values()) l.sort((a, b) => a.name.localeCompare(b.name));
		return m;
	});

	// ---- resizable sidebar (desktop): dragged by its edge, remembered on this device
	const SIDEBAR_KEY = 'sidebarWidth';
	const SIDEBAR_MIN = 180;
	const SIDEBAR_MAX = 480;
	function setSidebarWidth(w: number | null) {
		if (w == null) document.documentElement.style.removeProperty('--sidebar-w');
		else document.documentElement.style.setProperty('--sidebar-w', `${Math.round(Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, w)))}px`);
	}
	onMount(() => {
		const saved = Number(localStorage.getItem(SIDEBAR_KEY));
		if (saved) setSidebarWidth(saved);
	});
	let resizing = $state(false);
	function startResize(e: PointerEvent) {
		e.preventDefault();
		resizing = true;
		const handle = e.currentTarget as HTMLElement;
		handle.setPointerCapture(e.pointerId);
		const move = (ev: PointerEvent) => setSidebarWidth(ev.clientX);
		const up = (ev: PointerEvent) => {
			resizing = false;
			handle.removeEventListener('pointermove', move);
			handle.removeEventListener('pointerup', up);
			handle.removeEventListener('pointercancel', up);
			const w = Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, ev.clientX));
			localStorage.setItem(SIDEBAR_KEY, String(Math.round(w)));
		};
		handle.addEventListener('pointermove', move);
		handle.addEventListener('pointerup', up);
		handle.addEventListener('pointercancel', up);
	}
	function resetSidebar() {
		localStorage.removeItem(SIDEBAR_KEY);
		setSidebarWidth(null);
	}
</script>


{#if app.updateRequired || updated.current || app.newWebVersion}
	<div class="update" role="alertdialog" aria-modal="true" aria-labelledby="update-title">
		<div class="update-card">
			<h2 id="update-title">Update required</h2>
			<p class="muted">A new version of Photos is installed on the server. Update to continue.</p>
			<button class="btn primary" disabled={updating} onclick={() => { updating = true; applyUpdate(); }}
				>{updating ? 'Updating…' : 'Update now'}</button>
		</div>
	</div>
{/if}

<svelte:window onkeydown={onShortcutKey} />
{#if shortcuts}
	<ShortcutsSheet onClose={() => (shortcuts = false)} />
{/if}

<DropZone />
<UploadSheet />
<DeleteFlow />
<Hint />
<LibraryDownload />

<div class="shell" class:with-subtabs={collectionTab != null}>
	<nav class="sidebar" aria-label="Sections">
		<div class="brand">
			<span class="name"><img class="logo" src="/icons/icon-192.png" alt="" width="28" height="28" />Photos</span>
			<span class="brand-actions">
				<button class="cog" onclick={() => (shortcuts = true)} aria-label="Keyboard shortcuts" title="Keyboard shortcuts (?)"
					><Icon name="info" size={20} /></button
				>
				<a class="cog" href="/settings" class:active={exact('/settings')} aria-label="Settings" title="Settings"
					><Icon name="settings" size={20} /></a
				>
			</span>
		</div>
		<a href="/" class:active={onLibrary && libraryFilter === 'all'} onclick={(e) => showLibrary('all', e)}
			><Icon name="photos" size={20} /> Library</a
		>
		<a href="/people" class:active={exact('/people')}><Icon name="people" size={20} /> People</a>
		<a href="/places" class:active={exact('/places')}><Icon name="map" size={20} /> Places</a>
		<a href="/objects" class:active={page.url.pathname.startsWith('/objects')}><Icon name="tag" size={20} /> Objects</a>
		<a href="/duplicates" class:active={exact('/duplicates')}><Icon name="duplicate" size={20} /> Duplicates</a>
		<a href="/search" class:active={exact('/search')}><Icon name="search" size={20} /> Search</a>
		<a href="/trash" class:active={exact('/trash')}
			><Icon name="trash" size={20} /> Trash{#if app.trash.length}<span class="badge">{app.trash.length}</span>{/if}</a
		>
		<div class="group">Filters</div>
		{#each filterLinks as l (l.f)}
			<a href="/" class:active={libraryFilter === l.f} onclick={(e) => showLibrary(l.f, e)}
				><Icon name={l.icon} size={20} /> {l.label}</a
			>
		{/each}
		{#snippet groupHead(group: 'albums' | 'folders', href: string, label: string)}
			<div class="group">
				<button
					class="twisty"
					class:open={sidebarTree[group]}
					aria-label={sidebarTree[group] ? `Collapse ${label}` : `Expand ${label}`}
					aria-expanded={sidebarTree[group]}
					onclick={() => sidebarTree.toggleGroup(group)}><Icon name="chevron" size={11} /></button
				>
				<a class="grouplink" {href} class:active={exact(href)}>{label}</a>
			</div>
		{/snippet}
		{@render groupHead('albums', '/albums', 'Albums')}
		{#if sidebarTree.albums}
			<div class="albumlist">
				{#each sidebarAlbums as al (al.id)}
					<a href="/albums/{al.id}" class:active={page.url.pathname === `/albums/${al.id}`}><Icon name="albums" size={18} /> <span>{al.title}</span></a>
				{/each}
			</div>
		{/if}
		{@render groupHead('folders', '/folders', 'Folders')}
		{#if sidebarTree.folders}
			<div class="tree">
				{#each sidebarSources as src (src.root)}
					<SidebarFolder folder={src.folder} title={src.title} icon={kindIcon[src.kind]} {childrenOf} flat={isFlat(src)} />
				{/each}
			</div>
		{/if}
		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div
			class="resizer"
			class:resizing
			title="Drag to resize (double-click to reset)"
			onpointerdown={startResize}
			ondblclick={resetSidebar}
		></div>
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
	{#if collectionTab}
		<nav class="subtabs" aria-label="Collections">
			{#each collectionTabs as t (t.href)}
				<a href={t.href} class:active={collectionTab === t} aria-current={collectionTab === t ? 'page' : undefined}
					><Icon name={t.icon} size={20} /><span>{t.label}</span></a
				>
			{/each}
		</nav>
	{/if}
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
	/* Everything that keeps clear of the bottom bars (selection bar, scrubber, Places map…) uses
	   --tabbar-h, so on the phone it grows by the Collections tabs while they show. */
	.shell.with-subtabs {
		--tabbar-h: calc(var(--tabbar-base) + var(--subtabs-h));
	}
	.subtabs {
		position: fixed;
		z-index: 20;
		left: 0;
		right: 0;
		bottom: calc(var(--tabbar-base) + env(safe-area-inset-bottom));
		height: var(--subtabs-h);
		display: flex;
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
		border-top: 0.5px solid var(--separator);
	}
	.subtabs a {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 1px;
		font-size: 10px;
		color: var(--fg-secondary);
	}
	.subtabs a.active {
		color: var(--accent);
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
		height: calc(var(--tabbar-base) + env(safe-area-inset-bottom));
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
		.tabbar,
		.subtabs {
			display: none;
		}
		.shell.with-subtabs {
			--tabbar-h: var(--tabbar-base);
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
			/* the whole sidebar scrolls when it's taller than the window */
			overflow-y: auto;
			overscroll-behavior: contain;
		}
		.resizer {
			position: fixed;
			top: 0;
			bottom: 0;
			left: calc(var(--sidebar-w) - 3px);
			width: 6px;
			cursor: col-resize;
			z-index: 30;
		}
		.resizer:hover,
		.resizer.resizing {
			background: color-mix(in srgb, var(--accent) 35%, transparent);
		}
		.brand {
			display: flex;
			align-items: center;
			justify-content: space-between;
			font-weight: 700;
			font-size: 20px;
			padding: 6px 4px 14px 10px;
			/* stays at the top while the sidebar scrolls; the negative margin covers the sidebar's top padding */
			position: sticky;
			top: -16px;
			z-index: 2;
			margin: -16px -10px 0;
			padding: 22px 14px 14px 20px;
			background: var(--bg-elevated);
		}
		.brand .name {
			display: flex;
			align-items: center;
			gap: 10px;
		}
		.brand .logo {
			width: 28px;
			height: 28px;
			border-radius: 7px;
		}
		.sidebar .brand .cog {
			padding: 5px;
			border-radius: 8px;
		}
		.brand-actions {
			display: flex;
			align-items: center;
			gap: 2px;
		}
		.sidebar .brand button.cog {
			display: flex;
			border: none;
			background: none;
			color: var(--accent);
			cursor: pointer;
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
		.sidebar a .badge {
			margin-left: auto;
			font-size: 12px;
			color: var(--fg-secondary);
		}
		.sidebar a span {
			white-space: nowrap;
			overflow: hidden;
			text-overflow: ellipsis;
		}
		.group {
			display: flex;
			align-items: center;
			margin: 14px 10px 2px 0;
			font-size: 12px;
			font-weight: 600;
			color: var(--fg-secondary);
		}
		.group:not(:has(.twisty)) {
			margin-left: 10px;
		}
		.sidebar .grouplink {
			padding: 0;
			color: inherit;
		}
		.sidebar .grouplink.active {
			background: none;
			color: var(--fg);
		}
		.twisty {
			width: 20px;
			height: 20px;
			display: flex;
			align-items: center;
			justify-content: center;
			border: none;
			background: none;
			padding: 0;
			color: var(--fg-secondary);
			cursor: pointer;
		}
		.twisty :global(svg) {
			transition: transform 0.15s;
		}
		.twisty.open :global(svg) {
			transform: rotate(90deg);
		}
		.tree {
			display: flex;
			flex-direction: column;
			gap: 1px;
			padding-bottom: 12px;
		}
		.albumlist {
			display: flex;
			flex-direction: column;
			gap: 2px;
		}

	}
</style>
