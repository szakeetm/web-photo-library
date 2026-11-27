<script lang="ts">
	// Restoring a backup: choose where it is (any rclone location), see what it holds and whether
	// it can be restored here (the database opens with this server, the library folders it points at
	// are still where they were), then restore — the server downloads it and restarts with it.
	import { onDestroy } from 'svelte';
	import { api, type BackupInspection, type BackupStatus } from '#lib/api.ts';
	import RemotePicker from './RemotePicker.svelte';
	import { isoDateTime } from '#lib/dates.ts';

	let { start, onClose }: { start: string; onClose: () => void } = $props();

	// svelte-ignore state_referenced_locally
	let location = $state(start);
	let picking = $state(false);
	let inspection = $state<BackupInspection | null>(null);
	let checking = $state(false);
	let error = $state('');
	let phase = $state<'choose' | 'restoring' | 'restarting'>('choose');
	let status = $state<BackupStatus | null>(null);
	let confirmText = $state('');
	let timer: ReturnType<typeof setTimeout> | undefined;
	onDestroy(() => clearTimeout(timer));

	const fmtBytes = (n: number) => (n >= 1e9 ? `${(n / 1e9).toFixed(1)} GB` : n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.round(n / 1e3)} KB`);
	const when = (iso: string) => isoDateTime(iso);

	async function inspect() {
		checking = true;
		error = '';
		inspection = null;
		try {
			inspection = await api.inspectBackup(location);
		} catch (e) {
			error = (e as Error).message;
		} finally {
			checking = false;
		}
	}
	$effect(() => {
		if (location) inspect();
	});

	async function restore() {
		error = '';
		try {
			status = await api.restoreBackup(location);
			phase = 'restoring';
			watch();
		} catch (e) {
			error = (e as Error).message;
		}
	}

	function watch() {
		timer = setTimeout(async () => {
			try {
				const s = await api.backup();
				status = s;
				if (s.restoreError) {
					error = s.restoreError;
					phase = 'choose';
					return;
				}
				if (!s.activity || s.activity.kind !== 'restore') phase = 'restarting';
			} catch {
				// the server is restarting with the restored database
				phase = 'restarting';
			}
			if (phase === 'restarting') return waitForServer();
			watch();
		}, 1000);
	}

	function waitForServer() {
		timer = setTimeout(async () => {
			try {
				const r = await fetch('/api/health', { cache: 'no-store' });
				if (r.ok) {
					// everything shown so far came from the old database
					window.location.reload();
					return;
				}
			} catch {
				/* still restarting */
			}
			waitForServer();
		}, 1500);
	}
</script>

<div class="scrim" role="presentation" onclick={phase === 'choose' ? onClose : undefined}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-label="Restore a backup">
	{#if phase === 'choose'}
		<h3>Restore a backup</h3>
		<div class="where">
			<div>
				<div class="muted small">From</div>
				<div class="path">{location}</div>
			</div>
			<button class="btn" onclick={() => (picking = true)}>Choose…</button>
		</div>
		{#if checking}
			<p class="muted">Looking at the backup…</p>
		{:else if inspection}
			{#if inspection.manifest}
				{@const m = inspection.manifest}
				<p class="summary">
					Made {when(m.createdAt)}: {m.assets.toLocaleString()} photos and videos, {m.albums} albums, database {fmtBytes(inspection.databaseBytes)},
					{inspection.uploadsFiles.toLocaleString()} uploads ({fmtBytes(inspection.uploadsBytes)}).
				</p>
			{/if}
			<ul class="checks">
				{#each inspection.checks as c (c.title + c.detail)}
					<li class:bad={!c.ok}>
						<span class="mark">{c.ok ? '✓' : '✗'}</span>
						<div><strong>{c.title}</strong> <span class="muted">{c.detail}</span></div>
					</li>
				{/each}
			</ul>
			{#if inspection.canRestore}
				<p class="warn">
					The server's current database (albums, edits, people…) is replaced by this backup and kept next to it as a
					<code>.pre-restore</code> copy. Uploads in the backup are copied back; nothing is deleted. The server restarts, then scans the
					library for changes made since.
				</p>
				<label class="confirm"
					>Type <strong>restore</strong> to confirm
					<input bind:value={confirmText} autocapitalize="off" spellcheck="false" />
				</label>
			{/if}
		{/if}
		{#if error}<p class="error">{error}</p>{/if}
		<div class="buttons">
			<button class="btn" onclick={onClose}>Cancel</button>
			<button class="btn danger" disabled={!inspection?.canRestore || confirmText.trim().toLowerCase() !== 'restore'} onclick={restore}
				>Restore</button
			>
		</div>
	{:else if phase === 'restoring'}
		<h3>Restoring…</h3>
		<p class="muted">
			{status?.activity?.phase ?? 'Starting'}{#if status?.activity?.files}: {status.activity.files.toLocaleString()} files{/if}
		</p>
		<p class="muted small">Keep this page open; the server restarts when it's done.</p>
	{:else}
		<h3>Restarting the server…</h3>
		<p class="muted">The app reloads when it's back.</p>
	{/if}
</div>

{#if picking}
	<RemotePicker
		title="Restore from…"
		start={location}
		chooseLabel="Use This Folder"
		onPick={(p) => {
			picking = false;
			confirmText = '';
			location = p;
		}}
		onCancel={() => (picking = false)}
	/>
{/if}

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
		overflow: auto;
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
	.where {
		display: flex;
		align-items: center;
		gap: 10px;
		background: var(--bg-elevated);
		border-radius: 10px;
		padding: 8px 10px;
	}
	.where > div {
		flex: 1;
		min-width: 0;
	}
	.path {
		word-break: break-all;
		font-size: 14px;
	}
	.summary {
		font-size: 13px;
	}
	.checks {
		list-style: none;
		margin: 0;
		padding: 0;
		font-size: 13px;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
	.checks li {
		display: flex;
		gap: 8px;
	}
	.mark {
		color: var(--accent);
		font-weight: 600;
	}
	.checks li.bad .mark,
	.checks li.bad strong {
		color: var(--danger);
	}
	.warn {
		font-size: 13px;
		background: var(--bg-elevated);
		border-radius: 10px;
		padding: 8px 10px;
	}
	.confirm {
		display: flex;
		align-items: center;
		gap: 8px;
		font-size: 13px;
	}
	.confirm input {
		flex: 1;
		min-width: 0;
		border: 0.5px solid var(--separator);
		background: var(--bg-elevated);
		border-radius: 8px;
		padding: 6px 8px;
		font: inherit;
		color: inherit;
	}
	.error {
		color: var(--danger);
		font-size: 13px;
	}
	.buttons {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}
	.btn.danger:not(:disabled) {
		background: var(--danger);
		color: white;
	}
</style>
