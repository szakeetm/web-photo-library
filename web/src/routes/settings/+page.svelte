<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type Job, type JobKind, type Settings } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import FolderPicker from '#lib/components/FolderPicker.svelte';

	let settings = $state<Settings | null>(null);
	let current = $state<Job | null>(null);
	let recent = $state<Job[]>([]);
	let picker = $state<'library' | 'data' | null>(null);
	let message = $state<{ text: string; error?: boolean } | null>(null);
	let owner = $state('');
	let moving = $state(false);

	const jobNames: Record<string, string> = {
		'detect-changes': 'Detect changes',
		reindex: 'Re-index',
		'rebuild-caches': 'Rebuild caches',
		'purge-missing': 'Purge missing'
	};
	const phaseNames: Record<string, string> = {
		scan: 'Scanning library',
		metadata: 'Reading metadata',
		thumbnails: 'Generating thumbnails',
		previews: 'Generating previews'
	};

	async function loadSettings() {
		settings = await api.settings();
		owner = settings.ownerLogin ?? '';
	}

	let wasRunning = false;
	let lastSeenJob = 0;
	async function poll() {
		try {
			const j = await api.jobs();
			current = j.current ?? j.recent.find((r) => r.state === 'queued') ?? null;
			recent = j.recent;
			const running = !!current;
			if (wasRunning && !running) {
				await app.reload();
				await loadSettings();
				// Surface the outcome of the job that just finished.
				const last = j.recent[0];
				if (last && last.id !== lastSeenJob) {
					lastSeenJob = last.id;
					if (last.state === 'failed') message = { text: last.error ?? 'Job failed', error: true };
					else if (last.state === 'done' && last.message) {
						const [summary, ...problems] = last.message.split('\n');
						message = {
							text: problems.length ? `${summary}. ${problems.length} problem(s) — see Recent jobs.` : summary,
							error: problems.length > 0
						};
					}
				}
			}
			wasRunning = running;
		} catch {
			/* server restarting */
		}
	}

	onMount(() => {
		loadSettings().catch((e) => (message = { text: String(e.message ?? e), error: true }));
		poll();
		const t = setInterval(poll, 1000);
		return () => clearInterval(t);
	});

	async function setLibrary(path: string) {
		picker = null;
		try {
			settings = await api.saveSettings({ libraryPath: path });
			message = { text: 'Library folder saved. Scanning…' };
			app.libraryConfigured = true;
			await start('detect-changes');
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}

	async function moveData(path: string) {
		picker = null;
		if (!confirm(`Move the database and caches to\n${path}?\n\nThe server restarts afterwards.`)) return;
		moving = true;
		try {
			await api.moveData(path);
			message = { text: 'Moved. Waiting for the server to restart…' };
			for (let i = 0; i < 30; i++) {
				await new Promise<void>((r) => setTimeout(r, 1000));
				try {
					await api.health();
					break;
				} catch {
					/* still restarting */
				}
			}
			await loadSettings();
			await app.reload();
			message = { text: `Data location is now ${settings?.dataDir}` };
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		} finally {
			moving = false;
		}
	}

	async function start(kind: JobKind) {
		if (kind === 'purge-missing' && !confirm('Permanently forget photos whose files are no longer found?\n\nTheir favourites, descriptions and (later) edits, albums and faces are deleted. This cannot be undone.')) return;
		try {
			await api.startJob(kind);
			wasRunning = true;
			poll();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}

	async function saveOwner() {
		settings = await api.saveSettings({ ownerLogin: owner.trim() });
		message = { text: 'Saved.' };
	}

	const fmtBytes = (n: number) =>
		n < 1e6 ? `${(n / 1e3).toFixed(0)} KB` : n < 1e9 ? `${(n / 1e6).toFixed(1)} MB` : `${(n / 1e9).toFixed(2)} GB`;
	const pct = (j: Job) => (j.total ? Math.round((j.progress / j.total) * 100) : 0);
	const when = (s: string | null) => (s ? new Date(s).toLocaleString() : '');
</script>

<div class="page">
	<h1>Settings</h1>

	{#if !app.libraryConfigured}
		<div class="welcome">
			<h2>Welcome</h2>
			<p>Choose the folder on this Mac that holds your photos. It is only ever read, never modified.</p>
			<button class="btn primary" onclick={() => (picker = 'library')}>Choose library folder…</button>
		</div>
	{/if}

	{#if settings?.dataLocationMissing}
		<div class="msg error">
			The data location <strong>{settings.dataDir}</strong> is not available — is its drive connected? Connect it and
			restart the server, or start over with an empty library in the default location.
			<div style="margin-top: 8px">
				<button class="btn danger" onclick={async () => {
					if (!confirm('Start over in the default location? The photos on the missing drive are not deleted.')) return;
					await api.resetDataLocation();
					setTimeout(() => location.reload(), 2500);
				}}>Use default location</button>
			</div>
		</div>
	{/if}

	{#if message}
		<p class="msg" class:error={message.error}>{message.text}</p>
	{/if}

	<section>
		<h3>Library</h3>
		<div class="row">
			<div class="label">
				<div>Library folder</div>
				<div class="muted path">{settings?.libraryPath ?? 'Not set'}</div>
			</div>
			<button class="btn" onclick={() => (picker = 'library')}>Choose…</button>
		</div>
		<div class="row actions">
			<button class="btn" disabled={!settings?.libraryPath} onclick={() => start('detect-changes')}>Detect changes</button>
			<button class="btn" disabled={!settings?.libraryPath} onclick={() => start('reindex')}>Re-index</button>
			<button class="btn" disabled={!settings?.libraryPath} onclick={() => start('rebuild-caches')}>Rebuild caches</button>
			<button class="btn danger" onclick={() => start('purge-missing')}>Purge missing</button>
		</div>
		<p class="hint muted">
			Detect changes picks up new, changed and removed files. Re-index re-reads dates and locations of every photo.
			Rebuild caches regenerates thumbnails and previews. Purge missing permanently forgets photos whose files are gone.
		</p>
		{#if current}
			<div class="job">
				<div class="jobhead">
					<strong>{jobNames[current.kind] ?? current.kind}</strong>
					<span class="muted"
						>{current.state === 'queued' ? 'Waiting…' : (phaseNames[current.phase ?? ''] ?? current.phase ?? '')}
						{#if current.total}· {current.progress} / {current.total}{/if}</span
					>
					<button class="btn" onclick={() => current && api.cancelJob(current.id)}>Cancel</button>
				</div>
				<div class="bar"><div style="width: {pct(current)}%"></div></div>
			</div>
		{/if}
		{#if recent.length}
			<details>
				<summary class="muted">Recent jobs</summary>
				<ul class="jobs">
					{#each recent as j (j.id)}
						<li>
							<span class="state {j.state}">{j.state}</span>
							<strong>{jobNames[j.kind] ?? j.kind}</strong>
							<span class="muted">{when(j.endedAt ?? j.startedAt)}</span>
							{#if j.error}<pre class="error">{j.error}</pre>{/if}
							{#if j.message}<pre>{j.message}</pre>{/if}
						</li>
					{/each}
				</ul>
			</details>
		{/if}
	</section>

	<section>
		<h3>Storage on the server</h3>
		<div class="row">
			<div class="label">
				<div>Data location <span class="muted">(database and caches)</span></div>
				<div class="muted path">{settings?.dataDir ?? ''}</div>
				{#if settings}
					<div class="muted small">
						Database {fmtBytes(settings.databaseBytes)} · Caches {fmtBytes(settings.cacheBytes)}
					</div>
				{/if}
			</div>
			<button class="btn" disabled={moving || !!current} onclick={() => (picker = 'data')}
				>{moving ? 'Moving…' : 'Move…'}</button
			>
		</div>
	</section>

	<section>
		<h3>Access</h3>
		<div class="row">
			<div class="label">
				<div>Owner Tailscale login</div>
				<div class="muted small">
					If set, other Tailscale users are refused. Leave empty to allow everyone on your tailnet.
				</div>
			</div>
		</div>
		<form
			class="row"
			onsubmit={(e) => {
				e.preventDefault();
				saveOwner();
			}}
		>
			<input class="text" placeholder="you@example.com" bind:value={owner} autocapitalize="off" spellcheck="false" />
			<button class="btn">Save</button>
		</form>
	</section>

	<section>
		<h3>About</h3>
		<div class="row">
			<div class="label">
				<div>App build {app.clientVersion}</div>
				<div class="muted small">Server {app.server?.version ?? '?'} · API {app.server?.apiVersion ?? '?'}</div>
			</div>
		</div>
	</section>
</div>

{#if picker === 'library'}
	<FolderPicker
		title="Choose library folder"
		start={settings?.libraryPath}
		onPick={setLibrary}
		onCancel={() => (picker = null)}
	/>
{:else if picker === 'data'}
	<FolderPicker
		title="Move data to…"
		start={settings?.dataDir}
		allowCreate
		onPick={moveData}
		onCancel={() => (picker = null)}
	/>
{/if}

<style>
	.page {
		max-width: 760px;
		margin: 0 auto;
		padding: max(16px, env(safe-area-inset-top)) 16px 32px;
	}
	h1 {
		font-size: 30px;
		margin: 12px 0 18px;
	}
	section {
		background: var(--bg-elevated);
		border-radius: var(--radius);
		padding: 6px 16px 12px;
		margin-bottom: 22px;
	}
	h3 {
		font-size: 13px;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--fg-secondary);
		font-weight: 500;
		margin: 10px 0 4px;
	}
	.row {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 10px 0;
		border-bottom: 0.5px solid var(--separator);
	}
	.row:last-child {
		border-bottom: none;
	}
	.label {
		flex: 1;
		min-width: 0;
	}
	.path {
		font-size: 13px;
		word-break: break-all;
		margin-top: 2px;
	}
	.small {
		font-size: 12px;
		margin-top: 2px;
	}
	.actions {
		flex-wrap: wrap;
		gap: 8px;
	}
	.actions .btn {
		background: var(--bg);
	}
	.hint {
		font-size: 12px;
		line-height: 1.45;
	}
	.job {
		background: var(--bg);
		border-radius: 8px;
		padding: 10px 12px;
		margin: 8px 0;
	}
	.jobhead {
		display: flex;
		gap: 10px;
		align-items: center;
		margin-bottom: 8px;
	}
	.jobhead .muted {
		flex: 1;
		font-size: 13px;
	}
	.bar {
		height: 6px;
		background: var(--separator);
		border-radius: 3px;
		overflow: hidden;
	}
	.bar div {
		height: 100%;
		background: var(--accent);
		transition: width 0.3s;
	}
	.jobs {
		list-style: none;
		padding: 0;
		margin: 6px 0;
		font-size: 13px;
	}
	.jobs li {
		padding: 6px 0;
		border-bottom: 0.5px solid var(--separator);
	}
	.jobs pre {
		white-space: pre-wrap;
		font-size: 12px;
		margin: 4px 0 0;
		max-height: 140px;
		overflow: auto;
		color: var(--fg-secondary);
	}
	.jobs pre.error {
		color: var(--danger);
	}
	.state {
		font-size: 11px;
		text-transform: uppercase;
		padding: 1px 6px;
		border-radius: 4px;
		background: var(--separator);
		margin-right: 6px;
	}
	.state.done {
		background: rgba(52, 199, 89, 0.25);
	}
	.state.failed {
		background: rgba(255, 59, 48, 0.25);
	}
	summary {
		cursor: pointer;
		font-size: 13px;
		padding: 6px 0;
	}
	.msg {
		padding: 10px 14px;
		border-radius: 8px;
		background: rgba(10, 132, 255, 0.12);
	}
	.msg.error {
		background: rgba(255, 59, 48, 0.14);
		color: var(--danger);
	}
	.welcome {
		background: var(--bg-elevated);
		border-radius: var(--radius);
		padding: 18px;
		margin-bottom: 22px;
	}
	.welcome h2 {
		margin: 0 0 6px;
	}
	input.text {
		flex: 1;
		min-width: 0;
		border: 0.5px solid var(--separator);
		background: var(--bg);
		border-radius: 8px;
		padding: 7px 10px;
		font: inherit;
		color: inherit;
	}
</style>
