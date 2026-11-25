<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { api, type FaceInfo } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { groupByMonth, monthLabel } from '#lib/dates.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import PhotoBrowser from '#lib/components/PhotoBrowser.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';
	import FaceAvatar from '#lib/components/FaceAvatar.svelte';
	import Icon from '#lib/components/Icon.svelte';

	const selection = new Selection();
	const id = $derived(Number(page.params.id));
	const person = $derived(app.personById.get(id));
	const photos = $derived(app.assets.filter((a) => a.pp?.includes(id)));
	const sections = $derived(
		groupByMonth(photos).map((g) => ({ key: `${id}-${g.key}`, label: monthLabel(g.key), items: g.items.map((a) => a.id) }))
	);

	let menu = $state(false);
	let mode = $state<'photos' | 'faces' | 'merge'>('photos');
	let faces = $state<FaceInfo[]>([]);
	let busy = $state(false);

	$effect(() => {
		void id;
		selection.clear();
		menu = false;
		mode = 'photos';
	});

	async function run(work: () => Promise<unknown>) {
		busy = true;
		try {
			await work();
			await app.reload();
		} catch (e) {
			alert((e as Error).message);
		} finally {
			busy = false;
		}
	}

	async function rename() {
		if (!person) return;
		const name = prompt(person.name ? 'Name' : 'Who is this?', person.name ?? '')?.trim();
		if (name == null || name === (person.name ?? '')) return;
		// Naming someone with an existing name offers to merge them.
		const same = name && app.people.find((p) => p.id !== id && p.name?.toLowerCase() === name.toLowerCase());
		if (same && confirm(`“${same.name}” already exists. Are these the same person? Their photos will be combined.`)) {
			await run(() => api.mergePeople([id], same.id));
			goto(`/people/${same.id}`, { replaceState: true });
			return;
		}
		await run(() => api.updatePerson(id, { name: name || null }));
	}

	async function toggleHidden() {
		if (!person) return;
		await run(() => api.updatePerson(id, { hidden: !person.hidden }));
	}

	async function showFaces() {
		mode = 'faces';
		faces = await api.personFaces(id);
	}

	async function notThisPerson(f: FaceInfo) {
		faces = faces.filter((x) => x.id !== f.id);
		await run(() => api.assignFace(f.id, null));
	}

	async function makeCover(f: FaceInfo) {
		await run(() => api.updatePerson(id, { coverFaceId: f.id }));
	}

	async function mergeInto(target: number) {
		const t = app.personById.get(target);
		if (!confirm(`Combine with ${t?.name ?? 'this person'}? All photos move to ${t?.name ?? 'them'}.`)) return;
		await run(() => api.mergePeople([id], target));
		goto(`/people/${target}`, { replaceState: true });
	}

	const others = $derived(app.people.filter((p) => p.id !== id && !p.hidden));
	const title = $derived(person?.name ?? 'Unnamed person');
</script>

<TitleBar {title} subtitle={person ? String(photos.length) : undefined} back="/people">
	{#snippet actions()}
		{#if person}
			{#if mode === 'photos' && photos.length}
				<button class="btn" onclick={() => (selection.active ? selection.clear() : selection.start())}>
					{selection.active ? 'Cancel' : 'Select'}
				</button>
			{:else if mode !== 'photos'}
				<button class="btn" onclick={() => (mode = 'photos')}>Done</button>
			{/if}
			<div class="menuwrap">
				<button class="icon-btn" aria-label="More" aria-expanded={menu} onclick={() => (menu = !menu)}><Icon name="more" /></button>
				{#if menu}
					<div class="menu" role="menu">
						<button role="menuitem" disabled={!net.online} onclick={() => { menu = false; rename(); }}>{person.name ? 'Rename' : 'Add Name'}</button>
						<button role="menuitem" disabled={!net.online} onclick={() => { menu = false; showFaces(); }}>Review Faces</button>
						<button role="menuitem" disabled={!net.online || !others.length} onclick={() => { menu = false; mode = 'merge'; }}>Same Person As…</button>
						<button role="menuitem" disabled={!net.online} onclick={() => { menu = false; toggleHidden(); }}>{person.hidden ? 'Show in People' : 'Hide from People'}</button>
					</div>
				{/if}
			</div>
		{/if}
	{/snippet}
</TitleBar>

{#if app.loaded && !person}
	<p class="empty muted">This person no longer exists (they may have been combined with someone else).</p>
{:else if person}
	{#if !person.name && mode === 'photos'}
		<div class="prompt">
			<FaceAvatar faceId={person.coverFaceId} size={56} />
			<span>Who is this?</span>
			<button class="btn primary" disabled={!net.online || busy} onclick={rename}>Add Name</button>
		</div>
	{/if}

	{#if mode === 'faces'}
		<p class="hint muted">Remove faces that aren't {person.name ?? 'this person'}; they won't be added back automatically.</p>
		<div class="faces">
			{#each faces as f (f.id)}
				<div class="face">
					<FaceAvatar faceId={f.id} size={104} />
					<div class="faceactions">
						<button class="icon-btn small" title="Not {person.name ?? 'this person'}" aria-label="Not this person" disabled={busy}
							onclick={() => notThisPerson(f)}><Icon name="close" size={16} /></button>
						<button class="icon-btn small" title="Use as cover" aria-label="Use as cover" disabled={busy || person.coverFaceId === f.id}
							onclick={() => makeCover(f)}><Icon name="select" size={16} /></button>
					</div>
				</div>
			{/each}
		</div>
	{:else if mode === 'merge'}
		<p class="hint muted">Choose who {person.name ?? 'this person'} also appears as. Their photos are combined.</p>
		<div class="faces">
			{#each others as o (o.id)}
				<button class="pick" disabled={busy} onclick={() => mergeInto(o.id)}>
					<FaceAvatar faceId={o.coverFaceId} size={96} />
					<span>{o.name ?? 'Unnamed'}</span>
					<span class="muted small">{o.count}</span>
				</button>
			{/each}
		</div>
	{:else}
		<PhotoBrowser {sections} {selection} />
	{/if}
{/if}

<style>
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
	}
	.menu button:hover {
		background: var(--bg-elevated);
	}
	.menu button:disabled {
		opacity: 0.4;
	}
	.prompt {
		display: flex;
		align-items: center;
		gap: 12px;
		margin: 8px 16px;
		padding: 10px 12px;
		border-radius: 12px;
		background: var(--bg-elevated);
		font-weight: 500;
	}
	.prompt .btn {
		margin-left: auto;
	}
	.hint {
		margin: 8px 16px;
		font-size: 13px;
	}
	.faces {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(112px, 1fr));
		gap: 16px 10px;
		padding: 8px 16px 32px;
	}
	.face {
		position: relative;
		display: flex;
		justify-content: center;
	}
	.faceactions {
		position: absolute;
		top: -4px;
		left: 0;
		right: 0;
		display: flex;
		justify-content: space-between;
	}
	.icon-btn.small {
		width: 28px;
		height: 28px;
		background: var(--bg);
		border-radius: 50%;
		box-shadow: 0 1px 4px rgba(0, 0, 0, 0.25);
		display: inline-flex;
		align-items: center;
		justify-content: center;
		padding: 0;
	}
	.pick {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 4px;
		border: none;
		background: none;
		cursor: pointer;
		font: inherit;
		color: var(--fg);
	}
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
