<script lang="ts">
	// Round face crop (or a placeholder when there is none).
	import { faceThumbUrl } from '#lib/api.ts';
	let { faceId, size = 96 }: { faceId: number | null; size?: number } = $props();
	let failed = $state(false);
</script>

<span class="avatar" style="width: {size}px; height: {size}px">
	{#if faceId != null && !failed}
		<img src={faceThumbUrl(faceId)} alt="" loading="lazy" draggable="false" onerror={() => (failed = true)} />
	{:else}
		<svg viewBox="0 0 24 24" width={size * 0.5} height={size * 0.5} fill="currentColor" aria-hidden="true"
			><path d="M12 12a4.5 4.5 0 1 0 0-9 4.5 4.5 0 0 0 0 9zm0 2c-4.4 0-8 2.2-8 5v2h16v-2c0-2.8-3.6-5-8-5z" /></svg
		>
	{/if}
</span>

<style>
	.avatar {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		border-radius: 50%;
		overflow: hidden;
		background: var(--bg-elevated);
		color: var(--fg-secondary);
		flex: none;
	}
	img {
		width: 100%;
		height: 100%;
		object-fit: cover;
	}
</style>
