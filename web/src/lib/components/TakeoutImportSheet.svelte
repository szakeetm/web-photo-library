<script lang="ts">
	// Choosing which Google Takeout album folders (folders with a metadata.json, in any source) become
	// albums. Folders not imported yet, or with photos their album lacks, start out ticked.
	import { onMount } from 'svelte';
	import { api, type TakeoutAlbum } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';

	let { onClose }: { onClose: () => void } = $props();

	let list = $state<TakeoutAlbum[] | null>(null);
	let picked = $state(new Set<string>());
	let filter = $state('');
	let error = $state('');
	let importing = $state(false);
	let done = $state('');

	async function load() {
		error = '';
		try {
			list = await api.takeoutAlbums();
			picked = new Set(list.filter((a) => a.missing > 0).map((a) => a.key));
		} catch (e) {
			error = (e as Error).message;
		}
	}
	onMount(() => {
		load();
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape' && !importing) onClose();
		};
		window.addEventListener('keydown', onKey);
		return () => window.removeEventListener('keydown', onKey);
	});

	const shown = $derived.by(() => {
		const q = filter.trim().toLowerCase();
		return (list ?? []).filter((a) => !q || a.title.toLowerCase().includes(q) || a.path.toLowerCase().includes(q));
	});
	const pickedCount = $derived(picked.size);

	function toggle(key: string) {
		const next = new Set(picked);
		if (next.has(key)) next.delete(key);
		else next.add(key);
		picked = next;
	}
	/** Ticks or unticks every album shown (all of them, or those matching the filter). */
	function setShown(on: boolean) {
		const next = new Set(picked);
		for (const a of shown) {
			if (on) next.add(a.key);
			else next.delete(a.key);
		}
		picked = next;
	}

	async function importPicked() {
		if (!pickedCount) return;
		importing = true;
		error = '';
		done = '';
		try {
			const r = await api.importTakeoutAlbums([...picked]);
			const parts = [];
			if (r.created) parts.push(`${r.created} album${r.created === 1 ? '' : 's'} created`);
			if (r.updated) parts.push(`${r.updated} updated`);
			done = parts.length ? parts.join(', ') + '.' : 'Nothing new to import.';
			await app.reload();
			await load();
		} catch (e) {
			error = (e as Error).message;
		} finally {
			importing = false;
		}
	}

	const status = (a: TakeoutAlbum) =>
		a.albumId == null ? 'New' : a.missing > 0 ? `${a.missing.toLocaleString()} new photo${a.missing === 1 ? '' : 's'}` : 'Imported';
</script>

<div class="scrim" role="presentation" onclick={() => !importing && onClose()}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-labelledby="takeout-title">
	<h3 id="takeout-title">Import Takeout albums</h3>
	<p class="muted small">
		Folders with a Google Takeout metadata.json, in every source. Each one you tick becomes an album with its photos (the
		photos stay where they are). Importing again adds photos that are new in the folder.
	</p>
	{#if list == null && !error}
		<p class="muted">Looking for album folders…</p>
	{:else if list && list.length === 0}
		<p class="muted">No album folders found. Album folders on rclone sources are found once they have been scanned.</p>
	{:else if list}
		<div class="tools">
			<input class="filter" type="search" placeholder="Filter" bind:value={filter} aria-label="Filter albums" />
			<button class="btn small-btn" onclick={() => setShown(true)} disabled={importing}>Select all</button>
			<button class="btn small-btn" onclick={() => setShown(false)} disabled={importing}>Unselect all</button>
		</div>
		<ul class="list">
			{#each shown as a (a.key)}
				<li>
					<label class:imported={a.albumId != null && a.missing === 0}>
						<input type="checkbox" checked={picked.has(a.key)} disabled={importing} onchange={() => toggle(a.key)} />
						<span class="text">
							<span class="title">{a.title}</span>
							<span class="path muted">{a.path}</span>
						</span>
						<span class="meta">
							<span class="count">{a.count.toLocaleString()}</span>
							<span class="status" class:new={a.albumId == null}>{status(a)}</span>
						</span>
					</label>
				</li>
			{:else}
				<li class="muted small none">No album matches “{filter}”.</li>
			{/each}
		</ul>
	{/if}
	{#if error}<p class="error small">{error}</p>{/if}
	{#if done}<p class="small">{done}</p>{/if}
	<div class="actions">
		<span class="muted small">{list ? `${pickedCount.toLocaleString()} of ${list.length.toLocaleString()} selected` : ''}</span>
		<button class="btn" onclick={onClose} disabled={importing}>Close</button>
		<button class="btn primary" onclick={importPicked} disabled={!pickedCount || importing}
			>{importing ? 'Importing…' : `Import ${pickedCount.toLocaleString()} album${pickedCount === 1 ? '' : 's'}`}</button
		>
	</div>
</div>

<style>
	.scrim {
		position: fixed;
		inset: 0;
		z-index: 150;
		background: rgba(0, 0, 0, 0.4);
	}
	.sheet {
		position: fixed;
		z-index: 151;
		left: 50%;
		top: 50%;
		transform: translate(-50%, -50%);
		width: min(640px, calc(100vw - 24px));
		height: min(720px, calc(100dvh - 32px));
		background: var(--bg);
		color: var(--fg);
		border-radius: 14px;
		padding: 16px;
		display: flex;
		flex-direction: column;
		gap: 10px;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
	}
	h3 {
		margin: 0;
		font-size: 17px;
	}
	p {
		margin: 0;
		font-size: 14px;
	}
	.small {
		font-size: 12px;
	}
	.error {
		color: var(--danger);
	}
	.tools {
		display: flex;
		gap: 8px;
		align-items: center;
	}
	.filter {
		flex: 1;
		min-width: 0;
		font: inherit;
		font-size: 14px;
		padding: 6px 10px;
		border-radius: 8px;
		border: 1px solid var(--separator);
		background: var(--bg-elevated);
		color: var(--fg);
	}
	.small-btn {
		white-space: nowrap;
	}
	.list {
		list-style: none;
		margin: 0;
		padding: 0;
		flex: 1;
		min-height: 0;
		overflow-y: auto;
		border: 0.5px solid var(--separator);
		border-radius: 10px;
	}
	.list li + li {
		border-top: 0.5px solid var(--separator);
	}
	.none {
		padding: 12px;
	}
	label {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 8px 10px;
		cursor: pointer;
	}
	label.imported .title {
		color: var(--fg-secondary);
	}
	input[type='checkbox'] {
		flex: none;
		width: 18px;
		height: 18px;
		accent-color: var(--accent);
	}
	.text {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
	}
	.title {
		font-size: 14px;
		font-weight: 500;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.path {
		font-size: 11px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.meta {
		flex: none;
		display: flex;
		flex-direction: column;
		align-items: flex-end;
		font-size: 12px;
		font-variant-numeric: tabular-nums;
	}
	.status {
		color: var(--fg-secondary);
	}
	.status.new {
		color: var(--accent);
	}
	.actions {
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.actions > span {
		flex: 1;
	}
</style>
