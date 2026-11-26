<script lang="ts">
	// Downloading a selection: originals or, for edited photos, the edits (rendered at full resolution
	// on the Mac), plus Live Photo videos on request. Desktops get one download per file; phones fetch
	// the files into memory and hand them to the share sheet (a download would trap an iOS Home Screen
	// app). Live Photos: a still and its MOV share a content identifier (kept in edited exports too), so
	// importing both into Photos on a Mac pairs them again. A web page can't save a Live Photo into the
	// iPhone's Photos library: there they are saved as a photo and a separate video.
	import { exportUrl, motionDownloadUrl, originalUrl, type ImageFmt } from '#lib/api.ts';
	import { downloadUrl, iosStandalone } from '#lib/download.ts';
	import { app } from '#lib/state.svelte.ts';

	let { ids, onClose }: { ids: string[]; onClose: () => void } = $props();

	const assets = $derived(ids.map((i) => app.byId.get(i)).filter((a) => a != null));
	const edited = $derived(assets.filter((a) => a.ev > 0 && a.dur == null).length);
	const live = $derived(assets.filter((a) => a.live && a.dur == null).length);
	const touch = matchMedia('(pointer: coarse)').matches;
	const viaShare = touch || iosStandalone;

	let withEdits = $state(true);
	let fmt = $state<ImageFmt>('jpeg');
	let withMotion = $state(true);

	let phase = $state<'choose' | 'fetching' | 'ready' | 'error'>('choose');
	let done = $state(0);
	let total = $state(0);
	let bytes = $state(0);
	let files = $state<File[]>([]);
	let error = $state('');
	let controller: AbortController | null = null;

	/** What to fetch: [url, fallback name]. */
	function plan(): [string, string][] {
		const out: [string, string][] = [];
		for (const a of assets) {
			const base = a.name.replace(/\.[^.]*$/, '');
			if (withEdits && a.ev > 0 && a.dur == null) out.push([exportUrl(a.id, fmt), `${base}-edited.${fmt === 'heic' ? 'heic' : 'jpg'}`]);
			else out.push([originalUrl(a.id), a.name]);
			if (withMotion && a.live && a.dur == null) out.push([motionDownloadUrl(a.id), `${base}.MOV`]);
		}
		return out;
	}

	function nameOf(res: Response, fallback: string) {
		const m = /filename\*=UTF-8''([^;]+)/i.exec(res.headers.get('content-disposition') ?? '');
		return m ? decodeURIComponent(m[1]) : fallback;
	}

	async function start() {
		const list = plan();
		if (!viaShare) {
			// one download per file; browsers may ask once to allow multiple downloads
			for (const [url] of list) {
				downloadUrl(url);
				await new Promise((r) => setTimeout(r, 250));
			}
			onClose();
			return;
		}
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

	async function share() {
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

	function cancel() {
		controller?.abort();
		onClose();
	}

	const mb = (n: number) => (n >= 10e6 ? (n / 1e6).toFixed(0) : (n / 1e6).toFixed(1)) + ' MB';
	const count = $derived(plan().length);
</script>

<div class="scrim" role="presentation" onclick={cancel}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-label="Download">
	{#if phase === 'choose'}
		<h3>Download {assets.length} {assets.length === 1 ? 'item' : 'items'}</h3>
		{#if edited}
			<fieldset>
				<legend>{edited} edited {edited === 1 ? 'photo' : 'photos'}</legend>
				<label><input type="radio" bind:group={withEdits} value={true} /> With edits</label>
				<label><input type="radio" bind:group={withEdits} value={false} /> Originals (without edits)</label>
				{#if withEdits}
					<div class="fmt">
						<label><input type="radio" bind:group={fmt} value="jpeg" /> JPEG</label>
						<label><input type="radio" bind:group={fmt} value="heic" /> HEIC (smaller)</label>
					</div>
				{/if}
			</fieldset>
		{/if}
		{#if live}
			<fieldset>
				<legend>{live} Live {live === 1 ? 'Photo' : 'Photos'}</legend>
				<label><input type="checkbox" bind:checked={withMotion} /> Include the video (.MOV next to the photo)</label>
				<p class="note muted">
					{#if viaShare}
						The iPhone saves them as a photo and a separate video: a web app can't save Live Photos. Imported together
						into Photos on a Mac, they become a Live Photo again.
					{:else}
						Import the photo and its .MOV together into Photos to get the Live Photo back (edits included).
					{/if}
				</p>
			</fieldset>
		{/if}
		<button class="btn primary" onclick={start}>Download {count} {count === 1 ? 'file' : 'files'}</button>
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
		<button class="btn primary" onclick={share}>Share…</button>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else}
		<h3>Download failed</h3>
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
	.fmt {
		display: flex;
		gap: 16px;
		padding-left: 24px;
		font-size: 13px;
	}
	.note {
		text-align: left;
		font-size: 12px;
		margin: 2px 0 0;
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
