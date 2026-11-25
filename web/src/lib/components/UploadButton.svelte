<script lang="ts">
	import { goto } from '$app/navigation';
	import { app } from '#lib/state.svelte.ts';
	import { uploads, uploadUI, currentSource, imageAccept } from '#lib/uploadsInstance.svelte.ts';
	import Icon from './Icon.svelte';

	let input: HTMLInputElement;

	function pick() {
		if (!app.uploadsConfigured) {
			if (confirm('Choose an uploads folder in Settings first. Open Settings?')) goto('/settings');
			return;
		}
		input.click();
	}
	async function chosen() {
		const files = [...(input.files ?? [])];
		input.value = '';
		if (!files.length) return;
		uploadUI.open = true;
		await uploads.add(files, currentSource());
	}
</script>

<input bind:this={input} type="file" accept={imageAccept} multiple hidden onchange={chosen} />
<button class="icon-btn up" onclick={pick} title="Upload photos" aria-label="Upload photos">
	<Icon name="upload" />
	{#if uploads.active}<span class="badge">{uploads.active}</span>{/if}
</button>
{#if uploads.items.length && !uploadUI.open}
	<button class="link" onclick={() => (uploadUI.open = true)}>{uploads.active ? 'Uploading…' : 'Uploads'}</button>
{/if}

<style>
	.up {
		position: relative;
	}
	.badge {
		position: absolute;
		top: 0;
		right: 0;
		min-width: 16px;
		height: 16px;
		border-radius: 8px;
		background: var(--accent);
		color: white;
		font-size: 10px;
		font-weight: 700;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 0 4px;
	}
	.link {
		border: none;
		background: none;
		color: var(--accent);
		font-size: 13px;
		cursor: pointer;
	}
</style>
