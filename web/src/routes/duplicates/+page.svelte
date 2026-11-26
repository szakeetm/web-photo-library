<script lang="ts">
	// Duplicates: photos that are the same picture (copies: re-saved, resized, converted); shots that
	// are only alike (bursts, crops) aren't listed. Keep one: it gets the others' albums and favourite, and the
	// other copies go to the Trash (uploads are moved there; copies in folders, Photos libraries and rclone
	// folders are only hidden — their files are never touched).
	import { onMount } from 'svelte';
	import { api, thumbUrl, type DuplicateGroup } from '#lib/api.ts';
	import { app, deletePhotos } from '#lib/state.svelte.ts';
	import { captureLabel } from '#lib/dates.ts';
	import { formatBytes } from '#lib/video.ts';
	import { net } from '#lib/net.svelte.ts';
	import { LOCAL_FOLDERS } from '#lib/sources.ts';
	import TitleBar from '#lib/components/TitleBar.svelte';

	let groups = $state<DuplicateGroup[] | null>(null);
	let error = $state('');
	let busy = $state<string | null>(null);
	/** Chosen copy per group (default: the largest, then the oldest). */
	let keep = $state<Record<string, string>>({});
	/** Library copies still on disk after keeping one: shown until dismissed. */

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

	const visible = $derived((groups ?? []).filter((g) => g.items.some((i) => app.byId.has(i.id))));
	const same = $derived(visible.filter((g) => g.kind === 'same'));

	async function keepOne(g: DuplicateGroup) {
		const kept = keep[g.key] ?? best(g);
		const others = g.items.filter((i) => i.id !== kept);
		busy = g.key;
		try {
			await api.mergeDuplicates(kept, others.map((i) => i.id));
			await deletePhotos(others.map((i) => i.id));
			await api.dismissDuplicates(g.key);
			groups = (groups ?? []).filter((x) => x.key !== g.key);
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
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = null;
		}
	}

	const format = (mime: string) => (mime.split('.').pop() ?? mime).toUpperCase().replace('JPEG', 'JPG');

	/** Where a copy is: Upload, Local folders, or the source's name. */
	function sourceName(root: string) {
		if (root === 'uploads') return 'Upload';
		if (root === 'library') return LOCAL_FOLDERS;
		return app.folders.find((f) => f.root === root && f.relPath === '')?.name || 'Source';
	}
	// On the phone Duplicates is a Collections tab: no way "back".
	const phone = typeof matchMedia !== 'undefined' && matchMedia('(max-width: 767px)').matches;
</script>

<TitleBar title="Duplicates" subtitle={groups ? `${visible.length} ${visible.length === 1 ? 'group' : 'groups'}` : undefined} back={phone ? undefined : '/albums'} />

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
							<input type="radio" name={g.key} value={it.id} bind:group={keep[g.key]} />
						</div>
						<div class="meta">
							<div>
								<b>{it.w} × {it.h}</b> · {formatBytes(it.bytes)} · {format(it.mime)}
								{#if it.fav}<span title="Favourite">♥</span>{/if}
							</div>
							<div class="muted">{captureLabel(it.t, it.tz)}</div>
							<div class="muted path" title={it.path}>
								<span class="root">{sourceName(it.root)}</span>
								{it.path}
							</div>
							{#if it.albums}<div class="muted">In {it.albums} {it.albums === 1 ? 'album' : 'albums'}</div>{/if}
						</div>
					</label>
				{/each}
			</div>
			<div class="actions">
				<button class="btn" disabled={busy === g.key} onclick={() => notDuplicates(g)}>Not Duplicates</button>
				<button class="btn primary" disabled={busy === g.key} onclick={() => keepOne(g)}>Keep Selected</button>
			</div>
		</section>
	{/snippet}

	<p class="intro muted">
		Keep one photo of each group: it gets the others' albums and favourite, and the other copies go to the Trash. Uploads
		are deleted from disk when the Trash is emptied; copies in folders, Photos libraries and pCloud are only hidden here.
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
</style>
