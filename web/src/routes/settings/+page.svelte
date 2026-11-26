<script lang="ts">
	import Icon from '#lib/components/Icon.svelte';
	import { onMount } from 'svelte';
	import { api, type BackupStatus, type ConvertAllState, type Job, type JobKind, type Settings, type SourceScan } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import FolderPicker from '#lib/components/FolderPicker.svelte';
	import DeviceStorage from '#lib/components/DeviceStorage.svelte';
	import RemotePicker from '#lib/components/RemotePicker.svelte';
	import { deleteFlow } from '#lib/deleteFlow.svelte.ts';
	import RestoreSheet from '#lib/components/RestoreSheet.svelte';
	import TakeoutImportSheet from '#lib/components/TakeoutImportSheet.svelte';
	import { net } from '#lib/net.svelte.ts';
	import { applyUpdate } from '#lib/sw.ts';
	import { isIOS } from '#lib/download.ts';
	import { isFirefox } from '#lib/platform.ts';

	let settings = $state<Settings | null>(null);
	let current = $state<Job | null>(null);
	/** A source whose folder was moved, being pointed at its new place. */
	let relocating = $state<{ kind: 'library' | 'folder' | 'remote'; id: number; path: string } | null>(null);
	let recent = $state<Job[]>([]);
	let picker = $state<'data' | 'uploads' | 'photos' | 'folder' | null>(null);
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
		recluster: 'Regroup faces',
		objects: 'Analyse photos'
	};
	/** Why removing or relocating a source has to wait. */
	const busyTitle = $derived(
		!current
			? undefined
			: current.kind === 'faces' || current.kind === 'objects'
				? `Wait for ${jobNames[current.kind] ?? current.kind} to finish, or turn it off in Photo analysis.`
				: `Wait for ${jobNames[current.kind] ?? current.kind} to finish (see Library below).`
	);
	const phaseNames: Record<string, string> = {
		scan: 'Scanning library',
		metadata: 'Reading metadata',
		thumbnails: 'Generating thumbnails',
		previews: 'Generating previews',
		images: 'Generating thumbnails and previews',
		faces: 'Looking for faces',
		analyse: 'Analysing photos',
		remote: 'Fetching from remote sources'
	};

	/** The Analyse photos job, when it is running or waiting its turn. */
	const analysisJob = $derived(
		current?.kind === 'objects' ? current : (recent.find((r) => r.kind === 'objects' && r.state === 'queued') ?? null)
	);
	const analysisStatus = $derived.by(() => {
		const n = (x: number) => x.toLocaleString();
		const j = analysisJob;
		if (j?.state === 'running') {
			return j.total > 0 ? `Analysing… ${n(j.progress)} of ${n(j.total)}` : 'Analysing…';
		}
		if (j?.state === 'queued') return 'Waiting for the current job to finish';
		if (!settings) return '';
		if (settings.analysisTotal === 0) return 'No photos yet';
		if (settings.analysisPending === 0) return `All ${n(settings.analysisTotal)} analysed`;
		const done = settings.analysisTotal - settings.analysisPending;
		return `${n(done)} of ${n(settings.analysisTotal)} analysed · ${n(settings.analysisPending)} waiting`;
	});

	async function loadSettings() {
		settings = await api.settings();
		owner = settings.ownerLogin ?? '';
	}

	let wasRunning = false;
	let lastFinished = -1;
	let lastSeenJob = 0;
	async function poll() {
		if (!net.online) return;
		try {
			const j = await api.jobs();
			current = j.current ?? j.recent.find((r) => r.state === 'queued') ?? null;
			recent = j.recent;
			const running = !!current;
			// a job that just finished (others may follow it, like the analysis after a scan): its
			// photos and the sources' counts are shown now, not when the whole chain is done
			const finished = j.recent.find((r) => r.state === 'done' || r.state === 'failed' || r.state === 'cancelled');
			if (finished && finished.id !== lastFinished) {
				if (lastFinished !== -1 && running) {
					if (finished.kind === 'detect-changes' || finished.kind === 'reindex') await app.reload();
					await loadSettings();
				}
				lastFinished = finished.id;
			}
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
	const videoTotal = $derived(app.index.videos.length);
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

	// ---- library sources on rclone remotes

	let pickingSource = $state(false);
	/** What removing a source does, said plainly. */
	function removeWarning(name: string, untouched: string) {
		return (
			`Remove ${name}?\n\n` +
			'Its photos and videos (those not also in another source) are removed from the library permanently, ' +
			'with everything done to them here: edits, adjusted dates, video trims, favourites, descriptions, album memberships, ' +
			'people and faces, and deletions (they leave the Trash). Adding the source again later starts from scratch.\n\n' +
			untouched
		);
	}
	const hasSources = $derived(
		!!settings?.libraryPath ||
			!!settings?.uploadsPath ||
			(settings?.localFolders.length ?? 0) > 0 ||
			(settings?.remoteSources.length ?? 0) > 0 ||
			(settings?.photosLibraries.length ?? 0) > 0
	);
	async function addLocalFolder(path: string) {
		picker = null;
		try {
			settings = await api.addLocalFolder(path);
			message = { text: `${path.split('/').pop()} added. Scanning…` };
			app.libraryConfigured = true;
			poll();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	async function removeLocalFolder(id: number, path: string) {
		if (!confirm(removeWarning(path, 'Nothing in the folder is touched.'))) return;
		try {
			settings = await api.removeLocalFolder(id);
			await app.reload();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	async function addPhotosLibrary(path: string) {
		picker = null;
		try {
			settings = await api.addPhotosLibrary(path);
			message = { text: `${path.split('/').pop()} added. Scanning…` };
			app.libraryConfigured = true;
			poll();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	async function relocate(path: string) {
		const r = relocating;
		relocating = null;
		if (!r || path === r.path) return;
		try {
			settings =
				r.kind === 'library'
					? await api.relocateLibraryFolder(path)
					: r.kind === 'folder'
						? await api.relocateLocalFolder(r.id, path)
						: await api.relocateSource(r.id, path);
			message = { text: `Now reading ${r.path.split('/').filter(Boolean).pop()} from ${path}. Scanning…` };
			poll();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	async function removeLibraryFolder(path: string) {
		if (!confirm(removeWarning(path, 'Nothing in the folder is touched.'))) return;
		try {
			settings = await api.removeLibraryFolder();
			await app.reload();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	async function removePhotosLibrary(id: number, title: string) {
		if (!confirm(removeWarning(title, 'Albums imported from it stay (without its photos). Nothing in the Photos library is touched.'))) return;
		try {
			settings = await api.removePhotosLibrary(id);
			await app.reload();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	async function addSource(path: string) {
		pickingSource = false;
		try {
			settings = await api.addSource(path);
			message = { text: `${path} added. Scanning…` };
			app.libraryConfigured = true;
			poll();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	let removing = $state<number | null>(null);
	async function removeSource(id: number, path: string, stopsScan = false) {
		const what = 'Its originals kept on the Mac are deleted. Nothing on the remote is touched.';
		if (!confirm(removeWarning(path, stopsScan ? `Its scan is stopped first. ${what}` : what))) return;
		removing = id;
		try {
			settings = await api.removeSource(id);
			await app.reload();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		} finally {
			removing = null;
		}
	}
	async function stopJob(id: number) {
		try {
			await api.cancelJob(id);
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	async function setCacheGB(gb: number) {
		try {
			settings = await api.saveSettings({ originalsCacheGB: gb });
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	const cacheSizes = [5, 10, 20, 50, 100, 200, 500];

	/** A job's phase in words; a source's scan names the source ("remote:remote-2" → Fetching from Chicago to Seattle). */
	function phaseLabel(phase: string | null) {
		const [kind, root] = (phase ?? '').split(':');
		if (root) {
			const src = [...(settings?.remoteSources ?? []), ...(settings?.photosLibraries ?? [])].find((s) => s.root === root);
			return `${kind === 'photos' ? 'Scanning' : 'Fetching from'} ${src?.title ?? 'a source'}`;
		}
		return phaseNames[kind] ?? phase ?? '';
	}

	/** What a source is doing, or how its last scan went. */
	function sourceStatus(
		root: string,
		lastScan: SourceScan | null,
		files = 0
	): { text: string; busy?: boolean; progress?: number; error?: boolean; detail?: string | null; jobId?: number } {
		const scanning = current?.state === 'running' && (current.kind === 'detect-changes' || current.kind === 'reindex');
		if (scanning && current?.phase?.endsWith(':' + root)) {
			const p = current.total > 0 ? ` ${current.progress.toLocaleString()} of ${current.total.toLocaleString()}` : '…';
			return {
				text: `${current.phase.startsWith('photos') ? 'Scanning' : 'Fetching new photos'}${p}`,
				busy: true,
				progress: current.total ? current.progress / current.total : undefined,
				detail: current.detail,
				jobId: current.id
			};
		}
		const waiting =
			(scanning && !lastScan) || (!lastScan && recent.some((r) => r.kind === 'detect-changes' && r.state === 'queued'));
		if (waiting) return { text: 'Waiting to be scanned…', busy: true };
		// A first scan that was stopped (or interrupted) has no result yet, but some photos are in.
		if (!lastScan && files > 0)
			return { text: `First scan not finished: ${files.toLocaleString()} photos and videos are in so far. Scan to continue.` };
		if (!lastScan) return { text: 'Not scanned yet' };
		const when = new Date(lastScan.at).toLocaleString();
		if (!lastScan.ok) return { text: `Last scan failed (${when}): ${lastScan.note ?? ''}`, error: true };
		const parts = [
			lastScan.added && `${lastScan.added.toLocaleString()} added`,
			lastScan.updated && `${lastScan.updated.toLocaleString()} updated`,
			lastScan.removed && `${lastScan.removed.toLocaleString()} removed`,
			lastScan.problems && `${lastScan.problems.toLocaleString()} problems (see Recent jobs)`
		].filter(Boolean);
		return { text: `Scanned ${when}: ${parts.length ? parts.join(', ') : 'nothing new'}`, error: lastScan.problems > 0 };
	}

	// ---- backup (database and uploads, to an rclone destination)

	let backup = $state<BackupStatus | null>(null);
	let backupError = $state('');
	let pickingDestination = $state(false);
	let restoring = $state(false);
	async function loadBackup() {
		if (!net.online) return;
		try {
			backup = await api.backup();
			backupError = '';
		} catch (e) {
			// a restarting server is retried; anything else is shown
			if (net.online) backupError = (e as Error).message;
		}
	}
	async function backupAction(fn: () => Promise<BackupStatus>) {
		try {
			backup = await fn();
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}
	const backupRunning = $derived(!!backup?.activity);
	$effect(() => {
		if (!backupRunning) return;
		const t = setInterval(loadBackup, 1500);
		return () => clearInterval(t);
	});
	const intervals: [number, string][] = [
		[6, 'Every 6 hours'],
		[12, 'Every 12 hours'],
		[24, 'Every day'],
		[48, 'Every 2 days'],
		[168, 'Every week']
	];
	const ago = (iso: string) => {
		const s = (Date.now() - new Date(iso).getTime()) / 1000;
		if (s < 90) return 'just now';
		if (s < 5400) return `${Math.round(s / 60)} minutes ago`;
		if (s < 86400 * 1.5) return `${Math.round(s / 3600)} hours ago`;
		return `${Math.round(s / 86400)} days ago`;
	};
	const took = (a: string, b: string) => {
		const s = Math.max(0, (new Date(b).getTime() - new Date(a).getTime()) / 1000);
		return s < 90 ? `${Math.round(s)} s` : `${Math.round(s / 60)} min`;
	};

	onMount(() => {
		loadVideos();
		loadBackup();
		loadSettings().catch((e) => net.online && (message = { text: String(e.message ?? e), error: true }));
		poll();
		const t = setInterval(poll, 1000);
		return () => clearInterval(t);
	});

	async function setUploads(path: string) {
		picker = null;
		try {
			settings = await api.saveSettings({ uploadsPath: path });
			message = { text: `Uploads will be saved in ${path}. Scanning…` };
			app.libraryConfigured = true;
			await start('detect-changes');
		} catch (e) {
			message = { text: (e as Error).message, error: true };
		}
	}

	async function moveData(path: string) {
		picker = null;
		if (!confirm(`Move the database, caches and face model to\n${path}?\n\nThe server restarts afterwards.`)) return;
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

	async function setAnalysis(change: { facesEnabled?: boolean; objectsEnabled?: boolean }) {
		try {
			settings = await api.saveSettings(change);
			poll();
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
	const isSafari = typeof navigator !== 'undefined' && /^((?!chrome|android|crios|fxios).)*safari/i.test(navigator.userAgent);
	const isAndroid = typeof navigator !== 'undefined' && /Android/.test(navigator.userAgent);

	const fmtBytes = (n: number) =>
		n < 1e6 ? `${(n / 1e3).toFixed(0)} KB` : n < 1e9 ? `${(n / 1e6).toFixed(1)} MB` : `${(n / 1e9).toFixed(2)} GB`;
	const pct = (j: Job) => (j.total ? Math.round((j.progress / j.total) * 100) : 0);
	const when = (s: string | null) => (s ? new Date(s).toLocaleString() : '');

	/** Names of the cache's folders on the server. */
	const cacheLabels: Record<string, string> = {
		thumb: 'Thumbnails',
		preview: 'Previews',
		video: 'Videos',
		frames: 'Video frames',
		gainmap: 'HDR gain maps',
		faces: 'Faces',
		exports: 'Exports'
	};
	const cacheLabel = (name: string) => cacheLabels[name] ?? (name === 'other' ? 'Other' : name);
	/** The Import Takeout albums list is open. */
	let takeoutOpen = $state(false);
</script>

<div class="page">
	<h1>Settings</h1>

	{#if !app.libraryConfigured}
		<div class="welcome">
			<h2>Welcome</h2>
			<p>Add a folder on this Mac that holds your photos. It is only ever read, never modified.</p>
			<button class="btn primary" onclick={() => (picker = 'folder')}>Add folder…</button>
			<p class="muted small">
				No photos on this Mac yet? Choose an uploads folder instead and upload from your devices, or add an Apple Photos
				library or an rclone folder below.
			</p>
			<button class="btn" onclick={() => (picker = 'uploads')}>Choose uploads folder…</button>
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

	<div class="part">
		<h2><Icon name="info" size={20} /> About</h2>
	</div>

	<section>
		<h3>Versions</h3>
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
	</section>

	<div class="part">
		<h2><Icon name="device" size={20} /> This device</h2>
		<p class="muted">Only this {installed ? 'app' : 'browser'} on this device. Nothing here changes the server or the library.</p>
	</div>

	{#if app.serverLocal}
		<section>
			<h3>Local mode</h3>
			<div class="row">
				<div class="label">
					<div>Use local mode</div>
					<div class="muted small">
						This browser runs on the Mac that hosts the library, so photos and videos are read straight from its disk:
						nothing is cached or downloaded for offline use here, videos play from the original file when the browser
						can, zooming loads full resolution right away, and photos and folders can be revealed in the Finder.
					</div>
					<div class="muted small">Turn it off to test the app as a remote device (phone, other computer) would see it.</div>
				</div>
				<label class="switch">
					<input type="checkbox" checked={!app.forceRemote} onchange={(e) => app.setForceRemote(!(e.currentTarget as HTMLInputElement).checked)} />
					<span>{app.local ? 'On' : 'Off'}</span>
				</label>
			</div>
		</section>
	{/if}

	<section>
		<h3>Deleting</h3>
		<div class="row">
			<div class="label">
				<div>Ask before deleting</div>
				<div class="muted small">
					Off: photos go to the Trash right away and an Undo button shows for a few seconds. Deleting uploads permanently always
					asks.
				</div>
			</div>
			<label class="switch">
				<input type="checkbox" checked={!deleteFlow.skip} onchange={(e) => deleteFlow.setSkip(!(e.target as HTMLInputElement).checked)} />
				<span>{deleteFlow.skip ? 'Off' : 'On'}</span>
			</label>
		</div>
	</section>

	<section>
		<h3>Storage</h3>
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
						{:else if isAndroid}In the browser menu, choose <strong>Add to Home screen</strong> or <strong>Install app</strong>.
						{:else if isFirefox}Firefox can't install web apps on a computer: it works in a tab, and photos saved on this device stay
							until you clear them. For an app window, open this page in Chrome or Edge.
						{:else}Click the <strong>Install</strong> button at the right end of the address bar, or find
							<strong>Install</strong> in the browser menu (Chrome: Cast, save and share; Edge: Apps). The app gets its own window,
							and a Start menu, Dock or launcher entry.{/if}
					</div>
				{/if}
			</div>
		</div>
	</section>

	<div class="part">
		<h2><Icon name="server" size={20} /> Server</h2>
		<p class="muted">Settings of the Mac that hosts the library. They apply to every device using it.</p>
	</div>

	{#if !net.online}
		<p class="msg">The server can't be reached, so its settings are hidden. This device's settings are above.</p>
	{:else}
	{#snippet status(root: string, lastScan: SourceScan | null, files = 0)}
		{#each [sourceStatus(root, lastScan, files)] as st, i (i)}
			<div class="small" class:muted={!st.busy} class:warn={st.error}>{st.text}</div>
			{#if st.detail}<div class="small muted detail">{st.detail}</div>{/if}
			{#if st.progress != null}<div class="bar srcbar"><div style:width={`${st.progress * 100}%`}></div></div>{/if}
		{/each}
	{/snippet}

	<section>
		<h3>Local folders</h3>
		<div class="row">
			<div class="label">
				<div>Uploads</div>
				<div class="muted path">{settings?.uploadsPath ?? 'Not set: uploading is off'}</div>
				{#if settings?.uploadsPath}
					<div class="muted small">{settings.uploadsFiles.toLocaleString()} photo and video files · {fmtBytes(settings.uploadsBytes)}</div>
					{@render status('uploads', settings.uploadsLastScan)}
				{/if}
				<div class="muted small">
					Photos uploaded from your devices go here (phone-uploads/, desktop-uploads/), never into the other folders. It is
					always a source: what is in it shows under Folders, even with no other folder set.
				</div>
			</div>
			<button class="btn" onclick={() => (picker = 'uploads')}>{settings?.uploadsPath ? 'Change…' : 'Choose…'}</button>
		</div>
		{#if settings?.libraryPath}
			<div class="row">
				<div class="label">
					<div>{settings.libraryPath.split('/').filter(Boolean).pop()}</div>
					<div class="muted path">{settings.libraryPath}</div>
					<div class="muted small">{settings.libraryFiles.toLocaleString()} photo and video files</div>
					{@render status('library', settings.libraryLastScan)}
				</div>
				<div class="btns">
					<button class="btn" disabled={!!current} title={busyTitle} onclick={() => (relocating = { kind: 'library', id: 0, path: settings!.libraryPath! })}>Locate…</button>
					<button class="btn" disabled={!!current} title={busyTitle} onclick={() => removeLibraryFolder(settings!.libraryPath!)}>Remove</button>
				</div>
			</div>
		{/if}
		{#each settings?.localFolders ?? [] as f (f.id)}
			<div class="row">
				<div class="label">
					<div>{f.title}</div>
					<div class="muted path">{f.path}</div>
					<div class="muted small">{f.files.toLocaleString()} photo and video files · {fmtBytes(f.bytes)}</div>
					{@render status(f.root, f.lastScan)}
				</div>
				<div class="btns">
					<button class="btn" disabled={!!current} title={busyTitle} onclick={() => (relocating = { kind: 'folder', id: f.id, path: f.path })}>Locate…</button>
					<button class="btn" disabled={!!current} title={busyTitle} onclick={() => removeLocalFolder(f.id, f.path)}>Remove</button>
				</div>
			</div>
		{/each}
		<div class="row">
			<div class="label">
				<div class="muted small">
					Folders of photos and videos on the Mac or its drives, read where they are (never changed). Add as many as you
					like, or none. The same photo in several folders is shown once. Moved a folder? Locate… points the app at its new
					place, keeping everything done to its photos.
				</div>
			</div>
			<button class="btn" onclick={() => (picker = 'folder')}>Add Folder…</button>
		</div>
	</section>

	<section>
		<h3>Apple Photos libraries</h3>
		{#each settings?.photosLibraries ?? [] as lib (lib.id)}
			<div class="row">
				<div class="label">
					<div>{lib.title}</div>
					<div class="muted path">{lib.path}</div>
					{#if lib.stats}
						<div class="muted small">
							{lib.stats.onDisk.toLocaleString()} of {lib.stats.items.toLocaleString()} photos and videos on the Mac{#if lib.stats.onDisk < lib.stats.items}
								(the rest have no original in the library){/if} · {lib.stats.albums} albums · {fmtBytes(lib.bytes)}
						</div>
					{/if}
					{@render status(lib.root, lib.lastScan)}
				</div>
				<button class="btn" disabled={!!current} title={busyTitle} onclick={() => removePhotosLibrary(lib.id, lib.title)}>Remove</button>
			</div>
		{/each}
		<div class="row">
			<div class="label">
				<div class="muted small">
					Your own photos and videos in a Photos library, read where they are (never changed), with their original names and
					your albums. Photos edited in Photos come as Photos shows them (edits made here go on top). Shared albums aren't
					read yet.
				</div>
			</div>
			<button class="btn" onclick={() => (picker = 'photos')}>Add Photos Library…</button>
		</div>
	</section>

	<section>
		<h3>Folders on rclone remotes</h3>
		{#each settings?.remoteSources ?? [] as src (src.id)}
			{@const scanningThis = current?.state === 'running' && !!current.phase?.endsWith(':' + src.root)}
			<div class="row">
				<div class="label">
					<div>{src.title}</div>
					<div class="muted path">{src.path}</div>
					<div class="muted small">{src.files.toLocaleString()} photo and video files · {fmtBytes(src.bytes)}</div>
					{@render status(src.root, src.lastScan, src.files)}
				</div>
				<div class="btns">
					{#if scanningThis && current}
						<button class="btn" onclick={() => stopJob(current!.id)} title="Stop this scan; what was fetched stays">Stop</button>
					{:else}
						<button class="btn" disabled={!!current} title={current ? busyTitle : 'Look for new and changed photos (all sources are scanned; what is in already is skipped)'}
							onclick={() => start('detect-changes')}>Scan</button>
					{/if}
					<button class="btn" disabled={!!current} title={busyTitle} onclick={() => (relocating = { kind: 'remote', id: src.id, path: src.path })}>Locate…</button>
					<button class="btn" disabled={!!current && !scanningThis} title={scanningThis ? 'Stop the scan and remove this folder' : busyTitle}
						onclick={() => removeSource(src.id, src.path, scanningThis)}>{removing === src.id ? 'Removing…' : 'Remove'}</button>
				</div>
			</div>
		{/each}
		<div class="row">
			<div class="label">
				<div class="muted small">
					Folders on pCloud or any other rclone remote, read-only. Scans list them in one go and fetch new photos (many at a
					time) to make their thumbnails and previews; originals are fetched again when needed — to zoom, edit, play or
					export. Moved one? Locate… points the app at its new place, keeping everything.{#if !settings?.rclone} Needs rclone on the Mac (see Backup).{/if}
				</div>
			</div>
			<button class="btn" disabled={!settings?.rclone} onclick={() => (pickingSource = true)}>Add rclone Folder…</button>
		</div>
		{#if settings?.remoteSources.length}
			<div class="row">
				<div class="label">
					<div>Originals kept on the Mac</div>
					<div class="muted small">
						The most recently used originals from rclone folders stay on the Mac, up to this size: {fmtBytes(settings.originalsCacheBytes)} now.
					</div>
				</div>
				<select value={settings.originalsCacheGB} onchange={(e) => setCacheGB(Number((e.target as HTMLSelectElement).value))}>
					{#each cacheSizes as gb (gb)}<option value={gb}>{gb} GB</option>{/each}
					{#if !cacheSizes.includes(settings.originalsCacheGB)}<option value={settings.originalsCacheGB}>{settings.originalsCacheGB} GB</option>{/if}
				</select>
			</div>
		{/if}
	</section>

	<section>
		<h3>Library</h3>
		<div class="row actions">
			<button class="btn" disabled={!hasSources} onclick={() => start('detect-changes')}>Detect changes</button>
			<button class="btn" disabled={!hasSources} onclick={() => start('reindex')}>Re-index</button>
			<button class="btn" disabled={!hasSources} onclick={() => start('rebuild-caches')}>Rebuild caches</button>
			<button class="btn danger" onclick={() => start('purge-missing')}>Purge missing</button>
		</div>
		<div class="row actions">
			<button class="btn" disabled={!hasSources} onclick={() => (takeoutOpen = true)}>Import Takeout albums…</button>
			<span class="muted small"
				>Lists the Google Takeout album folders (with a metadata.json) in every source, rclone ones included, to choose
				which become albums. Safe to run again.</span
			>
			{#if takeoutOpen}<TakeoutImportSheet onClose={() => (takeoutOpen = false)} />{/if}
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
						>{current.state === 'queued' ? 'Waiting…' : phaseLabel(current.phase)}
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
			{#if vid.ffmpeg}
				<div class="row">
					<div class="label">
						<div>Delete conversions not played for</div>
						<div class="muted small">Keeps the server's cache small; a deleted conversion is made again when the video is played. Convert all turns this off.</div>
					</div>
					<select
						value={vid.keepDays ?? 0}
						onchange={(e) => {
							const v = Number((e.target as HTMLSelectElement).value);
							videoAction(() => api.setVideoCache(v || null));
						}}
					>
						<option value={0}>Never</option>
						<option value={1}>1 day</option>
						<option value={7}>7 days</option>
						<option value={30}>30 days</option>
					</select>
				</div>
			{/if}
		{/if}
	</section>

	<section>
		<h3>Storage on the server</h3>
		<div class="row">
			<div class="label">
				<div>Data location <span class="muted">(database, caches and face model)</span></div>
				<div class="muted path">{settings?.dataDir ?? ''}</div>
				{#if settings}
					<div class="muted small">
						Database {fmtBytes(settings.databaseBytes)} · Caches {fmtBytes(settings.cacheBytes)}
					</div>
					{#if settings.cacheParts?.length}
						<div class="muted small">
							{settings.cacheParts.map((c) => `${cacheLabel(c.name)} ${fmtBytes(c.bytes)}`).join(' · ')}
						</div>
					{/if}
				{/if}
			</div>
			<button class="btn" disabled={moving || !!current} onclick={() => (picker = 'data')}
				>{moving ? 'Moving…' : 'Move…'}</button
			>
		</div>
	</section>

	<section>
		<h3>Backup</h3>
		<div class="row">
			<div class="label">
				<div>rclone</div>
				{#if settings?.rclone}
					<div class="muted small">{settings.rclone.version} · {settings.rclone.path}</div>
				{:else if settings}
					<div class="muted small warn">
						Not found. On the Mac run <code>brew install rclone</code>, then set up your cloud storage with <code>rclone config</code>.
					</div>
				{/if}
			</div>
		</div>
		<div class="row">
			<div class="label">
				<div>Back up the database and uploads</div>
				<div class="muted small">
					What can't be rebuilt: the database (albums, edits, adjusted dates, people, places…) and the photos uploaded from
					devices (kept the same as the uploads folder: deleted uploads are removed from the backup too). Thumbnails,
					previews and the library itself aren't copied. The same files are replaced each time; a
					destination that keeps versions (like pCloud's 30-day rewind) keeps the earlier backups.
				</div>
			</div>
			<label class="switch">
				<input
					type="checkbox"
					checked={backup?.enabled ?? false}
					disabled={!backup?.rclone}
					onchange={(e) => backupAction(() => api.setBackup({ enabled: (e.target as HTMLInputElement).checked }))}
				/>
				<span>{backup?.enabled ? 'On' : 'Off'}</span>
			</label>
		</div>
		{#if backupError && !backup}
			<div class="row"><div class="label"><div class="small warn">Backup status can't be shown: {backupError}</div></div></div>
		{/if}
		{#if backup}
			<div class="row">
				<div class="label">
					<div>Destination</div>
					<div class="muted path">{backup.destination}</div>
				</div>
				<button class="btn" disabled={!backup.rclone} onclick={() => (pickingDestination = true)}>Choose…</button>
			</div>
			<div class="row">
				<div class="label">
					<div>How often</div>
					{#if backup.enabled && backup.nextAt && !backup.activity}
						<div class="muted small">Next backup {new Date(backup.nextAt) <= new Date() ? 'within a few minutes' : new Date(backup.nextAt).toLocaleString()}</div>
					{/if}
				</div>
				<select
					value={backup.intervalHours}
					onchange={(e) => backupAction(() => api.setBackup({ intervalHours: Number((e.target as HTMLSelectElement).value) }))}
				>
					{#each intervals as [h, label] (h)}<option value={h}>{label}</option>{/each}
					{#if !intervals.some(([h]) => h === backup?.intervalHours)}
						<option value={backup.intervalHours}>Every {backup.intervalHours} hours</option>
					{/if}
				</select>
			</div>
			<div class="row">
				<div class="label">
					<div>To back up now</div>
					<div class="muted small">
						Database {fmtBytes(backup.local.databaseBytes)} · {backup.local.assets.toLocaleString()} photos and videos · {backup.local.albums.toLocaleString()}
						{backup.local.albums === 1 ? 'album' : 'albums'}
					</div>
					<div class="muted small">
						Uploads {fmtBytes(backup.local.uploadsBytes)} · {backup.local.uploadsFiles.toLocaleString()}
						{backup.local.uploadsFiles === 1 ? 'file' : 'files'}{#if !settings?.uploadsPath} (no uploads folder){/if}
					</div>
				</div>
			</div>
			<div class="row">
				<div class="label">
					<div>Last backup</div>
					{#if backup.activity?.kind === 'backup'}
						<div class="small">
							Backing up… {backup.activity.phase}{#if backup.activity.files}: {backup.activity.files.toLocaleString()} files{/if}
						</div>
					{:else if backup.activity?.kind === 'restore'}
						<div class="small">Restoring… {backup.activity.phase}</div>
					{/if}
					{#if backup.last}
						{@const l = backup.last}
						<div class="small" class:warn={!l.ok}>
							{l.ok ? 'Done' : 'Failed'}
							{ago(l.finishedAt)} ({new Date(l.finishedAt).toLocaleString()}, took {took(l.startedAt, l.finishedAt)})
						</div>
						{#if l.ok}
							<div class="muted small">
								Database {fmtBytes(l.databaseBytes)} ({l.assets.toLocaleString()} photos and videos, {l.albums.toLocaleString()}
								{l.albums === 1 ? 'album' : 'albums'}) · uploads {fmtBytes(l.uploadsBytes)} ({l.uploadsFiles.toLocaleString()}
								{l.uploadsFiles === 1 ? 'file' : 'files'}, {l.uploadsCopied.toLocaleString()} new{#if l.uploadsDeleted}, {l.uploadsDeleted.toLocaleString()} removed{/if} this time)
							</div>
							<div class="muted small path">To {l.destination}</div>
						{:else}
							<div class="muted small">{l.error}</div>
							<div class="muted small">Tried again in an hour.</div>
						{/if}
					{:else if !backup.activity}
						<div class="muted small">Never</div>
					{/if}
				</div>
			</div>
			<div class="row actions">
				<button class="btn" disabled={!backup.rclone || !!backup.activity} onclick={() => backupAction(api.runBackup)}>Back Up Now</button>
				<button class="btn" disabled={!backup.rclone || !!backup.activity} onclick={() => (restoring = true)}>Restore…</button>
				<span class="muted small">Restore checks the backup first: that this server can open it and that the library folders are still where they were.</span>
			</div>
		{/if}
	</section>

	<section>
		<h3>Photo analysis</h3>
		<div class="row">
			<div class="label">
				<div class="muted small">
					Done on this Mac (Apple Vision and the Neural Engine) after each scan; nothing leaves the Mac. Turning one off
					stops it right away (what it found stays), so sources can be removed or located without waiting for it.
				</div>
			</div>
		</div>
		<div class="row">
			<div class="label">
				<div>Faces</div>
				<div class="muted small">Finds faces and groups them into people.</div>
				{#if settings && !settings.faceModelInstalled}
					<div class="muted small warn">
						The recognition model isn't installed. On the Mac run <code>tools/face-model/make.sh</code> (once), then Find faces.
					</div>
				{/if}
			</div>
			<label class="switch">
				<input type="checkbox" checked={settings?.facesEnabled ?? true} onchange={(e) => setAnalysis({ facesEnabled: (e.target as HTMLInputElement).checked })} />
				<span>{settings?.facesEnabled ?? true ? 'On' : 'Off'}</span>
			</label>
		</div>
		<div class="row actions">
			<button class="btn" disabled={!settings?.faceModelInstalled || !settings?.facesEnabled} onclick={() => start('faces')}>Find faces</button>
			<button class="btn" disabled={!settings?.faceModelInstalled} onclick={() => start('recluster')}>Regroup faces</button>
			<span class="muted small">Regroup rebuilds unnamed groups; names and your corrections stay.</span>
		</div>
		<div class="row">
			<div class="label">
				<div>Objects, text and duplicates</div>
				<div class="muted small">
					Recognises things in photos and videos (dogs, beaches, food…), reads text in photos for search, and fingerprints
					photos to find duplicates. Browse them in Collections (Objects, Duplicates), or search for text.
				</div>
			</div>
			<label class="switch">
				<input type="checkbox" checked={settings?.objectsEnabled ?? true} onchange={(e) => setAnalysis({ objectsEnabled: (e.target as HTMLInputElement).checked })} />
				<span>{settings?.objectsEnabled ?? true ? 'On' : 'Off'}</span>
			</label>
		</div>
		<div class="row actions">
			<button
				class="btn"
				disabled={!hasSources || !settings?.objectsEnabled || !!analysisJob || settings?.analysisPending === 0}
				onclick={() => start('objects')}>Analyse photos</button
			>
			<span class="small" class:muted={!analysisJob}>{analysisStatus}</span>
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
</div>

{#if relocating?.kind === 'remote'}
	<RemotePicker
		title={`Where is ${relocating.path} now?`}
		start={relocating.path}
		chooseLabel="It's Here"
		onPick={relocate}
		onCancel={() => (relocating = null)}
	/>
{:else if relocating}
	<FolderPicker
		title={`Where is ${relocating.path.split('/').filter(Boolean).pop()} now?`}
		start={relocating.path.split('/').slice(0, -1).join('/') || '/'}
		onPick={relocate}
		onCancel={() => (relocating = null)}
	/>
{/if}
{#if pickingSource}
	<RemotePicker title="Add a library folder" chooseLabel="Add This Folder" onPick={addSource} onCancel={() => (pickingSource = false)} />
{/if}
{#if pickingDestination && backup}
	<RemotePicker
		title="Back up to…"
		start={backup.destination}
		chooseLabel="Back Up Here"
		onPick={(p) => {
			pickingDestination = false;
			backupAction(() => api.setBackup({ destination: p }));
		}}
		onCancel={() => (pickingDestination = false)}
	/>
{/if}
{#if restoring && backup}
	<RestoreSheet start={backup.last?.destination ?? backup.destination} onClose={() => (restoring = false)} />
{/if}
{#if picker === 'folder'}
	<FolderPicker title="Add a folder of photos" start={settings?.libraryPath} onPick={addLocalFolder} onCancel={() => (picker = null)} />
{:else if picker === 'photos'}
	<FolderPicker title="Choose a Photos library (.photoslibrary)" start={'/Volumes'} onPick={addPhotosLibrary} onCancel={() => (picker = null)} />
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
	.btns {
		display: flex;
		gap: 8px;
		flex-shrink: 0;
	}
	.page {
		max-width: 760px;
		margin: 0 auto;
		padding: max(16px, env(safe-area-inset-top)) 16px 32px;
	}
	h1 {
		font-size: 30px;
		margin: 12px 0 18px;
	}
	.part {
		margin: 30px 2px 10px;
		padding-top: 14px;
		border-top: 1px solid var(--separator);
	}
	.part:first-of-type {
		margin-top: 8px;
		border-top: none;
		padding-top: 0;
	}
	.part h2 {
		display: flex;
		align-items: center;
		gap: 8px;
		font-size: 21px;
		margin: 0 0 2px;
	}
	.part h2 :global(svg) {
		color: var(--accent);
	}
	.part p {
		margin: 0;
		font-size: 13px;
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
	.detail {
		overflow-wrap: anywhere;
	}
	.srcbar {
		margin-top: 4px;
		max-width: 320px;
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
