<script lang="ts">
	import { untrack } from 'svelte';
	import { thumbUrl } from '#lib/api.ts';
	import { blurhashUrl } from '#lib/blurhash.ts';
	import { formatDuration } from '#lib/video.ts';
	import { app, pendingTurns, thumbGhosts } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { deviceThumbs } from '#lib/deviceThumbs.svelte.ts';
	import Icon from './Icon.svelte';

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
	/** The thumbnail couldn't be loaded: not on this device and the server can't be reached (or can't
	 *  make it). A cloud shows instead of the endless blur; it is tried again when the server is back. */
	let missing = $state(false);
	/** a failed load will be tried again shortly */
	let retrying = $state(false);
	let attempt = $state(0);
	deviceThumbs.start();
	const src = $derived(asset ? thumbUrl(id, asset.ev, app.fmt) : '');
	/**
	 * Where a thumbnail that isn't shown yet comes from: this device's cache (or, in local mode, the
	 * Mac's disk) → the blur; the server → a cloud; nowhere (offline and not on the device, or the
	 * server couldn't make it) → a crossed-out cloud.
	 */
	const source = $derived<'device' | 'server' | 'none'>(
		missing ? (retrying ? 'server' : 'none') : app.local || deviceThumbs.has(src) ? 'device' : net.online ? 'server' : 'none'
	);
	let wasOnline = net.online;
	$effect(() => {
		const online = net.online;
		const back = online && !wasOnline; // only when the server comes back, not in a loop
		wasOnline = online;
		if (back && untrack(() => missing)) {
			missing = false;
			attempt++;
		}
	});
	/** quarter turns shown ahead of the server's new rendition (rotate) */
	const turn = $derived(pendingTurns.get(id) ?? 0);
	/** the picture before a rotation's new rendition, on top until that one is painted */
	const ghost = $derived(thumbGhosts.get(id));
	/** A failed load is tried again twice while online (the server may have been slow to fetch the
	 *  original from a remote source); offline, it waits for the server to come back. */
	let retries = 0;
	let retryTimer: ReturnType<typeof setTimeout> | undefined;
	function failed() {
		missing = true;
		if (net.online && retries < 2) {
			retries++;
			retrying = true;
			clearTimeout(retryTimer);
			retryTimer = setTimeout(() => {
				retrying = false;
				if (!missing) return;
				missing = false;
				attempt++;
			}, 4000 * retries);
		}
	}
	$effect(() => () => clearTimeout(retryTimer));
	function loadedNew() {
		loaded = true;
		missing = false;
		if (net.online && !app.local) deviceThumbs.add(src);
		const g = thumbGhosts.get(id);
		if (g) requestAnimationFrame(() => requestAnimationFrame(() => thumbGhosts.get(id) === g && thumbGhosts.delete(id)));
	}
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
	class:missing
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
		{#key attempt}
		<img
			{src}
			alt=""
			decoding="async"
			draggable="false"
			use:releaseOnRemove
			class:loaded
			class:turned={turn !== 0}
			style:transform={turn ? `rotate(${turn * 90}deg)` : undefined}
			onload={loadedNew}
			onerror={failed}
		/>
		{/key}
		{#if ghost}
			<img class="ghost loaded" src={ghost.src} alt="" draggable="false" style:transform={ghost.turn ? `rotate(${ghost.turn * 90}deg)` : undefined} />
		{/if}
	{/if}
	{#if !loaded && source !== 'device'}
		<span class="cloud" class:off={source === 'none'}
			title={source === 'none' ? 'Not on this device, and the server can’t be reached' : 'Loading from the server'}
			><Icon name={source === 'none' ? 'cloudOff' : 'cloud'} size={Math.min(26, Math.max(14, size / 5))} /></span
		>
	{:else if missing && !retrying}
		<span class="cloud off" title="Couldn’t be loaded"><Icon name="cloudOff" size={Math.min(26, Math.max(14, size / 5))} /></span>
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
	img.ghost {
		position: absolute;
		inset: 0;
		transition: none;
	}
	/* selected: a blue frame, like Photos on the Mac */
	.selected::after,
	.focused::after {
		content: '';
		position: absolute;
		inset: 0;
		border: 3px solid var(--accent);
		pointer-events: none;
	}
	/* the photo last open (desktop) is only bookmarked, not selected: a thin outline */
	.focused::after {
		border-width: 1.5px;
		border-color: color-mix(in srgb, var(--accent) 75%, white);
	}
	.missing img {
		visibility: hidden; /* no broken-image glyph */
	}
	/* coming from the server (cloud) or unavailable (crossed out): over the blur; it fades in after a
	   moment, so quick loads don't flash it */
	.cloud {
		position: absolute;
		inset: 0;
		display: flex;
		align-items: center;
		justify-content: center;
		color: rgba(255, 255, 255, 0.85);
		pointer-events: none;
		animation: cloud-in 0.2s 0.25s both;
	}
	.cloud.off {
		background: rgba(0, 0, 0, 0.35);
		animation-delay: 0s;
	}
	@keyframes cloud-in {
		from {
			opacity: 0;
		}
	}
	.cloud :global(svg) {
		filter: drop-shadow(0 0 3px rgba(0, 0, 0, 0.5));
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
