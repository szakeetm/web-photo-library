<script lang="ts">
	// Export: original, the edit rendered at full resolution on the Mac, or (videos that needed one) the
	// converted copy. Phones get the share sheet (needs a fresh tap once the file is ready); desktops
	// download. Videos download as links (they can be hundreds of MB), except in an iOS Home Screen app,
	// where any download traps the app: there they are read into memory for the share sheet too.
	import { api, CLIENT_API_VERSION, exportUrl, originalUrl, videoDownloadUrl, type CatalogAsset } from '#lib/api.ts';
	import { iosStandalone, isIOS, saveBlob } from '#lib/download.ts';

	let { asset, onClose }: { asset: CatalogAsset; onClose: () => void } = $props();

	// Saving goes through: waiting (the Mac answers; for an edit it renders it first), downloading (bytes
	// arrive on this device), assembling (the pieces become one file in memory), ready (Share…).
	let phase = $state<'choose' | 'waiting' | 'downloading' | 'assembling' | 'ready' | 'error'>('choose');
	/** The chosen file is an edit the Mac renders before sending it. */
	let rendering = $state(false);
	let file = $state<File | null>(null);
	let error = $state('');
	let controller: AbortController | null = null;
	/** iPhone/iPad: the share sheet (Save Image, Save to Files); everything else downloads. */
	const touch = isIOS;
	const isVideo = $derived(asset.dur != null);
	// a date that is not the file's: the user's, or Apple Photos' (written into the exported file)
	const dated = $derived(asset.md === true || asset.pd === true);
	/** Bytes received / expected while preparing (null when the size isn't known). */
	let received = $state(0);
	let expected = $state<number | null>(null);
	/** A converted copy of the video exists. */
	let converted = $state(false);

	$effect(() => {
		if (asset.dur == null) return;
		const id = asset.id;
		api.videoConverted(id).then((c) => { if (id === asset.id) converted = c; }).catch(() => {});
	});

	const convertedName = $derived(asset.name.replace(/\.[^.]*$/, '') + '-converted.mp4');
	const fraction = $derived(expected ? Math.min(1, received / expected) : null);
	const mb = (n: number) => (n >= 10e6 ? (n / 1e6).toFixed(0) : (n / 1e6).toFixed(1)) + ' MB';

	function filename(res: Response, fallback: string) {
		const cd = res.headers.get('content-disposition') ?? '';
		const m = /filename\*=UTF-8''([^;]+)/i.exec(cd);
		return m ? decodeURIComponent(m[1]) : fallback;
	}

	async function prepare(url: string, fallback: string, render = false) {
		rendering = render;
		received = 0;
		expected = null;
		phase = 'waiting';
		controller = new AbortController();
		try {
			const res = await fetch(url, { signal: controller.signal, headers: { 'X-Client-API-Version': String(CLIENT_API_VERSION) } });
			if (!res.ok) throw new Error((await res.json().catch(() => null))?.error ?? `HTTP ${res.status}`);
			expected = Number(res.headers.get('content-length')) || null;
			phase = 'downloading';
			const chunks: Uint8Array[] = [];
			const reader = res.body!.getReader();
			for (;;) {
				const { done, value } = await reader.read();
				if (done) break;
				chunks.push(value);
				received += value.byteLength;
			}
			phase = 'assembling';
			await new Promise((r) => setTimeout(r, 50)); // let the step show before the (blocking) join
			const type = res.headers.get('content-type')?.split(';')[0] ?? '';
			file = new File(chunks as BlobPart[], filename(res, fallback), { type });
			if ((touch || iosStandalone) && navigator.canShare?.({ files: [file] })) {
				phase = 'ready';
			} else if (iosStandalone) {
				// A download would trap the Home Screen app in iOS's file preview.
				throw new Error("This file can't be shared from here.");
			} else {
				saveBlob(file);
				onClose();
			}
		} catch (e) {
			if ((e as Error).name === 'AbortError') return;
			error = (e as Error).message;
			phase = 'error';
		}
	}

	async function share() {
		if (!file) return;
		try {
			await navigator.share({ files: [file] });
			onClose();
		} catch (e) {
			if ((e as Error).name !== 'AbortError') {
				error = (e as Error).message;
				phase = 'error';
			}
		}
	}

	function cancel() {
		controller?.abort();
		onClose();
	}
</script>

