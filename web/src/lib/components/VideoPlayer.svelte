<script lang="ts">
	// Video playback inside the viewer's current slide, drawn over the poster (the viewer's preview image).
	// The server answers the video URL with the file (200/206), 202 while it makes a playable preview
	// (that request also queues the conversion), or 409 when nothing playable exists. A range probe asks
	// first, so the <video> only ever gets a URL that answers with video.
	//
	// Custom controls rather than `controls`: the native ones live in the element's shadow DOM, so a drag
	// on their scrubber reaches the viewer as an ordinary horizontal drag and would page to the next
	// photo. Here the bar is real DOM the viewer's gesture code skips, and a drag anywhere else on the
	// video still pages or closes.
	import { tick, untrack } from 'svelte';
	import { api, videoUrl, type CatalogAsset } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { formatDuration } from '#lib/video.ts';

	let {
		asset,
		active,
		onDownload,
		trim = null,
		editing = false
	}: {
		asset: CatalogAsset;
		active: boolean;
		onDownload?: () => void;
		/** play only this range (a saved trim, or the trim being edited) */
		trim?: [number, number] | null;
		/** the trim editor replaces the control bar; playback loops within the range */
		editing?: boolean;
	} = $props();

	type Phase = 'idle' | 'probing' | 'preparing' | 'ready' | 'unplayable' | 'failed' | 'offline';
	let phase = $state<Phase>('idle');
	let progress = $state<number | null>(null);
	let error = $state<string | null>(null);
	let src = $state<string | null>(null);

	let video = $state<HTMLVideoElement>();
	let paused = $state(true);
	let starting = $state(false); // a play() is pending (no play button flash before autoplay)
	let shown = $state(false); // a frame is decoded (until then the poster shows through)
	let time = $state(0);
	let duration = $state(0);
	let muted = $state(false);
	let scrubbing = false;
	let visible = $state(document.visibilityState === 'visible');

	/** Bumped on every probe and on teardown, so stale answers are dropped. */
	let gen = 0;

	async function probe() {
		const my = ++gen;
		const id = asset.id;
		if (phase !== 'preparing') phase = 'probing';
		const stale = () => my !== gen;
		let res: Response;
		try {
			res = await fetch(videoUrl(id, app.local), { headers: { Range: 'bytes=0-1' }, cache: 'no-store' });
		} catch {
			if (stale()) return;
			phase = 'offline';
			net.set(false);
			return;
		}
		if (stale()) return void res.body?.cancel();
		if (res.status === 200 || res.status === 206) {
			res.body?.cancel();
			starting = true;
			phase = 'ready';
			src = videoUrl(id, app.local); // local mode: the original when browsers can play it
			await tick();
			if (stale()) return;
			play();
		} else if (res.status === 202) {
			const body = (await res.json().catch(() => null)) as { status?: { progress?: number } } | null;
			if (stale()) return;
			progress = body?.status?.progress ?? null;
			phase = 'preparing';
		} else if (res.status === 409) {
			res.body?.cancel();
			const s = await api.videoStatus(id).catch(() => null);
			if (stale()) return;
			error = s?.state === 'failed' ? (s.error ?? null) : null;
			phase = s?.state === 'failed' ? 'failed' : 'unplayable';
		} else {
			res.body?.cancel();
			if (res.status >= 502 && res.status <= 504) {
				phase = 'offline';
				net.set(false);
			} else {
				error = res.status === 404 ? 'The video file is missing.' : `Server error (${res.status}).`;
				phase = 'failed';
			}
		}
	}

	function teardown() {
		gen++;
		if (video) {
			video.pause();
			video.removeAttribute('src');
			video.load(); // releases the connection
		}
		src = null;
		shown = false;
		starting = false;
		phase = 'idle';
	}

	// Start when the slide becomes current; pause and drop the source when it stops being current.
	$effect(() => {
		if (!active) return;
		untrack(() => (net.online ? probe() : (phase = 'offline')));
		return teardown;
	});

	// Offline before a source was found: say so; back online: try again. A playing video keeps playing.
	$effect(() => {
		if (!active) return;
		const online = net.online;
		untrack(() => {
			if (!online && phase !== 'ready' && phase !== 'offline') {
				gen++;
				phase = 'offline';
			} else if (online && phase === 'offline') probe();
		});
	});

	$effect(() => {
		const onVisibility = () => (visible = document.visibilityState === 'visible');
		document.addEventListener('visibilitychange', onVisibility);
		return () => document.removeEventListener('visibilitychange', onVisibility);
	});

	// While a preview is being made: poll its progress every second (current slide, page visible only).
	$effect(() => {
		if (!active || phase !== 'preparing' || !visible || !net.online) return;
		const id = asset.id;
		let stopped = false;
		let timer: ReturnType<typeof setTimeout>;
		const tickPoll = async () => {
			try {
				const s = await api.videoStatus(id);
				if (stopped) return;
				if (s.state === 'converting' || s.state === 'queued') progress = s.progress ?? null;
				else await probe(); // ready → plays; failed/unavailable → the probe says what is left
			} catch {
				// network errors flip `net.online`, which stops this loop
			}
			if (!stopped) timer = setTimeout(tickPoll, 1000);
		};
		timer = setTimeout(tickPoll, 1000);
		return () => {
			stopped = true;
			clearTimeout(timer);
		};
	});

	const full = $derived(duration || asset.dur || 0);
	const rangeStart = $derived(trim ? trim[0] : 0);
	const rangeEnd = $derived(trim ? Math.min(trim[1], full || trim[1]) : full);

	/** Plays; a rejected autoplay (NotAllowedError) leaves the big play button showing. */
	function play() {
		if (!video) return void (starting = false);
		if (trim && (video.currentTime < rangeStart - 0.05 || video.currentTime >= rangeEnd - 0.05)) video.currentTime = rangeStart;
		starting = true;
		video
			.play()
			.catch(() => {})
			.finally(() => (starting = false));
	}

	/** Play/pause (the viewer's space bar). */
	export function toggle() {
		if (!video || phase !== 'ready') return;
		if (video.paused) play();
		else video.pause();
	}

	function onVideoError() {
		if (!src) return;
		if (!net.online) phase = 'offline';
		else {
			error = 'Playback failed.';
			phase = 'failed';
		}
		src = null;
	}

	/** Shows the frame at `t` (the trim editor's handles). */
	export function seekTo(t: number) {
		if (!video) return;
		video.pause();
		video.currentTime = t;
		time = t;
	}

	/** Keeps playback inside the trimmed range: stops at its end (loops while editing). */
	function onTime() {
		if (!video) return;
		if (trim && video.currentTime >= rangeEnd - 0.03 && !video.paused) {
			if (editing) video.currentTime = rangeStart;
			else {
				video.pause();
				video.currentTime = rangeEnd;
			}
		}
		if (!scrubbing) time = video.currentTime;
	}

	function seek(e: Event) {
		const t = Number((e.currentTarget as HTMLInputElement).value);
		time = t;
		if (video) video.currentTime = t;
	}

	const pct = $derived(progress != null ? ` ${Math.round(progress * 100)}%` : '');
