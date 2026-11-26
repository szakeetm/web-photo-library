<script lang="ts">
	// Duplicates: photos that are the same picture (copies: re-saved, resized, converted); shots that
	// are only alike (bursts, crops) aren't listed. Keep one: it gets the others' albums and favourite; the other
	// uploaded copies go to the Trash. The library folder is never written to, so library copies are
	// shown in the Finder (on the Mac) for you to delete; the next scan notices.
	import { onMount } from 'svelte';
	import { api, thumbUrl, type DuplicateGroup, type DuplicateItem } from '#lib/api.ts';
	import { app, deleteUploads } from '#lib/state.svelte.ts';
	import { captureLabel } from '#lib/dates.ts';
	import { formatBytes } from '#lib/video.ts';
	import { net } from '#lib/net.svelte.ts';
	import { reveal } from '#lib/reveal.ts';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import Icon from '#lib/components/Icon.svelte';

	let groups = $state<DuplicateGroup[] | null>(null);
	let error = $state('');
	let busy = $state<string | null>(null);
	/** Chosen copy per group (default: the largest, then the oldest). */
	let keep = $state<Record<string, string>>({});
	/** Library copies still on disk after keeping one: shown until dismissed. */
	let leftovers = $state<Record<string, DuplicateItem[]>>({});

	const best = (g: DuplicateGroup) =>
		g.items.slice().sort((a, b) => b.w * b.h - a.w * a.h || b.bytes - a.bytes || (a.t < b.t ? -1 : 1))[0].id;

	async function load() {
		error = '';
		try {
			groups = await api.duplicates();
			for (const g of groups) keep[g.key] ??= best(g);
		} catch (e) {
			error = (e as Error).message;
		}
	}
	onMount(load);

	const visible = $derived((groups ?? []).filter((g) => g.items.some((i) => app.byId.has(i.id)) || leftovers[g.key]));
	const same = $derived(visible.filter((g) => g.kind === 'same'));

	async function keepOne(g: DuplicateGroup) {
		const kept = keep[g.key] ?? best(g);
		const others = g.items.filter((i) => i.id !== kept);
		busy = g.key;
		try {
			await api.mergeDuplicates(kept, others.map((i) => i.id));
			const uploads = others.filter((i) => i.root === 'uploads').map((i) => i.id);
			if (uploads.length) await deleteUploads(uploads);
			const library = others.filter((i) => i.root === 'library');
			if (library.length) leftovers[g.key] = library;
			else await api.dismissDuplicates(g.key);
			await app.reload();
			if (!library.length) groups = (groups ?? []).filter((x) => x.key !== g.key);
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = null;
		}
	}

	async function notDuplicates(g: DuplicateGroup) {
		busy = g.key;
		try {
			await api.dismissDuplicates(g.key);
			groups = (groups ?? []).filter((x) => x.key !== g.key);
			delete leftovers[g.key];
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = null;
		}
	}

	const format = (mime: string) => (mime.split('.').pop() ?? mime).toUpperCase().replace('JPEG', 'JPG');
</script>

<TitleBar title="Duplicates" subtitle={groups ? `${visible.length} ${visible.length === 1 ? 'group' : 'groups'}` : undefined} back="/albums" />

