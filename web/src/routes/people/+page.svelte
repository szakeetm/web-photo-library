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

<TitleBar title="People" subtitle={named.length ? String(named.length) : undefined} />

{#snippet grid(list: typeof app.people)}
	<div class="people">
		{#each list as p (p.id)}
			<a class="person" href="/people/{p.id}">
				<FaceAvatar faceId={p.coverFaceId} size={112} />
				<span class="name" class:unnamed={!p.name}>{p.name ?? 'Add Name'}</span>
				<span class="count muted">{p.count}</span>
			</a>
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
	.name {
		font-weight: 500;
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.name.unnamed {
		color: var(--accent);
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
