<script lang="ts">
	import { onMount } from 'svelte';
	import { api } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import FaceAvatar from '#lib/components/FaceAvatar.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	let showHidden = $state(false);
	let modelInstalled = $state<boolean | null>(null);
	let facesEnabled = $state(true);

	const named = $derived(app.people.filter((p) => !p.hidden && p.name));
	const unnamed = $derived(app.people.filter((p) => !p.hidden && !p.name));
	const hidden = $derived(app.people.filter((p) => p.hidden));

	/** The unnamed person whose name is being typed in place. */
	let naming = $state<number | null>(null);
	let nameText = $state('');
	let saving = $state(false);
	const knownNames = $derived([...new Set(app.people.filter((p) => p.name && !p.hidden).map((p) => p.name!))].sort());

	function startNaming(id: number) {
		naming = id;
		nameText = '';
	}
	function focusOnMount(el: HTMLInputElement) {
		el.focus();
	}
	/** Saves the typed name; a name someone already has offers to combine the two. */
	async function saveName(id: number) {
		if (naming !== id || saving) return;
		const name = nameText.trim();
		if (!name) {
			naming = null;
			return;
		}
		saving = true;
		try {
			const same = app.people.find((p) => p.id !== id && p.name?.toLowerCase() === name.toLowerCase());
			if (same) {
				if (!confirm(`“${same.name}” already exists. Are these the same person? Their photos will be combined.`)) return;
				await api.mergePeople([id], same.id);
			} else {
				await api.updatePerson(id, { name });
			}
			naming = null;
			await app.reload();
		} catch (e) {
			alert((e as Error).message);
		} finally {
			saving = false;
		}
	}

	onMount(() => {
		if (!net.online) return;
		api.settings()
			.then((s) => {
				modelInstalled = s.faceModelInstalled;
				facesEnabled = s.facesEnabled;
			})
			.catch(() => {});
	});
</script>

<datalist id="known-names">
	{#each knownNames as n (n)}<option value={n}></option>{/each}
</datalist>

<TitleBar title="People" subtitle={named.length ? String(named.length) : undefined} />

{#snippet grid(list: typeof app.people)}
	<div class="people">
		{#each list as p (p.id)}
			<div class="person">
				<a class="avatar" href="/people/{p.id}" title={p.name ? `All photos of ${p.name}` : 'Photos of this person'}>
					<FaceAvatar faceId={p.coverFaceId} size={112} />
				</a>
				{#if p.name}
					<a class="name" href="/people/{p.id}">{p.name}</a>
				{:else if naming === p.id}
					<input
						class="name-input"
						type="text"
						placeholder="Name"
						list="known-names"
						autocomplete="off"
						disabled={saving}
						bind:value={nameText}
						use:focusOnMount
						onkeydown={(e) => {
							if (e.key === 'Enter') saveName(p.id);
							else if (e.key === 'Escape') naming = null;
						}}
						onblur={() => saveName(p.id)}
					/>
				{:else}
					<button class="name unnamed" disabled={!net.online} onclick={() => startNaming(p.id)}>Add Name</button>
				{/if}
				<span class="count muted">{p.count}</span>
			</div>
		{/each}
	</div>
{/snippet}

{#if app.people.length === 0}
	<div class="empty muted">
		{#if modelInstalled === false}
			<p><strong>Face recognition isn't set up yet.</strong></p>
			<p>On the Mac, run <code>tools/face-model/make.sh</code> once, then choose Settings → Find faces.</p>
		{:else if !facesEnabled}
			<p>Face recognition is off. Turn it on in Settings.</p>
		{:else}
			<p>No people yet. Photos are scanned for faces in the background after each library scan.</p>
		{/if}
	</div>
{:else}
	{#if named.length}{@render grid(named)}{/if}
	{#if unnamed.length}
		<h2 class="section">{named.length ? 'More people' : 'Name the people in your photos'}</h2>
		{@render grid(unnamed)}
	{/if}
	{#if hidden.length}
		<button class="link" onclick={() => (showHidden = !showHidden)}>
			{showHidden ? 'Hide' : 'Show'} hidden people ({hidden.length})
		</button>
		{#if showHidden}{@render grid(hidden)}{/if}
	{/if}
{/if}

<style>
	.people {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(124px, 1fr));
		gap: 18px 12px;
		padding: 12px 16px 24px;
	}
	.person {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
		color: var(--fg);
		text-align: center;
		min-width: 0;
	}
	.avatar {
		display: block;
		border-radius: 50%;
	}
	.name {
		font: inherit;
		font-weight: 500;
		color: var(--fg);
		border: none;
		background: none;
		padding: 0;
		cursor: pointer;
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.name.unnamed {
		color: var(--accent);
	}
	.name.unnamed:disabled {
		color: var(--fg-secondary);
		cursor: default;
	}
	.name-input {
		width: 100%;
		max-width: 124px;
		font: inherit;
		font-weight: 500;
		text-align: center;
		padding: 3px 6px;
		border: 1px solid var(--accent);
		border-radius: 6px;
		background: var(--bg);
		color: var(--fg);
	}
	.count {
		font-size: 12px;
		margin-top: -4px;
	}
	.section {
		font-size: 17px;
		margin: 12px 16px 0;
	}
	.link {
		border: none;
		background: none;
		color: var(--accent);
		padding: 8px 16px 24px;
		cursor: pointer;
		font: inherit;
	}
	.empty {
		text-align: center;
		padding: 80px 24px;
		max-width: 520px;
		margin: 0 auto;
	}
	code {
		font-size: 13px;
		background: var(--bg-elevated);
		padding: 1px 5px;
		border-radius: 5px;
	}
</style>
