<script lang="ts">
	// Folder tree of one root (the read-only library or the uploads folder).
	import { thumbUrl, type FolderNode } from '#lib/api.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import TitleBar from './TitleBar.svelte';
	import { app } from '#lib/state.svelte.ts';
	import Icon from './Icon.svelte';
	import PhotoBrowser from './PhotoBrowser.svelte';

	let { root, relPath, base, rootTitle }: { root: 'library' | 'uploads'; relPath: string; base: string; rootTitle: string } =
		$props();
	const selection = new Selection();
	const folder = $derived(app.folders.find((f) => f.root === root && f.relPath === relPath));
	const children = $derived(
		folder ? app.folders.filter((f) => f.parentId === folder.id).sort((a, b) => a.name.localeCompare(b.name)) : []
	);

	// Total photos and a cover for each subfolder, including nested folders.
	const childrenOf = $derived.by(() => {
		const m = new Map<number, FolderNode[]>();
		for (const f of app.folders) if (f.parentId != null) m.set(f.parentId, [...(m.get(f.parentId) ?? []), f]);
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

	const photos = $derived(folder ? app.assets.filter((a) => a.folders.includes(folder.id)) : []);
	const sections = $derived([{ key: relPath || 'root', label: null, items: photos.map((a) => a.id) }]);
	const trail = $derived(
		relPath ? relPath.split('/').map((name, i, all) => ({ name, path: all.slice(0, i + 1).join('/') })) : []
	);
	const href = (p: string) => `${base}/${p.split('/').map(encodeURIComponent).join('/')}`;
</script>

<TitleBar
	title={trail.length ? trail[trail.length - 1].name : rootTitle}
	back={trail.length ? (trail.length > 1 ? href(trail[trail.length - 2].path) : base) : undefined}
>
	{#snippet crumbs()}
		<a href={base}>{rootTitle}</a>
		{#each trail.slice(0, -1) as c (c.path)}
			<span>›</span> <a href={href(c.path)}>{c.name}</a>
		{/each}
	{/snippet}
	{#snippet actions()}
		{#if photos.length}
			<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
				{selection.active ? 'Cancel' : 'Select'}
			</button>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && !folder}
	<p class="empty muted">{root === 'uploads' ? 'No uploads yet.' : app.libraryConfigured ? 'Folder not found.' : 'No library folder yet.'}</p>
{:else if folder}
	{#if children.length}
		<div class="folders">
			{#each children as c (c.id)}
				{@const cid = cover(c)}
				{@const ca = cid ? app.byId.get(cid) : undefined}
				<a class="card" href={href(c.relPath)}>
					<div class="cover">
						{#if ca}<img src={thumbUrl(ca.id, ca.ev, app.fmt)} alt="" loading="lazy" />{:else}<Icon name="folder" size={40} />{/if}
					</div>
					<div class="name">{c.name}</div>
					<div class="count muted">{total(c).toLocaleString()}</div>
				</a>
			{/each}
		</div>
	{/if}
	{#if photos.length}
		{#if children.length}<h2 class="section">Photos <span class="muted">{photos.length}</span></h2>{/if}
		<PhotoBrowser {sections} {selection} />
	{/if}
{/if}

<style>
	.folders {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 18px 14px;
		padding: 12px 14px 20px;
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
	.section {
		font-size: 19px;
		margin: 8px 14px 10px;
	}
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
