<script lang="ts">
	// Thin progress bar under the title while an album or folder downloads to the device.
	import type { PinRecord } from '#lib/db.ts';
	import { pinProgress } from '#lib/pins.svelte.ts';
	import { net } from '#lib/net.svelte.ts';

	let { pin }: { pin: PinRecord | undefined } = $props();
</script>

{#if pin?.state === 'downloading'}
	<div class="bar" class:paused={!net.online} role="progressbar" aria-label="Download progress" aria-valuemin={0} aria-valuemax={100}
		aria-valuenow={Math.floor(pinProgress(pin) * 100)}>
		<div style="width: {pinProgress(pin) * 100}%"></div>
	</div>
{/if}

<style>
	.bar {
		height: 3px;
		margin: 0 14px 8px;
		border-radius: 2px;
		background: var(--separator);
		overflow: hidden;
	}
	.bar div {
		height: 100%;
		background: var(--accent);
		transition: width 0.3s;
	}
	.paused div {
		background: var(--fg-secondary);
	}
</style>
