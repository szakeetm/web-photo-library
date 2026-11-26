<script lang="ts">
	// The delete confirmation (with "Don't ask again") and the Undo overlay after a deletion.
	import { deleteFlow } from '#lib/deleteFlow.svelte.ts';

	function onkey(e: KeyboardEvent) {
		// ⌘Z / Ctrl+Z: undo the last deletion while its Undo bar shows (not in a field or the editor)
		if (deleteFlow.undo && !deleteFlow.pending && (e.metaKey || e.ctrlKey) && !e.shiftKey && e.key.toLowerCase() === 'z') {
			const t = e.target as HTMLElement;
			if (t.closest?.('input, select, textarea, [contenteditable]') || document.querySelector('.editor')) return;
			e.preventDefault();
			deleteFlow.undoLast();
			return;
		}
		if (!deleteFlow.pending) return;
		// the question takes these keys (Escape must not also end selecting behind it)
		if (e.key === 'Escape' || e.key === 'Enter') {
			e.preventDefault();
			e.stopPropagation();
			deleteFlow.answer(e.key === 'Enter');
		}
	}
	$effect(() => {
		window.addEventListener('keydown', onkey, true);
		return () => window.removeEventListener('keydown', onkey, true);
	});
</script>


{#if deleteFlow.pending}
	<div class="scrim" role="presentation" onclick={() => deleteFlow.answer(false)}></div>
	<div class="dialog" role="alertdialog" aria-modal="true" aria-labelledby="del-title" aria-describedby="del-msg">
		<h3 id="del-title">{deleteFlow.pending.title}</h3>
		<p id="del-msg">{deleteFlow.pending.message}</p>
		<label class="dontask"><input type="checkbox" bind:checked={deleteFlow.dontAsk} /> Don't ask again (an Undo button shows instead)</label>
		<div class="buttons">
			<button class="btn" onclick={() => deleteFlow.answer(false)}>Cancel</button>
			<!-- svelte-ignore a11y_autofocus -->
			<button class="btn danger" autofocus onclick={() => deleteFlow.answer(true)}>Delete</button>
		</div>
	</div>
{/if}

{#if deleteFlow.undo}
	<div class="undo" role="status" aria-live="polite">
		<span>{deleteFlow.undo.text} · in the Trash</span>
		<button class="link" disabled={deleteFlow.undoing} onclick={() => deleteFlow.undoLast()}>Undo</button>
		<button class="close" aria-label="Dismiss" onclick={() => deleteFlow.dismissUndo()}>×</button>
	</div>
{/if}

<style>
	.scrim {
		position: fixed;
		inset: 0;
		z-index: 300;
		background: rgba(0, 0, 0, 0.4);
	}
	.dialog {
		position: fixed;
		z-index: 301;
		left: 50%;
		top: 50%;
		transform: translate(-50%, -50%);
		width: min(420px, calc(100vw - 24px));
		background: var(--bg);
		color: var(--fg);
		border-radius: 14px;
		padding: 18px;
		box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
		display: flex;
		flex-direction: column;
		gap: 10px;
	}
	h3 {
		margin: 0;
		font-size: 17px;
	}
	p {
		margin: 0;
		font-size: 14px;
		line-height: 1.4;
		white-space: pre-line;
	}
	.dontask {
		display: flex;
		align-items: center;
		gap: 8px;
		font-size: 13px;
		color: var(--fg-secondary);
	}
	.buttons {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
		margin-top: 4px;
	}
	.btn.danger {
		background: var(--danger);
		color: white;
	}
	.undo {
		position: fixed;
		z-index: 302;
		left: 50%;
		bottom: calc(var(--tabbar-h, 0px) + 20px + env(safe-area-inset-bottom));
		transform: translateX(-50%);
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 10px 12px 10px 16px;
		border-radius: 12px;
		background: rgba(30, 30, 30, 0.92);
		color: white;
		font-size: 14px;
		box-shadow: 0 8px 30px rgba(0, 0, 0, 0.3);
	}
	.undo .link {
		border: none;
		background: none;
		color: #4da3ff;
		font: inherit;
		font-weight: 600;
		cursor: pointer;
		padding: 4px;
	}
	.undo .close {
		border: none;
		background: none;
		color: rgba(255, 255, 255, 0.7);
		font-size: 18px;
		cursor: pointer;
		padding: 0 4px;
	}
	@media (min-width: 768px) {
		.undo {
			left: calc(50% + var(--sidebar-w) / 2);
			bottom: 24px;
		}
	}
</style>