{#if !net.online}
	<p class="empty muted">Duplicates need the server: you're offline.</p>
{:else if error}
	<p class="empty error">{error}</p>
{:else if groups == null}
	<p class="empty muted">Looking for duplicates…</p>
{:else if visible.length === 0}
	<p class="empty muted">No duplicates found. Photos are compared after “Analyse photos” (Settings) has run.</p>
{:else}
	{#snippet group(g: DuplicateGroup)}
		<section class="group">
			<div class="items">
				{#each g.items as it (it.id)}
					{@const a = app.byId.get(it.id)}
					<label class="item" class:kept={keep[g.key] === it.id}>
						<div class="thumb">
							{#if a}<img src={thumbUrl(a.id, a.ev, app.fmt)} alt="" loading="lazy" />{/if}
							<input type="radio" name={g.key} value={it.id} bind:group={keep[g.key]} disabled={!!leftovers[g.key]} />
						</div>
						<div class="meta">
							<div>
								<b>{it.w} × {it.h}</b> · {formatBytes(it.bytes)} · {format(it.mime)}
								{#if it.fav}<span title="Favourite">♥</span>{/if}
							</div>
							<div class="muted">{captureLabel(it.t, it.tz)}</div>
							<div class="muted path" title={it.path}>
								<span class="root">{it.root === 'uploads' ? 'Upload' : 'Library'}</span>
								{it.path}
							</div>
							{#if it.albums}<div class="muted">In {it.albums} {it.albums === 1 ? 'album' : 'albums'}</div>{/if}
						</div>
					</label>
				{/each}
			</div>
			{#if leftovers[g.key]}
				<div class="leftover">
					<p>
						Kept one. {leftovers[g.key].length === 1 ? 'This copy is' : 'These copies are'} in the library folder, which
						the app never changes: delete {leftovers[g.key].length === 1 ? 'it' : 'them'} in the Finder, then run Detect changes.
					</p>
					{#each leftovers[g.key] as it (it.id)}
						<div class="leftrow">
							<span class="path">{it.path}</span>
							{#if app.local}
								<button class="icon-btn" title="Reveal in Finder" aria-label="Reveal in Finder" onclick={() => reveal({ asset: it.id })}
									><Icon name="finder" /></button
								>
							{/if}
						</div>
					{/each}
					<button class="btn" onclick={() => notDuplicates(g)}>Done</button>
				</div>
			{:else}
				<div class="actions">
					<button class="btn" disabled={busy === g.key} onclick={() => notDuplicates(g)}>Not Duplicates</button>
					<button class="btn primary" disabled={busy === g.key} onclick={() => keepOne(g)}>Keep Selected</button>
				</div>
			{/if}
		</section>
	{/snippet}

	<p class="intro muted">
		Keep one photo of each group: it gets the others' albums and favourite. Uploaded copies go to the Trash; copies in the
		library folder are shown so you can delete them yourself.
	</p>
	{#each same as g (g.key)}{@render group(g)}{/each}
{/if}

<style>
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
	.error {
		color: var(--danger);
	}
	.intro {
		margin: 4px 16px 8px;
		font-size: 13px;
	}
	.group {
		margin: 0 12px 14px;
		padding: 10px;
		border-radius: 12px;
		background: var(--bg-elevated);
	}
	.items {
		display: flex;
		gap: 10px;
		overflow-x: auto;
	}
	.item {
		flex: 0 0 200px;
		border-radius: 10px;
		padding: 6px;
		border: 2px solid transparent;
		cursor: pointer;
		font-size: 13px;
	}
	.item.kept {
		border-color: var(--accent);
	}
	.thumb {
		position: relative;
		aspect-ratio: 1;
		border-radius: 8px;
		overflow: hidden;
		background: var(--bg);
	}
	.thumb img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}
	.thumb input {
		position: absolute;
		right: 8px;
		bottom: 8px;
		width: 20px;
		height: 20px;
		accent-color: var(--accent);
	}
	.meta {
		margin-top: 6px;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}
	.path {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.root {
		font-size: 11px;
		font-weight: 600;
		padding: 0 5px;
		border-radius: 4px;
		background: color-mix(in srgb, var(--accent) 14%, transparent);
		color: var(--accent);
	}
	.actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 8px;
	}
	.leftover {
		margin-top: 8px;
		font-size: 13px;
	}
	.leftover p {
		margin: 0 0 6px;
	}
	.leftrow {
		display: flex;
		align-items: center;
		gap: 6px;
	}
	.leftrow .path {
		flex: 1;
	}
</style>
