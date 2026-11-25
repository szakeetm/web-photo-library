<script lang="ts">
	// Sheet listing albums to add photos to, plus "New Album".
	import { thumbUrl } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import Icon from './Icon.svelte';

	let { count, onPick, onCreate, onCancel }: {
		count: number;
		onPick: (albumId: number) => void;
		onCreate: (title: string) => void;
		onCancel: () => void;
	} = $props();
	let creating = $state(false);
	let title = $state('');
	const albums = $derived(app.albums.slice().sort((a, b) => a.title.localeCompare(b.title)));
</script>

<div class="backdrop" role="presentation" onclick={onCancel}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-label="Add to album">
	<header>
		<h2>Add {count} {count === 1 ? 'photo' : 'photos'} to…</h2>
		<button class="icon-btn" onclick={onCancel} aria-label="Close"><Icon name="close" /></button>
	</header>
	{#if creating}
		<form class="new" onsubmit={(e) => { e.preventDefault(); if (title.trim()) onCreate(title.trim()); }}>
			<!-- svelte-ignore a11y_autofocus -->
			<input bind:value={title} placeholder="Album name" autofocus />
			<button class="btn primary" disabled={!title.trim()}>Create</button>
		</form>
	{:else}
		<button class="row newrow" onclick={() => (creating = true)}>
			<span class="cover plus">+</span> <span>New Album…</span>
		</button>
	{/if}
	<ul>
		{#each albums as al (al.id)}
			{@const c = al.coverId ? app.byId.get(al.coverId) : undefined}
			<li>
				<button class="row" onclick={() => onPick(al.id)}>
					<span class="cover">{#if c}<img src={thumbUrl(c.id, c.ev, app.fmt)} alt="" />{/if}</span>
					<span class="name">{al.title}</span>
					<span class="muted">{al.assetIds.filter((i) => app.byId.has(i)).length}</span>
				</button>
			</li>
		{/each}
	</ul>
</div>

<style>
	.backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.35);
		z-index: 150;
	}
	.sheet {
		position: fixed;
		z-index: 151;
		left: 50%;
		bottom: 0;
		transform: translateX(-50%);
		width: min(480px, 100vw);
		max-height: 75dvh;
		display: flex;
		flex-direction: column;
		background: var(--bg);
		border-radius: 14px 14px 0 0;
		padding-bottom: env(safe-area-inset-bottom);
		box-shadow: 0 -10px 40px rgba(0, 0, 0, 0.3);
	}
	@media (min-width: 768px) {
		.sheet {
			bottom: auto;
			top: 50%;
			transform: translate(-50%, -50%);
			border-radius: 14px;
		}
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 12px 12px 6px 18px;
	}
	h2 {
		font-size: 17px;
		margin: 0;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0 8px 8px;
		overflow: auto;
	}
	.row {
		width: 100%;
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 6px 10px;
		border: none;
		background: none;
		border-radius: 8px;
		cursor: pointer;
		text-align: left;
	}
	.row:hover {
		background: var(--bg-elevated);
	}
	.newrow {
		margin: 0 8px;
		width: calc(100% - 16px);
		color: var(--accent);
	}
	.cover {
		width: 48px;
		height: 48px;
		border-radius: 6px;
		overflow: hidden;
		background: var(--bg-elevated);
		flex: none;
	}
	.cover img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}
	.plus {
		display: flex;
		align-items: center;
		justify-content: center;
		font-size: 26px;
	}
	.name {
		flex: 1;
	}
	.new {
		display: flex;
		gap: 8px;
		padding: 4px 18px 10px;
	}
	.new input {
		flex: 1;
		border: 0.5px solid var(--separator);
		background: var(--bg-elevated);
		border-radius: 8px;
		padding: 8px 10px;
		font: inherit;
		color: inherit;
	}
</style>
