<script lang="ts">
	// Export: original, or the edit rendered at full resolution on the Mac. Phones get the share sheet
	// (needs a fresh tap once the file is ready); desktops download.
	import { CLIENT_API_VERSION, exportUrl, originalUrl, type CatalogAsset } from '#lib/api.ts';

	let { asset, onClose }: { asset: CatalogAsset; onClose: () => void } = $props();

	let phase = $state<'choose' | 'preparing' | 'ready' | 'error'>('choose');
	let file = $state<File | null>(null);
	let error = $state('');
	let controller: AbortController | null = null;
	const touch = matchMedia('(pointer: coarse)').matches;

	function filename(res: Response, fallback: string) {
		const cd = res.headers.get('content-disposition') ?? '';
		const m = /filename\*=UTF-8''([^;]+)/i.exec(cd);
		return m ? decodeURIComponent(m[1]) : fallback;
	}

	async function prepare(url: string, fallback: string) {
		phase = 'preparing';
		controller = new AbortController();
		try {
			const res = await fetch(url, { signal: controller.signal, headers: { 'X-Client-API-Version': String(CLIENT_API_VERSION) } });
			if (!res.ok) throw new Error((await res.json().catch(() => null))?.error ?? `HTTP ${res.status}`);
			const blob = await res.blob();
			file = new File([blob], filename(res, fallback), { type: blob.type });
			if (touch && navigator.canShare?.({ files: [file] })) {
				phase = 'ready';
			} else {
				download(file);
				onClose();
			}
		} catch (e) {
			if ((e as Error).name === 'AbortError') return;
			error = (e as Error).message;
			phase = 'error';
		}
	}

	function download(f: File) {
		const a = document.createElement('a');
		a.href = URL.createObjectURL(f);
		a.download = f.name;
		document.body.appendChild(a);
		a.click();
		a.remove();
		setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
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
		{#if asset.ev > 0}
			<button class="opt" onclick={() => prepare(exportUrl(asset.id, 'jpeg'), `${asset.name}-edited.jpg`)}>
				Edited photo <span>JPEG, full resolution</span>
			</button>
			<button class="opt" onclick={() => prepare(exportUrl(asset.id, 'heic'), `${asset.name}-edited.heic`)}>
				Edited photo <span>HEIC, smaller file</span>
			</button>
		{/if}
		{#if asset.dur != null}
			<!-- Videos can be hundreds of MB: let the browser download them instead of reading them into memory. -->
			<a class="opt" href={originalUrl(asset.id)} download={asset.name} onclick={onClose}>
				Original <span>unchanged file</span>
			</a>
		{:else}
			<button class="opt" onclick={() => prepare(originalUrl(asset.id), asset.name)}>
				Original <span>unchanged file{asset.ev > 0 ? ', without edits' : ''}</span>
			</button>
		{/if}
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'preparing'}
		<h3>Preparing…</h3>
		<p class="muted">{asset.ev > 0 ? 'Rendering at full resolution on the Mac.' : 'Downloading.'}</p>
		<button class="btn cancel" onclick={cancel}>Cancel</button>
	{:else if phase === 'ready'}
		<h3>Ready</h3>
		<p class="muted">{file?.name}</p>
		<button class="btn primary" onclick={share}>Share…</button>
		<button class="btn cancel" onclick={() => file && download(file)}>Save to Files</button>
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
		word-break: break-all;
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
	.cancel {
		width: 100%;
	}
	.btn.primary {
		width: 100%;
	}
</style>
