<script lang="ts">
	import { gestureDebug } from '#lib/gestureDebug.svelte.ts';
	import { onMount } from 'svelte';
	import { api, type ConvertAllState, type Job, type JobKind, type Settings } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import FolderPicker from '#lib/components/FolderPicker.svelte';
	import DeviceStorage from '#lib/components/DeviceStorage.svelte';
	import { net } from '#lib/net.svelte.ts';
	import { applyUpdate } from '#lib/sw.ts';

	let settings = $state<Settings | null>(null);
	let current = $state<Job | null>(null);
	let recent = $state<Job[]>([]);
	let picker = $state<'library' | 'data' | 'uploads' | null>(null);
	let message = $state<{ text: string; error?: boolean } | null>(null);
	let owner = $state('');
	let moving = $state(false);

	const jobNames: Record<string, string> = {
		'detect-changes': 'Detect changes',
		reindex: 'Re-index',
		'rebuild-caches': 'Rebuild caches',
		'purge-missing': 'Purge missing',
		'import-takeout-albums': 'Import Takeout albums',
		faces: 'Find faces',
		recluster: 'Regroup faces'
	};
	const phaseNames: Record<string, string> = {
		scan: 'Scanning library',
		metadata: 'Reading metadata',
		thumbnails: 'Generating thumbnails',
		previews: 'Generating previews',
		images: 'Generating thumbnails and previews',
		faces: 'Looking for faces'
	};

	async function loadSettings() {
		settings = await api.settings();
		owner = settings.ownerLogin ?? '';
	}

	let wasRunning = false;
	let lastSeenJob = 0;
	async function poll() {
		if (!net.online) return;
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

	let vid = $state<ConvertAllState | null>(null);
	const videoTotal = $derived(app.assets.filter((a) => a.dur != null).length);
	async function loadVideos() {
		if (!net.online) return;
		try {
			vid = await api.videos();
		} catch {
			/* server restarting */
		}
	}
	async function videoAction(fn: () => Promise<ConvertAllState>) {
		try {
			vid = await fn();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	const videosRunning = $derived(vid?.state === 'running');
	$effect(() => {
		if (!videosRunning) return;
		const t = setInterval(loadVideos, 2000);
		return () => clearInterval(t);
	});

	onMount(() => {
		loadVideos();
		loadSettings().catch((e) => net.online && (message = { text: String(e.message ?? e), error: true }));
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

	async function setUploads(path: string) {
		picker = null;
		try {
			settings = await api.saveSettings({ uploadsPath: path });
			message = { text: `Uploads will be saved in ${path}.` };
			await app.reload();
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

	let mapStyle = $state('');
	$effect(() => {
		if (settings) mapStyle = settings.mapStyleURL ?? '';
	});

	async function setFaces(on: boolean) {
		try {
			settings = await api.saveSettings({ facesEnabled: on });
			if (on) poll();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}

	async function saveMapStyle() {
		try {
			settings = await api.saveSettings({ mapStyleURL: mapStyle.trim() });
			await app.reload();
			message = { text: 'Map style saved.' };
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}

	/** "abc1234 · 25 Nov 2026, 15:20" (+ a note when built from uncommitted changes). */
	function buildLabel(commit: string | null | undefined, date: string | null | undefined, dirty: boolean | undefined) {
		if (!commit) return 'unknown build';
		const when = date ? new Date(date).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '';
		return [commit + (dirty ? ' + local changes' : ''), when].filter(Boolean).join(' · ');
	}
	const appBuild = buildLabel(__APP_COMMIT__, __APP_COMMIT_DATE__, __APP_DIRTY__);

	let checking = $state(false);
	let updateNote = $state<string | null>(null);

	/** Asks the server for its current web app now (instead of waiting for the 5-minute check). */
	async function checkForUpdate() {
		checking = true;
		updateNote = null;
		try {
			const info = await net.check();
			if (!info) {
				updateNote = "Can't reach the server.";
			} else if (info.webVersion && info.webVersion !== app.clientVersion) {
				updateNote = 'Updating…';
				await applyUpdate();
			} else {
				updateNote = 'This is the latest version.';
			}
		} finally {
			checking = false;
		}
	}

	async function saveOwner() {
		settings = await api.saveSettings({ ownerLogin: owner.trim() });
		message = { text: 'Saved.' };
	}

	const installed =
		typeof window !== 'undefined' &&
		(matchMedia('(display-mode: standalone)').matches || (navigator as { standalone?: boolean }).standalone === true);
	const isIOS = typeof navigator !== 'undefined' && /iPhone|iPad|iPod/.test(navigator.userAgent);
	const isSafari = typeof navigator !== 'undefined' && /^((?!chrome|android|crios|fxios).)*safari/i.test(navigator.userAgent);

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

	{#if !net.online}
		<p class="msg">The server can't be reached, so its settings are hidden. Photos saved on this device are below.</p>
	{:else}
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
		<div class="row">
			<div class="label">
				<div>Uploads folder</div>
				<div class="muted path">{settings?.uploadsPath ?? 'Not set — uploading is off'}</div>
				<div class="muted small">Photos uploaded from your devices go here (phone-uploads/, desktop-uploads/), never into the library. Move them into the library whenever you like — albums and favourites follow them.</div>
			</div>
			<button class="btn" onclick={() => (picker = 'uploads')}>Choose…</button>
		</div>
		<div class="row actions">
			<button class="btn" disabled={!settings?.libraryPath} onclick={() => start('import-takeout-albums')}>Import Takeout albums</button>
			<span class="muted small">Turns Google Takeout album folders (with metadata.json) into albums. Safe to run again.</span>
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
		<h3>Videos</h3>
		{#if vid}
			<div class="row">
				<div class="label">
					<div>{videoTotal} videos · {vid.needed} need a preview · {vid.converted} converted ({fmtBytes(vid.bytes)})</div>
					{#if !vid.ffmpeg}
						<div class="muted small">ffmpeg not found — install with brew install ffmpeg (VP9 videos can't play without it; 4K videos play full size). Restart the server after installing.</div>
					{:else if vid.state === 'running'}
						<div class="muted small">
							Converting {vid.done} of {vid.total}{#if vid.current} · {vid.current}{/if}{#if vid.progress != null} {Math.round(vid.progress * 100)}%{/if}
						</div>
					{:else if vid.state === 'paused'}
						<div class="muted small">Paused · {vid.done} of {vid.total} done</div>
					{/if}
				</div>
				{#if vid.ffmpeg}
					{#if vid.state === 'running'}
						<button class="btn" onclick={() => videoAction(api.pauseConversion)}>Pause</button>
					{:else if vid.state === 'paused'}
						<button class="btn" onclick={() => videoAction(api.convertAll)}>Resume</button>
					{:else if vid.needed > 0}
						<button class="btn" onclick={() => videoAction(api.convertAll)}>Convert all {vid.needed}</button>
					{/if}
				{/if}
			</div>
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
		<h3>People</h3>
		<div class="row">
			<div class="label">
				<div>Face recognition</div>
				<div class="muted small">
					Finds faces on this Mac (Apple Vision and the Neural Engine) and groups them into people. Nothing leaves the Mac.
				</div>
				{#if settings && !settings.faceModelInstalled}
					<div class="muted small warn">
						The recognition model isn't installed. On the Mac run <code>tools/face-model/make.sh</code> (once), then Find faces.
					</div>
				{/if}
			</div>
			<label class="switch">
				<input type="checkbox" checked={settings?.facesEnabled ?? true} onchange={(e) => setFaces((e.target as HTMLInputElement).checked)} />
				<span>{settings?.facesEnabled ?? true ? 'On' : 'Off'}</span>
			</label>
		</div>
		<div class="row actions">
			<button class="btn" disabled={!settings?.faceModelInstalled || !settings?.facesEnabled} onclick={() => start('faces')}>Find faces</button>
			<button class="btn" disabled={!settings?.faceModelInstalled} onclick={() => start('recluster')}>Regroup faces</button>
			<span class="muted small">New photos are scanned after each scan. Regroup rebuilds unnamed groups; names and your corrections stay.</span>
		</div>
	</section>

	<section>
		<h3>Places</h3>
		<div class="row">
			<div class="label">
				<div>Map style</div>
				<div class="muted small">
					Photo locations are turned into place names on this Mac. The map itself loads tiles from the style's server
					(default {settings?.defaultMapStyleURL ?? 'OpenFreeMap'}); tiles you have seen keep working offline.
				</div>
			</div>
		</div>
		<form
			class="row"
			onsubmit={(e) => {
				e.preventDefault();
				saveMapStyle();
			}}
		>
			<input class="text" placeholder={settings?.defaultMapStyleURL ?? ''} bind:value={mapStyle} autocapitalize="off" spellcheck="false" />
			<button class="btn">Save</button>
		</form>
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
	{/if}

	<section>
		<h3>This device</h3>
		<DeviceStorage />
		<div class="row">
			<div class="label">
				{#if installed}
					<div>Installed as an app</div>
				{:else}
					<div>Install Photos as an app</div>
					<div class="muted small">
						{#if isIOS}In Safari, tap Share → <strong>Add to Home Screen</strong>. The app opens full screen and keeps its own storage.
						{:else if isSafari}In Safari, choose File → <strong>Add to Dock</strong> for an app window. (A plain Safari tab may lose cached data after 7 days unused.)
						{:else}Use your browser's <strong>Install app</strong> button in the address bar.{/if}
					</div>
				{/if}
			</div>
		</div>
	</section>

	<section>
		<h3>About</h3>
		<div class="row">
			<div class="label">
				<div>App {appBuild}</div>
				<div class="muted small">
					Server {app.server ? buildLabel(app.server.commit, app.server.commitDate, app.server.dirty) : '?'} · API {app.server?.apiVersion ?? '?'}
				</div>
				{#if updateNote}<div class="muted small">{updateNote}</div>{/if}
			</div>
		</div>
		<div class="row actions">
			<button class="btn" disabled={checking} onclick={checkForUpdate}>{checking ? 'Checking…' : 'Check for Update'}</button>
			<button class="btn" onclick={() => applyUpdate()}>Reload</button>
			<span class="muted small">The app also checks on its own every 5 minutes and when you switch back to it.</span>
		</div>
		<div class="row">
			<label class="label">
				<input type="checkbox" checked={gestureDebug.enabled} onchange={(e) => gestureDebug.set((e.currentTarget as HTMLInputElement).checked)} />
				Show touch gesture log in the photo viewer
				<div class="muted small">For troubleshooting pinch and swipe on this device.</div>
			</label>
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
{:else if picker === 'uploads'}
	<FolderPicker
		title="Choose uploads folder"
		start={settings?.uploadsPath ?? settings?.libraryPath}
		allowCreate
		onPick={setUploads}
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
	.switch {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		cursor: pointer;
	}
	.warn {
		color: #ff9f0a;
		margin-top: 4px;
	}
</style>
