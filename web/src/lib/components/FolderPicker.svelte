<script lang="ts">
	// Modal that browses directories on the server (Mac) and returns the chosen path.
	import { api, type DirListing } from '#lib/api.ts';
	import Icon from './Icon.svelte';

	let { title, start, onPick, onCancel, allowCreate = false }: {
		title: string;
		start?: string | null;
		onPick: (path: string) => void;
		onCancel: () => void;
		allowCreate?: boolean;
	} = $props();

	let listing = $state<DirListing | null>(null);
	let error = $state<string | null>(null);
	let typed = $state('');
	let newName = $state('');

	async function open(path?: string | null) {
		try {
			listing = await api.listDir(path ?? undefined);
			typed = listing.path;
			error = null;
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		}
	}
	$effect(() => {
		open(start);
	});
</script>

<div class="backdrop" role="presentation" onclick={onCancel}></div>
<div class="dialog" role="dialog" aria-modal="true" aria-label={title}>
	<header>
		<h2>{title}</h2>
		<button class="icon-btn" onclick={onCancel} aria-label="Close"><Icon name="close" /></button>
	</header>
	<form class="pathbar" onsubmit={(e) => { e.preventDefault(); open(typed); }}>
		<button type="button" class="icon-btn" disabled={!listing?.parent} onclick={() => open(listing?.parent)} aria-label="Up">
			<Icon name="up" size={18} />
		</button>
		<input bind:value={typed} spellcheck="false" autocapitalize="off" />
	</form>
	{#if error}<p class="err">{error}</p>{/if}
	<ul>
		{#each listing?.entries ?? [] as e (e.path)}
			<li>
				<button disabled={!e.readable} onclick={() => open(e.path)}>
					<Icon name="folder" size={18} /> <span>{e.name}</span> <Icon name="chevron" size={14} />
				</button>
			</li>
		{:else}
			<li class="muted empty">No subfolders</li>
		{/each}
	</ul>
	<footer>
		{#if allowCreate}
			<input class="newname" placeholder="New folder name (optional)" bind:value={newName} />
		{/if}
		<button class="btn" onclick={onCancel}>Cancel</button>
		<button class="btn primary" disabled={!listing}
			onclick={() => listing && onPick(newName.trim() ? `${listing.path.replace(/\/$/, '')}/${newName.trim()}` : listing.path)}>
			Choose
		</button>
	</footer>
</div>

<style>
	.backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.35);
		z-index: 50;
	}
	.dialog {
		position: fixed;
		z-index: 51;
		left: 50%;
		top: 50%;
		transform: translate(-50%, -50%);
		width: min(560px, calc(100vw - 24px));
		height: min(620px, calc(100dvh - 48px));
		background: var(--bg);
		border-radius: 14px;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
		display: flex;
		flex-direction: column;
		overflow: hidden;
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 12px 12px 4px 18px;
	}
	h2 {
		font-size: 17px;
		margin: 0;
	}
	.pathbar {
		display: flex;
		gap: 6px;
		padding: 6px 12px;
	}
	.pathbar input,
	.newname {
		flex: 1;
		min-width: 0;
		border: 0.5px solid var(--separator);
		background: var(--bg-elevated);
		border-radius: 8px;
		padding: 7px 10px;
		font: inherit;
		color: inherit;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0 6px;
		overflow: auto;
		flex: 1;
		border-top: 0.5px solid var(--separator);
		border-bottom: 0.5px solid var(--separator);
	}
	li button {
		width: 100%;
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 9px 10px;
		border: none;
		background: none;
		border-radius: 8px;
		cursor: pointer;
		text-align: left;
	}
	li button span {
		flex: 1;
	}
	li button :global(svg:first-child) {
		color: var(--accent);
	}
	li button:hover:not(:disabled) {
		background: var(--bg-elevated);
	}
	li button:disabled {
		opacity: 0.4;
	}
	.empty {
		padding: 14px 10px;
	}
	footer {
		display: flex;
		gap: 8px;
		justify-content: flex-end;
		align-items: center;
		padding: 12px;
	}
	.err {
		color: var(--danger);
		padding: 0 18px;
		font-size: 13px;
	}
</style>
