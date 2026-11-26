<script lang="ts">
	// The short message of `hint` (bottom centre, like the Undo bar); it goes away by itself.
	import { fade } from 'svelte/transition';
	import { hint } from '#lib/hint.svelte.ts';
</script>

{#if hint.text}
	<div class="hint" role="status" aria-live="polite" transition:fade={{ duration: 150 }}>{hint.text}</div>
{/if}

<style>
	.hint {
		position: fixed;
		z-index: 302;
		left: 50%;
		bottom: calc(var(--tabbar-h, 0px) + 20px + env(safe-area-inset-bottom));
		transform: translateX(-50%);
		max-width: min(440px, calc(100vw - 32px));
		padding: 10px 16px;
		border-radius: 12px;
		background: rgba(30, 30, 30, 0.92);
		color: white;
		font-size: 14px;
		text-align: center;
		box-shadow: 0 8px 30px rgba(0, 0, 0, 0.3);
		pointer-events: none;
	}
	@media (min-width: 768px) {
		.hint {
			left: calc(50% + var(--sidebar-w) / 2);
			/* above the selection bar */
			bottom: calc(var(--tabbar-h, 56px) + 16px);
		}
	}
</style>
