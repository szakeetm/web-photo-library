<script lang="ts">
	// A Live Photo's motion clip, drawn over the still in the viewer's current slide, plus the LIVE badge.
	// The viewer sets `playing` while the photo is pressed and held; hovering the badge with a mouse (or
	// pressing the badge) plays it too. The clip is always the unedited original (owner's decision), laid
	// out with `object-fit: contain` in the frame's box like the still.
	//
	// Loading is on demand, to save data: the clip is fetched only when the user first holds the photo
	// (or hovers/presses the badge), and then kept in the device cache (imageCache: same size limit and
	// eviction as previews). A cached clip is loaded from there as soon as the slide is current, so it
	// plays at once, offline too. A download in progress is aborted when the slide stops being current. It is fetched whole and played from a
	// blob URL, so "ready" is certain (iOS often won't preload a <video>). While it loads, the badge's
	// icon spins and, during a hold, a "Loading Live Photo…" pill shows; the clip plays as soon as it
	// arrives if the hold is still on. A clip the Mac is still converting (202) is asked for again each
	// second. Anything else that isn't playable (404, 409, a <video> error) fails: the badge goes inert.
	import { untrack } from 'svelte';
	import { motionUrl, type CatalogAsset } from '#lib/api.ts';
	import { cachedClip, hasClip, motionKey, storeClip } from '#lib/imageCache.ts';
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
	/** The clip is in the device cache (known once the slide is current). */
	let cached = $state(false);
	/** A frame of the playing clip is on screen (fades in over the still). */
	let shown = $state(false);

	const online = $derived(net.online || cached);
	const usable = $derived(active && online && !zoomed && !failed);
	const aspect = $derived(still ? still.w / still.h : asset.w / asset.h);

	// When the slide becomes current, a cached clip is loaded at once (no network). Drop the clip (and
	// forget a failure) when the slide stops being current.
	$effect(() => {
		if (!active) return;
		const id = asset.id;
		let live = true;
		hasClip(motionKey(id))
			.then((hit) => {
				if (live && hit) {
					cached = true;
					armed = true;
				}
			})
			.catch(() => {});
		return () => {
			live = false;
			armed = false;
			failed = false;
			cached = false;
		};
	});

	/** The clip is being downloaded. */
	const loading = $derived(armed && !ready && !failed && online);

	// The first hold (or badge hover) loads the clip.
	$effect(() => {
		if (playing && usable) armed = true;
	});

	// Download the clip, then hand it to the <video>; drop both when the slide stops being current.
	$effect(() => {
		const v = video;
		if (!v || !armed) return;
		const ctl = new AbortController();
		let url = '';
		const load = async () => {
			const key = motionKey(asset.id);
			const hit = await cachedClip(key).catch(() => null);
			if (ctl.signal.aborted) return;
			if (hit) {
				url = URL.createObjectURL(hit);
				v.src = url;
				ready = true;
				return;
			}
			for (;;) {
				const res = await fetch(motionUrl(asset.id), { signal: ctl.signal });
				if (res.status === 202) {
					// The Mac is converting the clip: ask again shortly.
					res.body?.cancel();
					await new Promise((r) => setTimeout(r, 1000));
					if (ctl.signal.aborted) return;
					continue;
				}
				if (res.status !== 200) throw new Error(`HTTP ${res.status}`);
				const blob = await res.blob();
				if (ctl.signal.aborted) return;
				storeClip(key, blob).catch(() => {}); // full or unavailable storage: just don't keep it
				url = URL.createObjectURL(blob);
				v.src = url;
				ready = true;
				return;
			}
		};
		load().catch((e: Error) => {
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
	{#if playing && loading}
		<div class="live-wait" role="status">
			<span class="spinner" aria-hidden="true"></span>
			Loading Live Photo…
		</div>
	{/if}
	{#if !zoomed}
		<button
			type="button"
			class="live-badge"
			class:inert={!online || failed}
			class:loading
			class:playing={shown}
			tabindex="-1"
			title={!online ? 'Live Photo (needs a connection)' : failed ? "Live Photo (motion can't be played)" : loading ? 'Live Photo (loading…)' : 'Live Photo: hold the photo to play'}
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
	.live-wait {
		position: absolute;
		left: 50%;
		top: 50%;
		transform: translate(-50%, -50%);
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 8px 14px;
		border-radius: 999px;
		font-size: 14px;
		font-weight: 500;
		color: #fff;
		background: rgba(0, 0, 0, 0.55);
		backdrop-filter: blur(12px);
		-webkit-backdrop-filter: blur(12px);
		pointer-events: none;
		white-space: nowrap;
		animation: live-wait-in 0.2s 0.15s both; /* no flash when the clip is already almost there */
	}
	.live-wait .spinner {
		width: 14px;
		height: 14px;
		border: 2px solid rgba(255, 255, 255, 0.35);
		border-top-color: #fff;
		border-radius: 50%;
		animation: live-spin 0.8s linear infinite;
	}
	@keyframes live-wait-in {
		from {
			opacity: 0;
		}
		to {
			opacity: 1;
		}
	}
	.live-badge.loading svg {
		animation: live-spin 1.2s linear infinite;
	}
	@keyframes live-spin {
		to {
			transform: rotate(360deg);
		}
	}
	/* Hidden while the motion plays (as in Photos). Only visually: a mouse hovering it keeps playing. */
	.live-badge.playing {
		opacity: 0;
	}
	.live-badge.inert {
		opacity: 0.4;
		pointer-events: none;
	}
</style>
