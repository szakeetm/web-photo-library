<script lang="ts">
	// Turning folders into albums: one album per folder, with the folder's photos (subfolders included),
	// named after the folder unless the name is changed here.
	import { onMount } from 'svelte';
	import { api, type FolderNode } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { folderAssetIds } from '#lib/pins.svelte.ts';

	let { folders, onDone, onCancel }: { folders: FolderNode[]; onDone: (created: number) => void; onCancel: () => void } = $props();

	// svelte-ignore state_referenced_locally
	let rows = $state(folders.map((f) => ({ folder: f, name: f.name, ids: folderAssetIds(f, app.folders, app.index) })));
	let busy = $state(false);
	let error = $state('');
	const valid = $derived(rows.every((r) => r.name.trim()));

	let first: HTMLInputElement | undefined = $state();
	onMount(() => {
		first?.focus();
		first?.select();
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape' && !busy) onCancel();
		};
		window.addEventListener('keydown', onKey);
		return () => window.removeEventListener('keydown', onKey);
	});

	async function ok() {
		if (!valid || busy) return;
		busy = true;
		error = '';
		let created = 0;
		try {
			for (const r of rows) {
				await api.createAlbum(r.name.trim(), r.ids);
				created++;
			}
			await app.reload();
			onDone(created);
		} catch (e) {
			error = `${created ? `${created} album${created === 1 ? '' : 's'} created, then: ` : ''}${(e as Error).message}`;
			if (created) await app.reload();
		} finally {
			busy = false;
		}
	}
</script>

<div class="scrim" role="presentation" onclick={() => !busy && onCancel()}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-labelledby="f2a-title">
<form
	onsubmit={(e) => {
		e.preventDefault();
		ok();
	}}
>
	<h3 id="f2a-title">Make {rows.length === 1 ? 'an album' : `${rows.length} albums`}</h3>
	<p class="muted small">Each folder becomes an album with its photos, subfolders included. The photos stay where they are.</p>
	<ul class="list">
		{#each rows as r, i (r.folder.id)}
			<li>
				<label for="f2a-{r.folder.id}" class="from muted">{r.folder.relPath || r.folder.name} · {r.ids.length.toLocaleString()} photo{r.ids.length === 1 ? '' : 's'}</label>
				{#if i === 0}
					<input id="f2a-{r.folder.id}" type="text" bind:value={r.name} bind:this={first} disabled={busy} placeholder="Album name" />
				{:else}
					<input id="f2a-{r.folder.id}" type="text" bind:value={r.name} disabled={busy} placeholder="Album name" />
				{/if}
			</li>
		{/each}
	</ul>
	{#if error}<p class="error small">{error}</p>{/if}
	<div class="actions">
		<button type="button" class="btn" onclick={onCancel} disabled={busy}>Cancel</button>
		<button type="submit" class="btn primary" disabled={!valid || busy}>{busy ? 'Creating…' : 'OK'}</button>
	</div>
</form>
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
		width: min(520px, calc(100vw - 24px));
		max-height: calc(100dvh - 32px);
		margin: 0;
		background: var(--bg);
		color: var(--fg);
		border-radius: 14px;
		padding: 16px;
		display: flex;
		flex-direction: column;
		gap: 10px;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
	}
	form {
		display: contents;
	}
	h3 {
		margin: 0;
		font-size: 17px;
	}
	p {
		margin: 0;
	}
	.small {
		font-size: 12px;
	}
	.error {
		color: var(--danger);
	}
	.list {
		list-style: none;
		margin: 0;
		padding: 0;
		overflow-y: auto;
		min-height: 0;
		display: flex;
		flex-direction: column;
		gap: 10px;
	}
	li {
		display: flex;
		flex-direction: column;
		gap: 3px;
	}
	.from {
		font-size: 12px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	input {
		font: inherit;
		font-size: 15px;
		padding: 7px 10px;
		border-radius: 8px;
		border: 1px solid var(--separator);
		background: var(--bg-elevated);
		color: var(--fg);
	}
	input:focus {
		outline: 2px solid var(--accent);
		outline-offset: -1px;
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}
</style>
