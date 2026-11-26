<script lang="ts">
	// Exporting a selection, albums or the whole library.
	//
	// Desktop: the Mac builds the export — originals, with edits, or both (the originals of edited
	// items in an Originals/ folder); Live Photo videos; Google Photos JSON or XMP sidecars; flat, by
	// album or by month — and streams it as one ZIP, or (in local mode) writes it into a folder on the Mac.
	// From another computer a ZIP is limited (1,000 items or 5 GB: it's made in one go and can't
	// resume); above that, Chrome and Edge write the files into a folder themselves (resumable).
	//
	// Phones: only what the share sheet can take — the files themselves, fetched into memory and
	// shared (a download would trap an iOS Home Screen app). Live Photos: a still and its MOV share a
	// content identifier (kept in edited exports too), so importing both into Photos on a Mac pairs
	// them again; a web page can't save a Live Photo into the iPhone's Photos library.
	import { onDestroy } from 'svelte';
	import {
		api,
		exportDownloadUrl,
		exportUrl,
		motionDownloadUrl,
		originalUrl,
		type ExportEstimate,
		type ExportOptions,
		type ExportStatus,
		type ImageFmt
	} from '#lib/api.ts';
	import { downloadUrl, iosStandalone, isIOS } from '#lib/download.ts';
	import { isEdited } from '#lib/gridView.svelte.ts';
	import { sortByLocalTime } from '#lib/dates.ts';
	import { app } from '#lib/state.svelte.ts';
	import { canWriteFolders, pickFolder, writeExport, type FolderProgress } from '#lib/folderExport.ts';
	import FolderPicker from './FolderPicker.svelte';

	let {
		ids = [],
		albums = [],
		library = false,
		title,
		onClose
	}: {
		/** photos and videos to export */
		ids?: string[];
		/** or albums */
		albums?: number[];
		/** or everything */
		library?: boolean;
		/** name of the ZIP / folder */
		title?: string;
		onClose: () => void;
	} = $props();

	// The share sheet only where a ZIP can't be downloaded (an iOS Home Screen app) or wouldn't be
	// wanted (an iPhone, where Save to Photos is the point). Everything else gets the full export.
	const viaShare = iosStandalone || (isIOS && !matchMedia('(min-width: 700px)').matches);

	// svelte-ignore state_referenced_locally
	const albumList = albums.map((id) => app.albums.find((a) => a.id === id)).filter((a) => a != null);
	/** The photos covered (for counts, and what phones fetch): albums oldest to newest. */
	const assets = $derived.by(() => {
		if (library) return app.assets;
		if (albumList.length) {
			const seen = new Set<string>();
			const out = [];
			for (const al of albumList)
				for (const id of al.assetIds) {
					const a = app.byId.get(id);
					if (a && !seen.has(id)) (seen.add(id), out.push(a));
				}
			return sortByLocalTime(out);
		}
		return ids.map((i) => app.byId.get(i)).filter((a) => a != null);
	});
	const edited = $derived(assets.filter(isEdited).length);
	const pixelEdited = $derived(assets.filter((a) => a.ev > 0 && a.dur == null).length);
	const live = $derived(assets.filter((a) => a.live && a.dur == null).length);

	let content = $state<ExportOptions['content']>('edited');
	let fmt = $state<ImageFmt>('jpeg');
	let withMotion = $state(true);
	let sidecar = $state<ExportOptions['sidecar']>('none');
	// svelte-ignore state_referenced_locally
	let organize = $state<ExportOptions['organize']>(library ? 'months' : albumList.length > 1 ? 'albums' : 'flat');
	// on the Mac itself, straight into a folder (faster, resumable); the last one is remembered
	let target = $state<'zip' | 'folder' | 'files'>(app.local ? 'folder' : 'zip');
	let folder = $state<string | null>(app.local ? localStorage.getItem('exportFolder') : null);
	let picking = $state(false);

	let phase = $state<'choose' | 'fetching' | 'ready' | 'running' | 'done' | 'error'>('choose');
	let done = $state(0);
	let total = $state(0);
	let bytes = $state(0);
	let files = $state<File[]>([]);
	let error = $state('');
	let status = $state<ExportStatus | null>(null);
	let controller: AbortController | null = null;
	let progress = $state<FolderProgress | null>(null);
	let folderLabel = $state('');
	let poll: ReturnType<typeof setTimeout> | undefined;
	onDestroy(() => clearTimeout(poll));

	const what = $derived(
		library
			? 'Library'
			: albumList.length === 1
				? `“${albumList[0].title}”`
				: albumList.length
					? `${albumList.length} albums`
					: `${assets.length} ${assets.length === 1 ? 'item' : 'items'}`
	);
	const name = $derived(title ?? (library ? 'Photos Library' : albumList.length === 1 ? albumList[0].title : undefined));

	// ---- how big it is (and whether this device may have it as a ZIP)

	let estimate = $state<ExportEstimate | null>(null);
	let estimateSeq = 0;
	$effect(() => {
		const o = viaShare ? { ...options(), sidecar: 'none' as const, organize: 'flat' as const } : options();
		const seq = ++estimateSeq;
		const t = setTimeout(async () => {
			try {
				const e = await api.estimateExport(o);
				if (seq === estimateSeq) estimate = e;
			} catch {
				/* the export itself reports problems */
			}
		}, 250);
		return () => clearTimeout(t);
	});
	const zipAllowed = $derived(app.local || estimate?.zip !== false);
	// too big for a ZIP: a folder instead, where the browser can write one
	$effect(() => {
		if (!zipAllowed && target === 'zip' && canWriteFolders) target = 'files';
	});
	const GB = 1e9;
	const device = /iPhone/.test(navigator.userAgent) ? 'iPhone' : 'iPad';
	const size = (n: number) => (n >= GB ? `${(n / GB).toFixed(n >= 10 * GB ? 0 : 1)} GB` : mb(n));
	const count = (n: number) => n.toLocaleString();
	const skippedCount = $derived(target === 'files' ? (progress?.skipped.length ?? 0) : (status?.skippedCount ?? 0));

	// ---- phones: fetch the files and share them

	/** What to fetch: [url, fallback name, use this name even if the server names it]. */
	function plan(): [string, string, boolean?][] {
		const out: [string, string, boolean?][] = [];
		for (const a of assets) {
			const base = a.name.replace(/\.[^.]*$/, '');
			const ext0 = a.name.split('.').pop();
			if (edited && content !== 'original' && isEdited(a)) {
				const ext = a.ev > 0 && a.dur == null ? (fmt === 'heic' ? 'heic' : 'jpg') : ext0;
				out.push([exportUrl(a.id, fmt), `${base}.${ext}`]);
				// both: the original next to it, named apart (no folders in a share sheet)
				if (content === 'both') out.push([originalUrl(a.id), `${base} (Original).${ext0}`, true]);
			} else out.push([originalUrl(a.id), a.name]);
			if (withMotion && a.live && a.dur == null) out.push([motionDownloadUrl(a.id), `${base}.MOV`]);
		}
		return out;
	}

	function nameOf(res: Response, fallback: string) {
		const m = /filename\*=UTF-8''([^;]+)/i.exec(res.headers.get('content-disposition') ?? '');
		return m ? decodeURIComponent(m[1]) : fallback;
	}

	async function share() {
		const list = plan();
		phase = 'fetching';
		total = list.length;
		done = 0;
		bytes = 0;
		controller = new AbortController();
		try {
			const out: File[] = [];
			for (const [url, fallback, keepName] of list) {
				const res = await fetch(url, { signal: controller.signal });
				if (!res.ok) throw new Error((await res.json().catch(() => null))?.error ?? `HTTP ${res.status}`);
				const blob = await res.blob();
				bytes += blob.size;
				out.push(new File([blob], keepName ? fallback : nameOf(res, fallback), { type: blob.type }));
				done++;
			}
			if (!navigator.canShare?.({ files: out })) throw new Error("These files can't be shared from here.");
			files = out;
			phase = 'ready'; // the share sheet needs a fresh tap
		} catch (e) {
			if ((e as Error).name === 'AbortError') return;
			error = (e as Error).message;
			phase = 'error';
		}
	}

	async function shareNow() {
		try {
			await navigator.share({ files });
			onClose();
		} catch (e) {
			if ((e as Error).name !== 'AbortError') {
				error = (e as Error).message;
				phase = 'error';
			}
		}
	}

	// ---- desktop: the Mac makes a ZIP (or a folder)

	function options(): ExportOptions {
		return {
			...(library ? { library: true } : albumList.length ? { albums: albumList.map((a) => a.id) } : { ids: assets.map((a) => a.id) }),
			content: edited ? content : 'original',
			editFormat: fmt,
			livePhotoVideo: withMotion,
			sidecar,
			organize
		};
	}

	async function start() {
		if (target === 'folder' && !folder) return void (picking = true);
		if (target === 'files') return startFiles();
		error = '';
		try {
			status = await api.startExport(options(), target, folder ?? undefined, name);
		} catch (e) {
			error = (e as Error).message;
			phase = 'error';
			return;
		}
		phase = 'running';
		if (target === 'zip') downloadUrl(exportDownloadUrl(status.id));
		watch(status.id);
	}

	/** The browser writes the files into a folder on this computer. */
	async function startFiles() {
		error = '';
		let dir: FileSystemDirectoryHandle | null;
		try {
			dir = await pickFolder(); // first, while the click still counts
		} catch (e) {
			error = (e as Error).message;
			return;
		}
		if (!dir) return;
		controller = new AbortController();
		try {
			status = await api.startExport(options(), 'files', undefined, name);
			folderLabel = `${dir.name}/${status.name}`;
			phase = 'running';
			progress = await writeExport(status.id, dir, status.name, controller.signal, (p) => (progress = { ...p }));
			phase = 'done';
		} catch (e) {
			if (controller.signal.aborted) return;
			error = (e as Error).message;
			phase = 'error';
		}
	}

	function watch(id: string) {
		poll = setTimeout(async () => {
			try {
				status = await api.exportStatus(id);
			} catch {
				/* keep trying */
			}
			if (status?.state === 'done') phase = 'done';
			else if (status?.state === 'failed' || status?.state === 'cancelled') {
				error = status.error ?? 'Export failed.';
				phase = status.state === 'cancelled' ? 'choose' : 'error';
				if (status.state === 'cancelled') onClose();
			} else watch(id);
		}, 700);
	}

	function cancel() {
		controller?.abort();
		if (phase === 'running' && status && target !== 'files') api.cancelExport(status.id).catch(() => {});
		onClose();
	}

	const mb = (n: number) => (n >= 10e6 ? (n / 1e6).toFixed(0) : (n / 1e6).toFixed(1)) + ' MB';
