<script lang="ts">
	import { thumbUrl } from '#lib/api.ts';
	import { blurhashUrl } from '#lib/blurhash.ts';
	import { app } from '#lib/state.svelte.ts';

	let { id, x, y, size, onOpen }: { id: string; x: number; y: number; size: number; onOpen: (id: string) => void } =
		$props();
	const asset = $derived(app.byId.get(id));
	let loaded = $state(false);
	const placeholder = $derived(blurhashUrl(asset?.bh ?? null));
</script>

<button
	class="thumb"
	data-asset-id={id}
	style="transform: translate({x}px, {y}px); width: {size}px; height: {size}px; {placeholder
		? `background-image: url(${placeholder})`
		: ''}"
	onclick={() => onOpen(id)}
	aria-label={asset?.name ?? 'Photo'}
>
	{#if asset}
		<img
			src={thumbUrl(id, asset.ev, app.fmt)}
			alt=""
			decoding="async"
			draggable="false"
			class:loaded
			onload={() => (loaded = true)}
		/>
	{/if}
	{#if asset?.fav}<span class="fav">♥</span>{/if}
</button>

<style>
	.thumb {
		position: absolute;
		left: 0;
		top: 0;
		padding: 0;
		border: none;
		background-color: var(--bg-elevated);
		background-size: cover;
		cursor: pointer;
		overflow: hidden;
		contain: strict;
	}
	img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
		opacity: 0;
		transition: opacity 0.2s;
		-webkit-user-select: none;
		user-select: none;
	}
	img.loaded {
		opacity: 1;
	}
	.fav {
		position: absolute;
		left: 5px;
		bottom: 3px;
		color: white;
		font-size: 12px;
		text-shadow: 0 0 3px rgba(0, 0, 0, 0.6);
	}
</style>
