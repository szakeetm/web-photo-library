<script lang="ts">
	// A Live Photo's motion clip, drawn over the still in the viewer's current slide, plus the LIVE badge.
	// The viewer sets `playing` while the photo is pressed and held; hovering the badge with a mouse (or
	// pressing the badge) plays it too. The clip is always the unedited original (owner's decision), laid
	// out with `object-fit: contain` in the frame's box like the still.
	//
	// Loading: the clip is fetched only for the current slide, once it has been current for 500 ms (or at
	// once when a hold starts sooner), and dropped (download aborted) when the slide stops being current.
	// The clip is fetched whole and played from a blob URL, so "ready" is certain (iOS often won't
	// preload a <video>): the badge's icon spins until then. Anything but a playable answer (404, 202
	// while converting, 409) or a <video> error fails: the badge goes inert and holds do nothing.
	import { untrack } from 'svelte';
	import { motionUrl, type CatalogAsset } from '#lib/api.ts';
	import { net } from '#lib/net.svelte.ts';

	let {
		asset,
		active,
		zoomed,
		playing = $bindable(false),
		still
	}: {
		asset: CatalogAsset;
		/** The slide is current (and the viewer isn't closing). */
		active: boolean;
		zoomed: boolean;
		playing?: boolean;
		/** Displayed size of the still (an edit's crop changes its aspect); places the badge. */
		still?: { w: number; h: number };
	} = $props();

	let video = $state<HTMLVideoElement>();
	/** The clip's source is set (preloading or loaded). */
	let armed = $state(false);
	/** The clip can't be played (no motion, still converting, unplayable, or the download failed). */
	let failed = $state(false);
	/** The clip is downloaded and can play. */
	let ready = $state(false);
	/** A frame of the playing clip is on screen (fades in over the still). */
	let shown = $state(false);

	const usable = $derived(active && net.online && !zoomed && !failed);
	const aspect = $derived(still ? still.w / still.h : asset.w / asset.h);

	// Preload once the slide has been current for a moment; drop the clip when it stops being current.
	$effect(() => {
		if (!active || !net.online) return;
		const t = setTimeout(() => (armed = true), 500);
		return () => {
			clearTimeout(t);
			armed = false;
			failed = false;
		};
	});

	// A hold before the preload started loads it now.
	$effect(() => {
		if (playing && usable) armed = true;
	});

	// Download the clip, then hand it to the <video>; drop both when the slide stops being current.
	$effect(() => {
		const v = video;
		if (!v || !armed) return;
		const ctl = new AbortController();
		let url = '';
		fetch(motionUrl(asset.id), { signal: ctl.signal })
			.then(async (res) => {
				if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
				url = URL.createObjectURL(await res.blob());
				v.src = url;
				ready = true;
			})
			.catch((e: Error) => {
				if (e.name !== 'AbortError') failed = true;
			});
		return () => {
			ctl.abort();
			v.pause();
			v.removeAttribute('src');
			v.load();
			if (url) URL.revokeObjectURL(url);
			ready = false;
			shown = false;
		};
	});

	// Nothing to play (zoomed, offline, failed, not current): let go of the request.
	$effect(() => {
		if (playing && !usable) playing = false;
	});

	// Play from the start with sound while `playing`; stop (and fade back) otherwise.
	$effect(() => {
		const v = video;
		if (!v || !armed || !ready) return;
		const want = playing && usable;
		untrack(() => (want ? start(v) : stop(v)));
	});

	function start(v: HTMLVideoElement) {
		v.currentTime = 0;
		v.muted = false;
		v.play().catch((e: DOMException) => {
			// Autoplay policy (no recent user gesture, e.g. a hover on desktop): play muted instead.
			if (e.name !== 'NotAllowedError' || !playing || v.muted) return;
			v.muted = true;
			v.play().catch(() => {});
		});
	}

	function stop(v: HTMLVideoElement) {
		shown = false;
		if (!v.paused) v.pause();
	}

	function onError() {
		if (!video?.getAttribute('src')) return; // the source was dropped on purpose
		failed = true;
		ready = false;
		shown = false;
	}

	// The badge: hover (mouse) or press (touch/pen) plays.
	function onEnter(e: PointerEvent) {
		if (e.pointerType === 'mouse' && usable) playing = true;
	}
	function onLeave(e: PointerEvent) {
		if (e.pointerType === 'mouse') playing = false;
	}
	function onDown(e: PointerEvent) {
		if (e.pointerType === 'mouse' || !usable) return;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		playing = true;
	}
	function onUp(e: PointerEvent) {
		if (e.pointerType !== 'mouse') playing = false;
	}
</script>

<div class="live" style="--ar: {aspect}">
	<!-- svelte-ignore a11y_media_has_caption -->
	<video
		bind:this={video}
		class:shown
		playsinline
		preload="auto"
		disableremoteplayback
		onplaying={() => (shown = playing && usable)}
		onended={() => (shown = false)}
		onerror={onError}
	></video>
	{#if !zoomed}
		<button
			type="button"
			class="live-badge"
			class:inert={!net.online || failed}
			class:loading={net.online && !failed && !ready}
			tabindex="-1"
			title={!net.online ? 'Live Photo (needs a connection)' : failed ? "Live Photo (motion can't be played)" : !ready ? 'Live Photo (loading…)' : 'Live Photo: hold the photo to play'}
			aria-label="Live Photo"
			onpointerenter={onEnter}
			onpointerleave={onLeave}
			onpointerdown={onDown}
			onpointerup={onUp}
			onpointercancel={onUp}
			oncontextmenu={(e) => e.preventDefault()}
		>
			<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.6">
				<circle cx="12" cy="12" r="3" fill="currentColor" stroke="none" />
				<circle cx="12" cy="12" r="6" />
				<circle cx="12" cy="12" r="9.5" stroke-dasharray="1.4 2" />
			</svg>
			LIVE
		</button>
	{/if}
</div>

<style>
	.live {
		position: absolute;
		inset: 0;
		container-type: size;
		pointer-events: none;
		/* The still's box when fitted (contain) into the frame. */
		--w: min(100cqw, 100cqh * var(--ar));
		--h: min(100cqh, 100cqw / var(--ar));
	}
	video {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		object-fit: contain;
		opacity: 0;
		transition: opacity 0.25s;
		pointer-events: none;
		-webkit-touch-callout: none;
	}
	video.shown {
		opacity: 1;
	}
	.live-badge {
		position: absolute;
		/* Top-left of the photo, below the viewer's top bar. */
		left: calc((100cqw - var(--w)) / 2 + 8px);
		top: max(calc((100cqh - var(--h)) / 2 + 8px), calc(env(safe-area-inset-top) + 64px));
		display: flex;
		align-items: center;
		gap: 4px;
		padding: 3px 8px 3px 5px;
		border: none;
		border-radius: 6px;
		font: inherit;
		font-size: 12px;
		font-weight: 600;
		letter-spacing: 0.04em;
		color: var(--fg);
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
		pointer-events: auto;
		cursor: default;
		transition: opacity 0.2s;
		-webkit-touch-callout: none;
		-webkit-user-select: none;
		user-select: none;
	}
	.live-badge.loading svg {
		animation: live-spin 1.2s linear infinite;
	}
	@keyframes live-spin {
		to {
			transform: rotate(360deg);
		}
	}
	.live-badge.inert {
		opacity: 0.4;
		pointer-events: none;
	}
</style>