<div class="scrim" role="presentation" onclick={cancel}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-label="Export">
	{#if phase === 'choose'}
		<h3>Export</h3>
		{#if isVideo && (asset.tr || dated)}
			{#if iosStandalone}
				<button class="opt" onclick={() => prepare(exportUrl(asset.id, 'jpeg'), asset.name, true)}>
					With edits <span>{asset.tr ? 'trimmed' : asset.md ? 'adjusted date' : 'date from Photos'}, not re-encoded</span>
				</button>
			{:else}
				<a class="opt" href={exportUrl(asset.id, 'jpeg')} download={asset.name} onclick={onClose}>
					With edits <span>{asset.tr ? 'trimmed' : asset.md ? 'adjusted date' : 'date from Photos'}, not re-encoded</span>
				</a>
			{/if}
		{/if}
		{#if !isVideo && dated && asset.ev === 0}
			<button class="opt" onclick={() => prepare(exportUrl(asset.id, 'jpeg'), asset.name, true)}>
				With {asset.md ? 'adjusted date' : 'the date from Photos'} <span>same file, {asset.md ? 'new date' : 'date written in'}</span>
			</button>
		{/if}
		{#if asset.ev > 0}
			<button class="opt" onclick={() => prepare(exportUrl(asset.id, 'jpeg'), `${asset.name}-edited.jpg`, true)}>
				Edited photo <span>JPEG, full resolution</span>
			</button>
			<button class="opt" onclick={() => prepare(exportUrl(asset.id, 'heic'), `${asset.name}-edited.heic`, true)}>
				Edited photo <span>HEIC, smaller file</span>
			</button>
		{/if}
		{#if isVideo && !iosStandalone}
			<!-- Videos can be hundreds of MB: let the browser download them instead of reading them into memory. -->
			<a class="opt" href={originalUrl(asset.id)} download={asset.name} onclick={onClose}>
				Original <span>unchanged file</span>
			</a>
			{#if converted}
				<a class="opt" href={videoDownloadUrl(asset.id)} download={convertedName} onclick={onClose}>
					Converted <span>MP4 (HEVC), for Apple devices, phones and most PCs</span>
				</a>
			{/if}
		{:else if isVideo}
			<button class="opt" onclick={() => prepare(originalUrl(asset.id), asset.name)}>
				Original <span>unchanged file</span>
			</button>
			{#if converted}
				<button class="opt" onclick={() => prepare(videoDownloadUrl(asset.id), convertedName)}>
					Converted <span>MP4 (HEVC), for Apple devices, phones and most PCs</span>
				</button>
			{/if}
		{:else}
			<button class="opt" onclick={() => prepare(originalUrl(asset.id), asset.name)}>
				Original <span>unchanged file{asset.ev > 0 || asset.md ? ', without edits' : asset.pd ? ', without the date from Photos' : ''}</span>
			</button>
		{/if}
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'waiting'}
		<h3>{rendering ? 'Rendering…' : 'Requesting…'}</h3>
		<p class="muted">
			{rendering
				? 'The Mac is applying your edits to the full-resolution original. This takes a few seconds.'
				: 'Asking the Mac for the file.'}
		</p>
		<div class="bar indeterminate"><div></div></div>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'downloading'}
		<h3>Downloading… {fraction != null ? `${Math.round(fraction * 100)}%` : ''}</h3>
		<p class="muted">
			Copying {isVideo ? 'the video' : 'the photo'} from the Mac to this device:
			{expected ? `${mb(received)} of ${mb(expected)}` : mb(received)}.
			{#if iosStandalone || touch}<br />It is kept in memory until you share it; nothing is saved yet.{/if}
		</p>
		<div class="bar" class:indeterminate={fraction == null}><div style:width={fraction != null ? `${fraction * 100}%` : null}></div></div>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'assembling'}
		<h3>Preparing the file…</h3>
		<p class="muted">Putting the downloaded {mb(received)} together into one file on this device.</p>
		<div class="bar indeterminate"><div></div></div>
	{:else if phase === 'ready'}
		<h3>Ready</h3>
		<p class="muted">{file?.name}{file ? ` (${mb(file.size)})` : ''}</p>
		<p class="muted">Tap Share… and choose {isVideo ? 'Save Video' : 'Save Image'} (Photos) or Save to Files.</p>
		<button class="btn primary" onclick={share}>Share…</button>
		{#if !iosStandalone}
			<button class="btn cancel" onclick={() => file && saveBlob(file)}>Save to Files</button>
		{/if}
		<button class="btn cancel" onclick={cancel}>Close</button>
	{:else}
		<h3>Export failed</h3>
		<p class="muted">{error}</p>
		<button class="btn cancel" onclick={cancel}>Close</button>
	{/if}
</div>

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
		background: var(--bg);
		color: var(--fg);
		border-radius: 14px;
		padding: 16px;
		display: flex;
		flex-direction: column;
		gap: 8px;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
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
		overflow-wrap: anywhere;
	}
	.opt {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 2px;
		border: none;
		background: var(--bg-elevated);
		border-radius: 10px;
		padding: 10px 14px;
		font: inherit;
		font-weight: 500;
		cursor: pointer;
		text-align: left;
		color: inherit;
		text-decoration: none;
	}
	.opt span {
		font-weight: 400;
		font-size: 12px;
		color: var(--fg-secondary);
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
		width: 0;
		background: var(--accent, #0a84ff);
		transition: width 0.15s linear;
	}
	.bar.indeterminate > div {
		width: 30%;
		animation: slide 1.2s ease-in-out infinite;
	}
	@keyframes slide {
		from {
			transform: translateX(-100%);
		}
		to {
			transform: translateX(340%);
		}
	}
	.cancel {
		width: 100%;
	}
	.btn.primary {
		width: 100%;
	}
</style>
