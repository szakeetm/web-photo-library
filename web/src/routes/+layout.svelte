<script lang="ts">
	import '../app.css';
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page, updated } from '$app/state';
	import favicon from '#lib/assets/favicon.svg';
	import Icon from '#lib/components/Icon.svelte';
	import { app } from '#lib/state.svelte.ts';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();

	const tabs = [
		{ href: '/', label: 'Library', icon: 'photos' },
		{ href: '/folders', label: 'Folders', icon: 'folder' },
		{ href: '/settings', label: 'Settings', icon: 'settings' }
	];
	const active = (href: string) =>
		href === '/' ? page.url.pathname === '/' : page.url.pathname.startsWith(href);

	onMount(async () => {
		await app.init();
		if (!app.libraryConfigured && !page.url.pathname.startsWith('/settings')) goto('/settings');
	});
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<div class="shell">
	<nav class="sidebar" aria-label="Sections">
		<div class="brand">Photos</div>
		{#each tabs as t (t.href)}
			<a href={t.href} class:active={active(t.href)}><Icon name={t.icon} size={20} /> {t.label}</a>
		{/each}
	</nav>
	<main>
		{#if app.compat === 'required'}
			<div class="banner update">
				This app is too old for the server. <button class="btn primary" onclick={() => location.reload()}>Update now</button>
			</div>
		{:else if updated.current || app.compat === 'available'}
			<div class="banner update">
				A new version of Photos is available. <button class="btn primary" onclick={() => location.reload()}>Update</button>
			</div>
		{:else if app.compat === 'older'}
			<div class="banner">The server is older than this app. Some features may not work until the server is updated.</div>
		{/if}
		{#if app.error}
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
	.banner.update {
		background: var(--bg-elevated);
		color: var(--fg);
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}
	.banner {
		background: #ff9f0a;
		color: black;
		padding: 8px 16px;
		font-size: 13px;
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
	}
</style>
