<script lang="ts">
	// Progress of the full catalog download (first install, or when the device copy had to be replaced).
	import { app } from '#lib/state.svelte.ts';

	const mb = (n: number) => (n / 1024 ** 2).toFixed(n < 10 * 1024 ** 2 ? 1 : 0);
	const fraction = $derived(app.download?.total ? Math.min(1, app.download.received / app.download.total) : null);
	const label = $derived.by(() => {
		const d = app.download;
		if (!d || d.received === 0) return 'Waiting for the server…';
		return d.total ? `${mb(d.received)} of ${mb(d.total)} MB` : `${mb(d.received)} MB`;
	});
</script>

{#if app.download}
	<div class="download" class:first={app.assets.length === 0} role="status" aria-live="polite">
		<div class="title">Downloading library…</div>
		<div class="bar" class:indeterminate={fraction == null}>
			<div style:width={fraction == null ? undefined : `${fraction * 100}%`}></div>
		</div>
		<div class="muted">{label}</div>
		{#if app.assets.length === 0}
			<p class="muted hint">The first download of a big library can take a while. Afterwards only changes are fetched.</p>
		{/if}
	</div>
{/if}

<style>
	.download {
		position: fixed;
		z-index: 50;
		left: 50%;
		top: calc(env(safe-area-inset-top) + 10px);
		transform: translateX(-50%);
		width: min(320px, calc(100vw - 32px));
		padding: 10px 14px;
		border-radius: 12px;
		background: var(--bg-elevated);
		box-shadow: 0 4px 20px rgb(0 0 0 / 0.18);
		font-size: 13px;
		text-align: center;
	}
	.download.first {
		top: 40%;
		transform: translate(-50%, -50%);
		padding: 18px 20px;
		font-size: 14px;
	}
	.title {
		font-weight: 600;
		margin-bottom: 8px;
	}
	.hint {
		margin: 10px 0 0;
		font-size: 12px;
	}
	.bar {
		height: 4px;
		border-radius: 2px;
		background: var(--separator);
		overflow: hidden;
		margin-bottom: 6px;
	}
	.bar > div {
		height: 100%;
		background: var(--accent);
		transition: width 0.2s;
	}
	.bar.indeterminate > div {
		width: 30%;
		animation: slide 1.2s ease-in-out infinite;
	}
	@keyframes slide {
		from { transform: translateX(-100%); }
		to { transform: translateX(340%); }
	}
</style>
