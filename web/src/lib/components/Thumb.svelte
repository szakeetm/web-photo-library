<script lang="ts">
	import { thumbUrl } from '#lib/api.ts';
	import { blurhashUrl } from '#lib/blurhash.ts';
	import { formatDuration } from '#lib/video.ts';
	import { app, pendingTurns } from '#lib/state.svelte.ts';

	let {
		id,
		x,
		y,
		size,
		selected = false,
		selecting = false,
		focused = false,
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
		/** the photo last open in the viewer (desktop): Space opens it again */
		focused?: boolean;
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
	/** quarter turns shown ahead of the server's new rendition (rotate) */
	const turn = $derived(pendingTurns.get(id) ?? 0);
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
	class:focused={focused && !selected}
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
			class:turned={turn !== 0}
			style:transform={turn ? `rotate(${turn * 90}deg)` : undefined}
			onload={() => (loaded = true)}
		/>
	{/if}
	{#if asset?.fav}<span class="fav">♥</span>{/if}
	{#if asset?.dur != null}<span class="dur">{formatDuration(asset.tr ? asset.tr[1] - asset.tr[0] : asset.dur)}</span>{/if}
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
		transition: opacity 0.2s;
	}
	/* turning ahead of the server; the new rendition replaces it without animating back */
	img.turned {
		transition:
			opacity 0.2s,
			transform 0.2s ease-out;
	}
	img.loaded {
		opacity: 1;
	}
	/* selected (and the photo last open, on desktop): a blue frame, like Photos on the Mac */
	.selected::after,
	.focused::after {
		content: '';
		position: absolute;
		inset: 0;
		border: 3px solid var(--accent);
		pointer-events: none;
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
</style>
