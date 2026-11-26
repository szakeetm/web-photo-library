<script lang="ts">
	// The Folders page: a section per source (the library folder, more folders on the Mac, Apple Photos
	// libraries, rclone folders), each with its top-level folders.
	import { thumbUrl, type FolderNode } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { folderHref, isFlat, kindIcon, kindLabel, sources } from '#lib/sources.ts';
	import TitleBar from './TitleBar.svelte';
	import Icon from './Icon.svelte';

	const list = $derived(sources(app.folders));
	const childrenOf = $derived.by(() => {
		const m = new Map<number, FolderNode[]>();
		for (const f of app.folders) if (f.parentId != null) m.set(f.parentId, [...(m.get(f.parentId) ?? []), f]);
		for (const l of m.values()) l.sort((a, b) => a.name.localeCompare(b.name));
		return m;
	});
	function total(f: FolderNode): number {
		return f.count + (childrenOf.get(f.id) ?? []).reduce((n, c) => n + total(c), 0);
	}
	function cover(f: FolderNode): string | null {
		if (f.coverId) return f.coverId;
		for (const c of childrenOf.get(f.id) ?? []) {
			const id = cover(c);
			if (id) return id;
		}
		return null;
	}
	const all = $derived(list.reduce((n, s) => n + total(s.folder), 0));
</script>

<TitleBar title="Folders" subtitle={`${all.toLocaleString()} photos · ${list.length} ${list.length === 1 ? 'source' : 'sources'}`} />

{#if app.loaded && !list.length}
	<p class="empty muted">{app.libraryConfigured ? 'No folders yet.' : 'No library folder yet: choose one in Settings.'}</p>
{/if}

{#snippet card(f: FolderNode, name: string, href: string, count: number)}
	{@const cid = cover(f)}
	{@const ca = cid ? app.byId.get(cid) : undefined}
	<a class="card" {href}>
		<div class="cover">
			{#if ca}<img src={thumbUrl(ca.id, ca.ev, app.fmt)} alt="" loading="lazy" />{:else}<Icon name="folder" size={40} />{/if}
		</div>
		<div class="name">{name}</div>
		<div class="count muted">{count.toLocaleString()}</div>
	</a>
{/snippet}

{#each list as s (s.root)}
	{@const kids = isFlat(s) ? [] : (childrenOf.get(s.folder.id) ?? [])}
	<section>
		<h2>
			<a href={folderHref(s.root, '')}><Icon name={kindIcon[s.kind]} size={20} /> {s.title}</a>
			<span class="muted">{total(s.folder).toLocaleString()} · {kindLabel[s.kind]}</span>
		</h2>
		<div class="folders">
			{#each kids as c (c.id)}{@render card(c, c.name, folderHref(c.root, c.relPath), total(c))}{/each}
			<!-- photos not in a subfolder (or all of a Photos library) -->
			{#if !kids.length || s.folder.count > 0}
				{@render card(
					{ ...s.folder, coverId: s.folder.coverId ?? (kids.length ? null : cover(s.folder)) },
					kids.length ? `Photos in ${s.title}` : s.title,
					folderHref(s.root, ''),
					kids.length ? s.folder.count : total(s.folder)
				)}
			{/if}
		</div>
	</section>
{/each}

<style>
	section {
		margin-bottom: 8px;
	}
	h2 {
		display: flex;
		align-items: baseline;
		gap: 10px;
		flex-wrap: wrap;
		font-size: 19px;
		margin: 14px 16px 0;
	}
	h2 a {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		color: var(--fg);
	}
	h2 a :global(svg) {
		color: var(--accent);
		align-self: center;
	}
	h2 .muted {
		font-size: 13px;
		font-weight: 400;
	}
	.empty {
		padding: 40px 16px;
		text-align: center;
	}
	.folders {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 18px 14px;
		padding: 12px 14px 14px;
	}
	@media (max-width: 500px) {
		.folders {
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