</script>

{#if src}
	<!-- svelte-ignore a11y_media_has_caption -->
	<video
		bind:this={video}
		class:shown
		{src}
		playsinline
		preload="metadata"
		bind:paused
		bind:muted
		onloadeddata={() => (shown = true)}
		onplaying={() => (shown = true)}
		onseeked={() => (shown = true)}
		onloadedmetadata={() => {
			duration = video?.duration || asset.dur || 0;
			if (video && trim && video.currentTime < trim[0]) video.currentTime = trim[0];
		}}
		ontimeupdate={onTime}
		onerror={onVideoError}
	></video>
{/if}

{#if phase === 'ready'}
	{#if paused && !starting}
		<button class="big-play" onclick={play} aria-label="Play">
			<svg viewBox="0 0 24 24" width="34" height="34" aria-hidden="true"><path d="M8 5.5v13l11-6.5z" fill="currentColor" /></svg>
		</button>
	{/if}
	{#if !editing}
	<div class="video-controls">
		<button class="icon-btn" onclick={toggle} aria-label={paused ? 'Play' : 'Pause'}>
			<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" fill="currentColor">
				<path d={paused ? 'M7 4.5v15l12.5-7.5z' : 'M6.5 4.5h4v15h-4z M13.5 4.5h4v15h-4z'} />
			</svg>
		</button>
		<span class="time">{formatDuration(Math.max(0, time - rangeStart))}</span>
		<input
			type="range"
			min={rangeStart}
			max={rangeEnd}
			step="any"
			value={time}
			aria-label="Position"
			oninput={seek}
			onpointerdown={() => (scrubbing = true)}
			onpointerup={(e) => {
				scrubbing = false;
				e.currentTarget.blur(); // keep arrow keys and space for the viewer
			}}
			onpointercancel={() => (scrubbing = false)}
		/>
		<span class="time">{formatDuration(rangeEnd - rangeStart)}</span>
		<button class="icon-btn" onclick={() => (muted = !muted)} aria-label={muted ? 'Unmute' : 'Mute'}>
			<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true" fill="none" stroke="currentColor"
				stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
				<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z" fill="currentColor" />
				<path d={muted ? 'M16 9.5l5 5 M21 9.5l-5 5' : 'M15.5 9a4 4 0 0 1 0 6 M18 6.5a7.5 7.5 0 0 1 0 11'} />
			</svg>
		</button>
	</div>
	{/if}
{:else if phase === 'preparing'}
	<div class="note">Preparing video…{pct}</div>
{:else if phase === 'offline'}
	<div class="note">Video needs a connection</div>
{:else if phase === 'unplayable' || phase === 'failed'}
	<div class="note">
		<div>{phase === 'unplayable' ? "Can't play this video here" : "Couldn't prepare this video"}</div>
		{#if error}<div class="detail">{error}</div>{/if}
		<button class="btn" onclick={() => onDownload?.()}>Download…</button>
	</div>
{/if}

<style>
	video {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		object-fit: contain;
		opacity: 0;
	}
	video.shown {
		opacity: 1;
	}
	.big-play {
		position: absolute;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: 72px;
		height: 72px;
		border: none;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 0 0 0 4px;
		color: white;
		background: rgba(0, 0, 0, 0.45);
		backdrop-filter: blur(12px);
		-webkit-backdrop-filter: blur(12px);
		cursor: pointer;
	}
	.video-controls {
		position: absolute;
		left: 0;
		right: 0;
		bottom: 0;
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 6px 12px calc(env(safe-area-inset-bottom) + 6px);
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
		transition: opacity 0.2s;
	}
	.video-controls input {
		flex: 1;
		min-width: 0;
		accent-color: var(--accent);
	}
	.time {
		font-size: 12px;
		font-variant-numeric: tabular-nums;
		color: var(--fg-secondary);
	}
	.note {
		position: absolute;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		max-width: calc(100% - 32px);
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 8px;
		padding: 12px 18px;
		border-radius: var(--radius);
		background: rgba(0, 0, 0, 0.6);
		backdrop-filter: blur(12px);
		-webkit-backdrop-filter: blur(12px);
		color: white;
		font-size: 15px;
		font-weight: 500;
		text-align: center;
	}
	.note .detail {
		font-size: 12px;
		font-weight: 400;
		opacity: 0.75;
		word-break: break-word;
	}
</style>
