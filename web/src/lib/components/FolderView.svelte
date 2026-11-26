<script lang="ts">
	import { reveal } from '#lib/reveal.ts';
	// Folder tree of one root (the read-only library, the uploads folder, or a source on an rclone remote).
	import { thumbUrl, type FolderNode, type RootName } from '#lib/api.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import TitleBar from './TitleBar.svelte';
	import { app } from '#lib/state.svelte.ts';
	import Icon from './Icon.svelte';
	import PhotoBrowser from './PhotoBrowser.svelte';
	import DownloadBar from './DownloadBar.svelte';
	import { net } from '#lib/net.svelte.ts';
	import { confirmDownload, folderAssetIds, folderPinId, pins, pinStatus, pinProgress } from '#lib/pins.svelte.ts';

	let { root, relPath, base, rootTitle }: { root: RootName; relPath: string; base: string; rootTitle: string } =
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

	const photos = $derived(folder ? (app.index.byFolder.get(folder.id) ?? []) : []);
	const sections = $derived([{ key: relPath || 'root', label: null, items: photos.map((a) => a.id) }]);
	const trail = $derived(
		relPath ? relPath.split('/').map((name, i, all) => ({ name, path: all.slice(0, i + 1).join('/') })) : []
	);
	const href = (p: string) => `${base}/${p.split('/').map(encodeURIComponent).join('/')}`;

	// ---- download to this device (this folder and its subfolders) ----
	let menu = $state(false);
	$effect(() => {
		void relPath;
		menu = false;
	});
	const title = $derived(trail.length ? trail[trail.length - 1].name : rootTitle);
	const totalPhotos = $derived(folder ? total(folder) : 0);
	/** This folder's download, or the parent folder download that includes it. */
	const pin = $derived(folder ? pins.folderPin(folder) : undefined);
	const ownPin = $derived(!!folder && pin?.albumId === folderPinId(folder));
	const subtitle = $derived.by(() => {
		if (!folder) return undefined;
		let s = `${totalPhotos.toLocaleString()} photo${totalPhotos === 1 ? '' : 's'}`;
		if (pin && ownPin) s += ` · ${pinStatus(pin, net.online)}`;
		// Covered by a parent folder's download: its size and progress are the parent's.
		else if (pin) s += pin.state === 'done' ? ` · Downloaded with “${pin.title}”` : ` · Downloading with “${pin.title}”`;
		return s;
	});

	async function toggleDownload() {
		if (!folder) return;
		if (ownPin) {
			await pins.remove(folderPinId(folder));
			return;
		}
		const count = folderAssetIds(folder, app.folders, app.index).length;
		if (confirmDownload(title, count, children.length > 0)) await pins.downloadFolder(folder, title);
	}
</script>

<TitleBar
	{title}
	{subtitle}
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
		{#if folder && app.local}
			<button class="icon-btn" onclick={() => reveal({ folder: folder.id })} title="Reveal in Finder" aria-label="Reveal in Finder"
				><Icon name="finder" /></button>
		{/if}
		{#if folder && totalPhotos && (!app.local || pin)}
			<div class="menuwrap">
				<button class="icon-btn" aria-label="More" aria-expanded={menu} onclick={() => (menu = !menu)}><Icon name="more" /></button>
				{#if menu}
					<div class="menu" role="menu">
						{#if pin && !ownPin}
							<button role="menuitem" disabled>Downloaded with “{pin.title}”</button>
						{:else if !app.local || ownPin}
							<!-- local mode: the photos are on this Mac already, offline downloads make no sense -->
							<button role="menuitem" disabled={!ownPin && !net.online} onclick={() => { menu = false; toggleDownload(); }}
								>{ownPin ? 'Remove Download' : 'Download to This Device'}</button>
						{/if}
					</div>
				{/if}
			</div>
		{/if}
	{/snippet}
</TitleBar>

<DownloadBar {pin} />

{#if app.loaded && !folder}
	<p class="empty muted">{root === 'uploads' ? 'No uploads yet.' : app.libraryConfigured ? 'Folder not found.' : 'No library folder yet.'}</p>
{:else if folder}
	{#if children.length}
		<div class="folders">
			{#each children as c (c.id)}
				{@const cid = cover(c)}
				{@const ca = cid ? app.byId.get(cid) : undefined}
				{@const cp = pins.folderPin(c)}
				<a class="card" href={href(c.relPath)}>
					<div class="cover">
						{#if ca}<img src={thumbUrl(ca.id, ca.ev, app.fmt)} alt="" loading="lazy" />{:else}<Icon name="folder" size={40} />{/if}
					</div>
					<div class="name">{c.name}</div>
					<div class="count muted">
						{total(c).toLocaleString()}
						{#if cp}<span class="dl" title={pinStatus(cp, net.online)}
								>· {cp.state === 'done' ? 'Downloaded' : `${Math.floor(pinProgress(cp) * 100)}%`}</span
							>{/if}
					</div>
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
	.dl {
		color: var(--accent);
	}
	.menuwrap {
		position: relative;
	}
	.menu {
		position: absolute;
		right: 0;
		top: 36px;
		min-width: 190px;
		background: var(--bg);
		border-radius: 10px;
		box-shadow: 0 8px 30px rgba(0, 0, 0, 0.2);
		border: 0.5px solid var(--separator);
		padding: 4px;
		z-index: 40;
	}
	.menu button {
		display: block;
		width: 100%;
		text-align: left;
		border: none;
		background: none;
		padding: 9px 12px;
		border-radius: 7px;
		cursor: pointer;
		color: var(--fg);
	}
	.menu button:hover:not(:disabled) {
		background: var(--bg-elevated);
	}
	.menu button:disabled {
		opacity: 0.5;
		cursor: default;
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
