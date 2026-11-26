<script lang="ts">
	import { thumbUrl } from '#lib/api.ts';
	import { blurhashUrl } from '#lib/blurhash.ts';
	import { formatDuration } from '#lib/video.ts';
	import { app } from '#lib/state.svelte.ts';

	let {
		id,
		x,
		y,
		size,
		selected = false,
		selecting = false,
		onActivate,
		onLongPress,
		defer = false
	}: {
		id: string;
		x: number;
		y: number;
		size: number;
		selected?: boolean;
		selecting?: boolean;
		onActivate: (id: string, e: MouseEvent) => void;
		onLongPress?: (id: string) => void;
		/** Show only the placeholder for now (the grid is flying past); once loaded, an image stays. */
		defer?: boolean;
	} = $props();
	let started = $state(false);
	/** When the grid drops this thumbnail (scrolled far away), WebKit can keep the decoded bitmap of
	 *  a detached <img> until garbage collection; pointing it at an empty image frees it now, so a
	 *  long scroll doesn't pile up memory. */
	function releaseOnRemove(img: HTMLImageElement) {
		return {
			destroy() {
				img.removeAttribute('srcset');
				img.src = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';
			}
		};
	}
	$effect.pre(() => {
		if (!defer) started = true;
	});
	const asset = $derived(app.lookup(id));
	let loaded = $state(false);
	const placeholder = $derived(blurhashUrl(asset?.bh ?? null));

	// Long-press (touch) starts selection; a long press must not also "click".
	let timer: ReturnType<typeof setTimeout> | undefined;
	let longPressed = false;
	let start = { x: 0, y: 0 };
	function down(e: PointerEvent) {
		if (e.pointerType !== 'touch' || !onLongPress) return;
		longPressed = false;
		start = { x: e.clientX, y: e.clientY };
		timer = setTimeout(() => {
			longPressed = true;
			navigator.vibrate?.(10);
			onLongPress?.(id);
		}, 450);
	}
	function move(e: PointerEvent) {
		if (timer && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 10) clearTimeout(timer);
	}
	function up() {
		clearTimeout(timer);
	}
	function click(e: MouseEvent) {
		if (longPressed) {
			longPressed = false;
			e.preventDefault();
			return;
		}
		onActivate(id, e);
	}
</script>

<button
	class="thumb"
	class:selected
	data-asset-id={id}
	style="transform: translate({x}px, {y}px); width: {size}px; height: {size}px; {placeholder
		? `background-image: url(${placeholder})`
		: ''}"
	onclick={click}
	onpointerdown={down}
	onpointermove={move}
	onpointerup={up}
	onpointercancel={up}
	oncontextmenu={(e) => onLongPress && e.preventDefault()}
	aria-label={asset?.name ?? 'Photo'}
	aria-pressed={selecting ? selected : undefined}
>
	{#if asset && started}
		<img
			src={thumbUrl(id, asset.ev, app.fmt)}
			alt=""
			decoding="async"
			draggable="false"
			use:releaseOnRemove
			class:loaded
			onload={() => (loaded = true)}
		/>
	{/if}
	{#if asset?.fav}<span class="fav">♥</span>{/if}
	{#if asset?.dur != null && !selecting}<span class="dur">{formatDuration(asset.tr ? asset.tr[1] - asset.tr[0] : asset.dur)}</span>{/if}
	{#if selecting}
		<span class="check" class:on={selected} aria-hidden="true">{selected ? '✓' : ''}</span>
	{/if}
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
		-webkit-touch-callout: none;
		-webkit-user-select: none;
		user-select: none;
	}
	img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
		opacity: 0;
		transition:
			opacity 0.2s,
			transform 0.15s;
	}
	img.loaded {
		opacity: 1;
	}
	.selected img {
		transform: scale(0.9);
		opacity: 0.75;
	}
	.fav {
		position: absolute;
		left: 5px;
		bottom: 3px;
		color: white;
		font-size: 12px;
		text-shadow: 0 0 3px rgba(0, 0, 0, 0.6);
	}
	.dur {
		position: absolute;
		right: 5px;
		bottom: 4px;
		padding: 1px 5px;
		border-radius: 8px;
		background: rgba(0, 0, 0, 0.45);
		color: white;
		font-size: 11px;
		font-weight: 600;
		line-height: 1.4;
		font-variant-numeric: tabular-nums;
		text-shadow: 0 0 3px rgba(0, 0, 0, 0.6);
		pointer-events: none;
	}
	.check {
		position: absolute;
		right: 5px;
		bottom: 5px;
		width: 22px;
		height: 22px;
		border-radius: 50%;
		border: 1.5px solid white;
		background: rgba(0, 0, 0, 0.15);
		box-shadow: 0 0 3px rgba(0, 0, 0, 0.4);
		color: white;
		font-size: 13px;
		font-weight: 700;
		display: flex;
		align-items: center;
		justify-content: center;
	}
	.check.on {
		background: var(--accent);
	}
</style>
