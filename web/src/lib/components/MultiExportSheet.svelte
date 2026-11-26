<script lang="ts">
	// Exporting a selection, albums or the whole library.
	//
	// Desktop: the Mac builds the export — originals, with edits, or both (the originals of edited
	// items in an Originals/ folder); Live Photo videos; Google Photos JSON or XMP sidecars; flat, by
	// album or by month — and streams it as one ZIP, or (in local mode) writes it into a folder on the Mac.
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
		type ExportOptions,
		type ExportStatus,
		type ImageFmt
	} from '#lib/api.ts';
	import { downloadUrl, iosStandalone } from '#lib/download.ts';
	import { isEdited } from '#lib/gridView.svelte.ts';
	import { sortByLocalTime } from '#lib/dates.ts';
	import { app } from '#lib/state.svelte.ts';
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

	const touch = matchMedia('(pointer: coarse)').matches;
	const viaShare = touch || iosStandalone;

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
	let target = $state<'zip' | 'folder'>('zip');
	let folder = $state<string | null>(null);
	let picking = $state(false);

	let phase = $state<'choose' | 'fetching' | 'ready' | 'running' | 'done' | 'error'>('choose');
	let done = $state(0);
	let total = $state(0);
	let bytes = $state(0);
	let files = $state<File[]>([]);
	let error = $state('');
	let status = $state<ExportStatus | null>(null);
	let controller: AbortController | null = null;
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

	// ---- phones: fetch the files and share them

	/** What to fetch: [url, fallback name]. */
	function plan(): [string, string][] {
		const out: [string, string][] = [];
		for (const a of assets) {
			const base = a.name.replace(/\.[^.]*$/, '');
			if (content !== 'original' && isEdited(a)) {
				const ext = a.ev > 0 && a.dur == null ? (fmt === 'heic' ? 'heic' : 'jpg') : a.name.split('.').pop();
				out.push([exportUrl(a.id, fmt), `${base}.${ext}`]);
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
		if (list.length > 500 && !confirm(`Fetch ${list.length} files to this device before sharing? That can take a while and a lot of memory.`)) return;
		phase = 'fetching';
		total = list.length;
		done = 0;
		bytes = 0;
		controller = new AbortController();
		try {
			const out: File[] = [];
			for (const [url, fallback] of list) {
				const res = await fetch(url, { signal: controller.signal });
				if (!res.ok) throw new Error((await res.json().catch(() => null))?.error ?? `HTTP ${res.status}`);
				const blob = await res.blob();
				bytes += blob.size;
				out.push(new File([blob], nameOf(res, fallback), { type: blob.type }));
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
			content,
			editFormat: fmt,
			livePhotoVideo: withMotion,
			sidecar,
			organize
		};
	}

	async function start() {
		if (target === 'folder' && !folder) return void (picking = true);
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
		if (phase === 'running' && status) api.cancelExport(status.id).catch(() => {});
		onClose();
	}

	const mb = (n: number) => (n >= 10e6 ? (n / 1e6).toFixed(0) : (n / 1e6).toFixed(1)) + ' MB';
</script>

<div class="scrim" role="presentation" onclick={phase === 'running' ? undefined : cancel}></div>
<div class="sheet" class:wide={!viaShare} role="dialog" aria-modal="true" aria-label="Export">
	{#if phase === 'choose'}
		<h3>Export {what}</h3>
		<fieldset>
			<legend>Photos and videos</legend>
			<label><input type="radio" bind:group={content} value="edited" /> With edits</label>
			<label><input type="radio" bind:group={content} value="original" /> Originals</label>
			{#if !viaShare}
				<label><input type="radio" bind:group={content} value="both" /> Both <span class="muted">(originals of edited items in an Originals folder)</span></label>
			{/if}
			{#if content !== 'original' && (pixelEdited || library || albumList.length)}
				<div class="fmt">
					<span class="muted">Edited photos as</span>
					<label><input type="radio" bind:group={fmt} value="jpeg" /> JPEG</label>
					<label><input type="radio" bind:group={fmt} value="heic" /> HEIC</label>
				</div>
			{/if}
			{#if !library && !albumList.length}
				<p class="note muted">{edited ? `${edited} edited (photo edits, adjusted dates, trims).` : 'None of these is edited.'}</p>
			{/if}
		</fieldset>
		{#if live || library || albumList.length}
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
				<label><input type="radio" bind:group={target} value="zip" /> ZIP download</label>
				{#if app.local}
					<label><input type="radio" bind:group={target} value="folder" /> A folder on this Mac</label>
					{#if target === 'folder'}
						<div class="folder">
							<span class="muted path">{folder ?? 'No folder chosen'}</span>
							<button class="btn" onclick={() => (picking = true)}>Choose…</button>
						</div>
					{/if}
				{/if}
			</fieldset>
			{#if error}<p class="error">{error}</p>{/if}
			<button class="btn primary" onclick={start} disabled={target === 'folder' && !folder}>Export</button>
		{:else}
			{@const count = plan().length}
			<button class="btn primary" onclick={share}>Download {count} {count === 1 ? 'file' : 'files'}</button>
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
		<h3>Exporting… {status?.done ?? 0} of {status?.total ?? 0} files</h3>
		<p class="muted">
			{target === 'zip'
				? 'The ZIP downloads while the Mac makes the files (edited photos are rendered at full size).'
				: `Writing into ${status?.folder ?? 'the folder'}.`}
		</p>
		<div class="bar"><div style:width={`${((status?.done ?? 0) / Math.max(1, status?.total ?? 1)) * 100}%`}></div></div>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'done'}
		<h3>Exported</h3>
		<p class="muted">
			{status?.total} files {target === 'zip' ? `in “${status?.name}.zip” (in your downloads)` : `in ${status?.folder}`}.
		</p>
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