</script>

<div class="scrim" role="presentation" onclick={phase === 'running' ? undefined : cancel}></div>
<div class="sheet" class:wide={!viaShare} role="dialog" aria-modal="true" aria-label="Export">
	{#if phase === 'choose'}
		<h3>Export {what}</h3>
		{#if edited}
			<fieldset>
				<legend>{edited} edited {edited === 1 ? 'item' : 'items'}</legend>
				<label><input type="radio" bind:group={content} value="edited" /> With edits</label>
				<label><input type="radio" bind:group={content} value="original" /> Originals</label>
				<label
					><input type="radio" bind:group={content} value="both" /> Both
					<span class="muted">{viaShare ? '(originals named “… (Original)”)' : '(originals of edited items in an Originals folder)'}</span></label
				>
				{#if content !== 'original' && pixelEdited}
					<div class="fmt">
						<span class="muted">Edited photos as</span>
						<label><input type="radio" bind:group={fmt} value="jpeg" /> JPEG</label>
						<label><input type="radio" bind:group={fmt} value="heic" /> HEIC</label>
					</div>
				{/if}
				<p class="note muted">Photo edits, adjusted dates and video trims.</p>
			</fieldset>
		{/if}
		{#if live}
			<fieldset>
				<legend>Live Photos</legend>
				<label><input type="checkbox" bind:checked={withMotion} /> Include the video (.MOV next to the photo)</label>
				<p class="note muted">
					{#if viaShare}
						The iPhone saves them as a photo and a separate video: a web app can't save Live Photos. Imported together into Photos
						on a Mac, they become a Live Photo again.
					{:else}
						Import the photo and its .MOV together into Photos to get the Live Photo back (edits included).
					{/if}
				</p>
			</fieldset>
		{/if}
		{#if !viaShare}
			<fieldset>
				<legend>Details</legend>
				<label class="row"
					>Sidecar files
					<select bind:value={sidecar}>
						<option value="none">None</option>
						<option value="google">Google Photos (.json)</option>
						<option value="xmp">XMP (.xmp)</option>
					</select>
				</label>
				<label class="row"
					>Folders
					<select bind:value={organize}>
						<option value="flat">None (all in one)</option>
						{#if albumList.length}<option value="albums">One per album</option>{/if}
						<option value="years">By year (2024)</option>
						<option value="months">By month (2024/2024-03)</option>
					</select>
				</label>
				{#if sidecar !== 'none'}
					<p class="note muted">
						{sidecar === 'google'
							? 'Takeout-style JSON next to each file: date, place, description, favourite, people.'
							: 'XMP next to each photo: date and time zone, place, description, favourite (5 stars), albums and people as keywords, named faces.'}
					</p>
				{/if}
			</fieldset>
			<fieldset>
				<legend>Save as</legend>
				<p class="note muted">
					{#if estimate}
						{count(estimate.items)} {estimate.items === 1 ? 'photo or video' : 'photos and videos'}, {count(estimate.files)}
						{estimate.files === 1 ? 'file' : 'files'}, about {size(estimate.bytes)}
					{:else}
						Counting…
					{/if}
				</p>
				{#if app.local}
					<label><input type="radio" bind:group={target} value="folder" /> A folder on this Mac</label>
					{#if target === 'folder'}
						<div class="folder">
							<span class="muted path">{folder ?? 'No folder chosen'}</span>
							<button class="btn" onclick={() => (picking = true)}>Choose…</button>
						</div>
						<p class="note muted">Exporting again into the same folder continues where it stopped.</p>
					{/if}
					<label><input type="radio" bind:group={target} value="zip" /> ZIP download</label>
				{:else}
					<label class:off={!zipAllowed}><input type="radio" bind:group={target} value="zip" disabled={!zipAllowed} /> ZIP download</label>
					{#if canWriteFolders}
						<label><input type="radio" bind:group={target} value="files" /> A folder on this computer</label>
					{/if}
					{#if !zipAllowed && estimate}
						<p class="note muted">
							A ZIP is limited to {count(estimate.zipLimitItems)} photos and videos or {size(estimate.zipLimitBytes)} from another device:
							it's made in one go, and a dropped connection means starting over.
							{canWriteFolders
								? 'A folder gets the files one by one, and an interrupted export picks up where it stopped.'
								: 'Open this page in Chrome or Edge to save into a folder, export on the Mac itself, or choose fewer.'}
						</p>
					{:else if target === 'files'}
						<p class="note muted">
							You choose a folder; the files go into “{name ?? 'Photos …'}” inside it. Exporting again into the same folder continues
							where it stopped.
						</p>
					{/if}
					{#if isIOS && target === 'zip' && estimate && estimate.bytes > GB}
						<p class="warn">
							About {size(estimate.bytes)}: this {device} needs that much free space,
							and the download can't resume if it stops.
						</p>
					{/if}
				{/if}
			</fieldset>
			{#if error}<p class="error">{error}</p>{/if}
			<button
				class="btn primary"
				onclick={start}
				disabled={(target === 'folder' && !folder) || (target === 'zip' && (!zipAllowed || (!app.local && !estimate)))}>Export</button
			>
		{:else}
			{@const n = plan().length}
			{#if estimate}<p class="note muted">{count(n)} {n === 1 ? 'file' : 'files'}, about {size(estimate.bytes)}</p>{/if}
			{#if estimate && estimate.bytes > GB}
				<p class="warn">
					About {size(estimate.bytes)}: the files are held in memory until you share them, and above 1 GB the app can run out of
					memory and reload. Export fewer at a time, or from a computer.
				</p>
			{/if}
			<button class="btn primary" onclick={share}>Download {count(n)} {n === 1 ? 'file' : 'files'}</button>
		{/if}
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'fetching'}
		<h3>Downloading… {done} of {total}</h3>
		<p class="muted">
			Copying the files from the Mac to this device ({mb(bytes)} so far). Edited photos are rendered first.<br />They are kept
			in memory until you share them; nothing is saved yet.
		</p>
		<div class="bar"><div style:width={`${(done / Math.max(1, total)) * 100}%`}></div></div>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'ready'}
		<h3>Ready</h3>
		<p class="muted">{files.length} files ({mb(bytes)}). Tap Share… and choose Save {files.length === 1 ? 'Image' : `${files.length} Items`} or Save to Files.</p>
		<button class="btn primary" onclick={shareNow}>Share…</button>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'running'}
		{@const d = target === 'files' ? (progress?.done ?? 0) : (status?.done ?? 0)}
		{@const t = target === 'files' ? (progress?.total ?? 0) : (status?.total ?? 0)}
		<h3>Exporting… {count(d)} of {count(t)} files</h3>
		<p class="muted">
			{target === 'zip'
				? 'The ZIP downloads while the Mac makes the files (edited photos are rendered at full size).'
				: target === 'files'
					? `Saving into ${folderLabel} (${size(progress?.bytes ?? 0)} of about ${size(status?.bytes ?? 0)}). Keep this tab open.`
					: `Writing into ${status?.folder ?? 'the folder'}.`}
		</p>
		<div class="bar"><div style:width={`${(d / Math.max(1, t)) * 100}%`}></div></div>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'done'}
		<h3>Exported</h3>
		<p class="muted">
			{count(status?.total ?? 0)} files {target === 'zip'
				? `in “${status?.name}.zip” (in your downloads)`
				: target === 'files'
					? `in ${folderLabel}`
					: `in ${status?.folder}`}.
		</p>
		{#if skippedCount}
			<p class="warn">
				{count(skippedCount)}
				{skippedCount === 1 ? "file wasn't" : "files weren't"} available (moved or deleted since the last scan); they're listed in “Export
				problems.txt”.
			</p>
		{/if}
		{#if target === 'folder' && status}
			<button class="btn primary" onclick={() => status && api.revealExport(status.id)}>Show in Finder</button>
		{/if}
		<button class="btn cancel" onclick={onClose}>Done</button>
	{:else}
		<h3>Export failed</h3>
		<p class="muted">{error}</p>
		<button class="btn cancel" onclick={onClose}>Close</button>
	{/if}
</div>

{#if picking}
	<FolderPicker
		title="Export into…"
		allowCreate
		onPick={(p) => {
			folder = p;
			localStorage.setItem('exportFolder', p);
			picking = false;
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
		bottom: calc(16px + env(safe-area-inset-bottom));
		transform: translateX(-50%);
		width: min(380px, calc(100vw - 24px));
		max-height: calc(100dvh - 32px);
		overflow: auto;
		background: var(--bg);
		color: var(--fg);
		border-radius: 14px;
		padding: 16px;
		display: flex;
		flex-direction: column;
		gap: 8px;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
	}
	.sheet.wide {
		width: min(460px, calc(100vw - 24px));
		top: 50%;
		bottom: auto;
		transform: translate(-50%, -50%);
	}
	h3 {
		margin: 0 0 4px;
		font-size: 16px;
		text-align: center;
	}
	p {
		margin: 0 0 6px;
		text-align: center;
		font-size: 13px;
	}
	fieldset {
		border: none;
		margin: 0;
		padding: 10px 14px;
		border-radius: 10px;
		background: var(--bg-elevated);
		display: flex;
		flex-direction: column;
		gap: 6px;
		font-size: 14px;
	}
	legend {
		float: left;
		font-weight: 600;
		margin-bottom: 2px;
	}
	label {
		display: flex;
		align-items: center;
		gap: 8px;
	}
	label.row {
		justify-content: space-between;
	}
	select {
		font: inherit;
		font-size: 14px;
		color: inherit;
		background: var(--bg);
		border: 0.5px solid var(--separator);
		border-radius: 6px;
		padding: 3px 6px;
	}
	.fmt {
		display: flex;
		gap: 12px;
		padding-left: 24px;
		font-size: 13px;
	}
	.note {
		text-align: left;
		font-size: 12px;
		margin: 2px 0 0;
	}
	.folder {
		display: flex;
		align-items: center;
		gap: 8px;
		padding-left: 24px;
	}
	.path {
		flex: 1;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: 12px;
	}
	.error {
		color: var(--danger);
	}
	.warn {
		margin: 0;
		font-size: 13px;
		color: var(--warning, #b26a00);
	}
	label.off {
		opacity: 0.45;
	}
	.bar {
		height: 4px;
		border-radius: 2px;
		background: var(--bg-elevated);
		overflow: hidden;
		margin: 0 0 6px;
	}
	.bar > div {
		height: 100%;
		background: var(--accent);
		transition: width 0.2s;
	}
	.cancel {
		margin-top: 4px;
	}
</style>
