<script lang="ts">
	// Desktop: drop photos or whole folders anywhere on the window to upload them.
	import { onMount } from 'svelte';
	import { app } from '#lib/state.svelte.ts';
	import { uploads, uploadUI, currentSource, isImageName } from '#lib/uploadsInstance.svelte.ts';

	let over = $state(false);
	let depth = 0;

	async function readEntry(entry: FileSystemEntry): Promise<File[]> {
		if (entry.isFile) {
			return new Promise((res) => (entry as FileSystemFileEntry).file((f) => res([f]), () => res([])));
		}
		if (entry.isDirectory) {
			const reader = (entry as FileSystemDirectoryEntry).createReader();
			const out: File[] = [];
			for (;;) {
				const batch = await new Promise<FileSystemEntry[]>((res) => reader.readEntries(res, () => res([])));
				if (!batch.length) break;
				for (const e of batch) out.push(...(await readEntry(e)));
			}
			return out;
		}
		return [];
	}

	onMount(() => {
		const hasFiles = (e: DragEvent) => [...(e.dataTransfer?.types ?? [])].includes('Files');
		const enter = (e: DragEvent) => {
			if (!hasFiles(e)) return;
			e.preventDefault();
			depth++;
			over = true;
		};
		const overFn = (e: DragEvent) => {
			if (hasFiles(e)) e.preventDefault();
		};
		const leave = () => {
			depth = Math.max(0, depth - 1);
			if (!depth) over = false;
		};
		const drop = async (e: DragEvent) => {
			if (!hasFiles(e)) return;
			e.preventDefault();
			depth = 0;
			over = false;
			if (!app.uploadsConfigured) {
				alert('Choose an uploads folder in Settings first.');
				return;
			}
			const entries = [...(e.dataTransfer?.items ?? [])].map((i) => i.webkitGetAsEntry?.()).filter(Boolean) as FileSystemEntry[];
			const files = entries.length ? (await Promise.all(entries.map(readEntry))).flat() : [...(e.dataTransfer?.files ?? [])];
			const images = files.filter((f) => isImageName(f.name));
			if (!images.length) return;
			uploadUI.open = true;
			await uploads.add(images, currentSource());
		};
		window.addEventListener('dragenter', enter);
		window.addEventListener('dragover', overFn);
		window.addEventListener('dragleave', leave);
		window.addEventListener('drop', drop);
		return () => {
			window.removeEventListener('dragenter', enter);
			window.removeEventListener('dragover', overFn);
			window.removeEventListener('dragleave', leave);
			window.removeEventListener('drop', drop);
		};
	});
</script>

{#if over}
	<div class="drop" aria-hidden="true">
		<div>Drop photos or folders to upload</div>
	</div>
{/if}

<style>
	.drop {
		position: fixed;
		inset: 0;
		z-index: 500;
		background: rgba(10, 132, 255, 0.12);
		border: 3px dashed var(--accent);
		display: flex;
		align-items: center;
		justify-content: center;
		pointer-events: none;
	}
	.drop div {
		background: var(--bg);
		padding: 14px 22px;
		border-radius: 12px;
		font-weight: 600;
		box-shadow: 0 6px 30px rgba(0, 0, 0, 0.2);
	}
</style>
