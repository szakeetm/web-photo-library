<script lang="ts">
	// What the app is doing with the library, at the top: opening the device copy, reaching the server,
	// checking for changes (only when it takes a moment), then briefly what came from the server.
	// The full download (LibraryDownload) and being offline (the banner) are shown elsewhere.
	import { fade } from 'svelte/transition';
	import { app } from '#lib/state.svelte.ts';
	import { net } from '#lib/net.svelte.ts';

	const DELAY_MS = 500; // a quick check shows nothing
	const RESULT_MS = 3500;

	const busy = $derived(!app.loaded || app.sync != null);
	let slow = $state(false);
	$effect(() => {
		slow = false;
		if (!busy) return;
		const t = setTimeout(() => (slow = true), DELAY_MS);
		return () => clearTimeout(t);
	});

	let result = $state<string | null>(null);
	$effect(() => {
		const s = app.synced;
		if (!s) return;
		const parts = [
			s.added && `${s.added.toLocaleString()} new`,
			s.removed && `${s.removed.toLocaleString()} removed`,
			s.changed && `${s.changed.toLocaleString()} changed`
		].filter(Boolean);
		result = `Library updated · ${parts.join(' · ')}`;
		const t = setTimeout(() => (result = null), RESULT_MS);
		return () => clearTimeout(t);
	});

	const busyText = $derived(
		!app.loaded ? 'Opening library…' : app.sync === 'reaching' ? 'Connecting to the server…' : app.sync === 'updating' ? 'Checking for changes…' : null
	);
	const text = $derived(app.download || !net.online ? null : slow && busyText ? busyText : result);
	const spinning = $derived(slow && busyText != null && text === busyText);
</script>

{#if text}
	<div class="sync" role="status" aria-live="polite" transition:fade={{ duration: 150 }}>
		{#if spinning}<span class="spinner" aria-hidden="true"></span>{/if}
		{text}
	</div>
{/if}

<style>
	.sync {
		position: fixed;
		z-index: 49;
		left: 50%;
		top: calc(env(safe-area-inset-top) + 8px);
		transform: translateX(-50%);
		display: flex;
		align-items: center;
		gap: 8px;
		max-width: calc(100vw - 32px);
		padding: 6px 14px;
		border-radius: 999px;
		background: var(--bg-elevated);
		box-shadow: 0 2px 12px rgb(0 0 0 / 0.18);
		font-size: 13px;
		white-space: nowrap;
		pointer-events: none;
	}
	.spinner {
		width: 12px;
		height: 12px;
		flex: none;
		border-radius: 50%;
		border: 2px solid var(--separator);
		border-top-color: var(--accent);
		animation: spin 0.8s linear infinite;
	}
	@keyframes spin {
		to { transform: rotate(360deg); }
	}
	@media (min-width: 768px) {
		.sync {
			left: calc(50% + var(--sidebar-w) / 2);
		}
	}
</style>
