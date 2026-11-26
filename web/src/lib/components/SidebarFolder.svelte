<script lang="ts">
	// One folder in the sidebar's Folders tree, with its subfolders when expanded (a source is the
	// top folder of its tree). Which folders are open is remembered on this device.
	import { page } from '$app/state';
	import type { FolderNode } from '#lib/api.ts';
	import { folderHref } from '#lib/sources.ts';
	import { sidebarTree } from '#lib/sidebarTree.svelte.ts';
	import Icon from './Icon.svelte';
	import Self from './SidebarFolder.svelte';

	let {
		folder,
		title,
		icon = 'folder',
		depth = 0,
		childrenOf,
		flat = false
	}: {
		folder: FolderNode;
		title: string;
		icon?: string;
		depth?: number;
		childrenOf: Map<number, FolderNode[]>;
		/** never expanded (a Photos library) */
		flat?: boolean;
	} = $props();

	const kids = $derived(flat ? [] : (childrenOf.get(folder.id) ?? []));
	const open = $derived(sidebarTree.isOpen(folder.id));
	const href = $derived(folderHref(folder.root, folder.relPath));
	const active = $derived(decodeURIComponent(page.url.pathname) === decodeURIComponent(href));
</script>

<div class="item" class:active style:padding-left={`${depth * 14}px`}>
	{#if kids.length}
		<button
			class="twisty"
			class:open
			aria-label={open ? `Collapse ${title}` : `Expand ${title}`}
			aria-expanded={open}
			onclick={() => sidebarTree.toggle(folder.id)}><Icon name="chevron" size={12} /></button
		>
	{:else}
		<span class="twisty"></span>
	{/if}
	<a {href}><Icon name={icon} size={depth ? 16 : 18} /> <span>{title}</span></a>
</div>
{#if open}
	{#each kids as c (c.id)}
		<Self folder={c} title={c.name} depth={depth + 1} {childrenOf} />
	{/each}
{/if}

<style>
	.item {
		display: flex;
		align-items: center;
		border-radius: 8px;
	}
	.item.active {
		background: rgba(127, 127, 127, 0.18);
	}
	.twisty {
		flex: none;
		width: 20px;
		height: 26px;
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
	a {
		flex: 1;
		min-width: 0;
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 6px 8px 6px 2px;
		color: var(--fg);
		font-size: 14px;
	}
	a :global(svg) {
		flex: none;
		color: var(--accent);
	}
	a span {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
</style>
