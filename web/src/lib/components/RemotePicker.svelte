<script lang="ts">
	// Modal that browses rclone remotes on the server (pCloud, S3, SFTP… as set up with `rclone config`)
	// and returns the chosen folder as an rclone path ("remote:folder/sub"). A path can also be typed.
	import { api } from '#lib/api.ts';
	import Icon from './Icon.svelte';

	let {
		title,
		start,
		chooseLabel = 'Choose',
		onPick,
		onCancel
	}: {
		title: string;
		/** an rclone path to open at ("pcloud:Photos") */
		start?: string | null;
		chooseLabel?: string;
		onPick: (path: string) => void;
		onCancel: () => void;
	} = $props();

	/** '' = the list of remotes */
	let path = $state('');
	let entries = $state<string[]>([]);
	let loading = $state(false);
	let error = $state<string | null>(null);
	let typed = $state('');
	let creating = $state(false);
	let newName = $state('');

	const join = (dir: string, name: string) => (dir.endsWith(':') || dir.endsWith('/') ? dir + name : `${dir}/${name}`);
	/** One level up: "pcloud:a/b" → "pcloud:a" → "pcloud:" → '' (the remotes). */
	function parentOf(p: string) {
		if (!p) return null;
		if (p.endsWith(':')) return '';
		const colon = p.indexOf(':');
		const slash = p.lastIndexOf('/');
		return slash > colon ? p.slice(0, slash) : p.slice(0, colon + 1);
	}

	let seq = 0;
	async function open(p: string) {
		const n = ++seq;
		loading = true;
		error = null;
		creating = false;
		try {
			const list = p ? (await api.rcloneFolders(p)).folders : await api.rcloneRemotes();
			if (n !== seq) return;
			path = p;
			typed = p;
			entries = list;
		} catch (e) {
			if (n !== seq) return;
			error = e instanceof Error ? e.message : String(e);
			typed = p;
		} finally {
			if (n === seq) loading = false;
		}
	}
	$effect(() => {
		open(start ?? '');
	});

	async function makeFolder() {
		const name = newName.trim().replace(/\//g, '-');
		if (!name || !path) return;
		try {
			const target = join(path, name);
			await api.rcloneMakeFolder(target);
			newName = '';
			await open(target);
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		}
	}
</script>

<div class="backdrop" role="presentation" onclick={onCancel}></div>
<div class="dialog" role="dialog" aria-modal="true" aria-label={title}>
	<header>
		<h2>{title}</h2>
		<button class="icon-btn" onclick={onCancel} aria-label="Close"><Icon name="close" /></button>
	</header>
	<form
		class="pathbar"
		onsubmit={(e) => {
			e.preventDefault();
			open(typed.trim());
		}}
	>
		<button type="button" class="icon-btn" disabled={parentOf(path) == null} onclick={() => open(parentOf(path) ?? '')} aria-label="Up">
			<Icon name="up" size={18} />
		</button>
		<input bind:value={typed} placeholder="remote:folder" spellcheck="false" autocapitalize="off" />
	</form>
	{#if error}<p class="err">{error}</p>{/if}
	<ul class:loading>
		{#each entries as e (e)}
			<li>
				<button onclick={() => open(path ? join(path, e) : e)}>
					<Icon name={path ? 'folder' : 'server'} size={18} /> <span>{path ? e : e.replace(/:$/, '')}</span>
					<Icon name="chevron" size={14} />
				</button>
			</li>
		{:else}
			{#if !loading && !error}
				<li class="muted empty">{path ? 'No folders' : 'No rclone remotes. Set one up on the Mac with rclone config.'}</li>
			{/if}
		{/each}
	</ul>
	<footer>
		{#if creating}
			<form
				class="newfolder"
				onsubmit={(e) => {
					e.preventDefault();
					makeFolder();
				}}
			>
				<!-- svelte-ignore a11y_autofocus -->
				<input class="newname" placeholder="New folder name" bind:value={newName} autofocus />
				<button class="btn" disabled={!newName.trim()}>Create</button>
			</form>
		{:else}
			<button class="btn" disabled={!path || loading} onclick={() => (creating = true)}>New Folder</button>
		{/if}
		<span class="spacer"></span>
		<button class="btn" onclick={onCancel}>Cancel</button>
		<button class="btn primary" disabled={!path || loading || !!error} onclick={() => onPick(path)}>{chooseLabel}</button>
	</footer>
</div>

<style>
	.backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.35);
		z-index: 160;
	}
	.dialog {
		position: fixed;
		z-index: 161;
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
	ul.loading {
		opacity: 0.5;
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
		color: inherit;
		font: inherit;
	}
	li button span {
		flex: 1;
	}
	li button :global(svg:first-child) {
		color: var(--accent);
	}
	li button:hover {
		background: var(--bg-elevated);
	}
	.empty {
		padding: 16px 10px;
		font-size: 14px;
	}
	.err {
		color: var(--danger);
		margin: 4px 16px;
		font-size: 13px;
	}
	footer {
		display: flex;
		gap: 8px;
		align-items: center;
		padding: 10px 12px calc(10px + env(safe-area-inset-bottom));
	}
	.newfolder {
		display: flex;
		gap: 6px;
		flex: 1;
		min-width: 0;
	}
	.spacer {
		flex: 1;
	}
</style>
