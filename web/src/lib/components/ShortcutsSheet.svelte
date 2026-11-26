<script lang="ts">
	// Every keyboard shortcut, grouped by where it works (the ? key or the sidebar's info button).
	import { onMount } from 'svelte';
	import { isApple, shortcut } from '#lib/platform.ts';
	import Icon from './Icon.svelte';

	let { onClose }: { onClose: () => void } = $props();

	const mod = isApple ? '⌘' : 'Ctrl+';
	const shift = isApple ? '⇧' : 'Shift+';

	/** [keys (alternatives), what they do] */
	const groups: { title: string; items: [string[], string][] }[] = [
		{
			title: 'Photos',
			items: [
				[[`${mod}click`], 'Select or unselect a photo'],
				[[`${shift}click`], 'Select every photo up to this one'],
				[[shortcut('A')], 'Select all'],
				[['L', 'R'], 'Rotate the selected photos left / right'],
				[['Esc'], 'Stop selecting'],
				[['+', '−'], 'Larger / smaller thumbnails']
			]
		},
		{
			title: 'Viewer',
			items: [
				[['←', '→'], 'Previous / next photo'],
				[['L', 'R'], 'Rotate left / right'],
				[['[', ']'], 'Rotate left / right'],
				[['F'], 'Favourite'],
				[['I'], 'Info'],
				[['E'], 'Edit'],
				[['Space'], 'Play or pause a video; close a photo'],
				[['Esc'], 'Close the info, then the viewer']
			]
		},
		{
			title: 'Editor',
			items: [
				[[shortcut('Z')], 'Undo'],
				[isApple ? [shortcut('Z', true)] : [shortcut('Z', true), 'Ctrl+Y'], 'Redo'],
				[[shortcut('['), shortcut(']')], 'Rotate left / right'],
				[['C'], 'Crop on / off'],
				[['Return'], 'Finish cropping'],
				[['\\'], 'Hold to see the original'],
				[['Esc'], 'Leave cropping, then cancel']
			]
		},
		{
			title: 'Video trim',
			items: [[['←', '→'], `Move the focused handle (${shift.replace('+', '')}: 1 s steps)`]]
		},
		{ title: 'Anywhere', items: [[['?'], 'This list']] }
	];

	onMount(() => {
		const onKey = (e: KeyboardEvent) => {
			if (e.key === 'Escape') {
				e.stopPropagation();
				onClose();
			}
		};
		window.addEventListener('keydown', onKey, true);
		return () => window.removeEventListener('keydown', onKey, true);
	});
</script>

<div class="backdrop" role="presentation" onclick={onClose}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-label="Keyboard shortcuts">
	<header>
		<h2>Keyboard shortcuts</h2>
		<button class="icon-btn" onclick={onClose} aria-label="Close"><Icon name="close" /></button>
	</header>
	<div class="body">
		{#each groups as g (g.title)}
			<section>
				<h3>{g.title}</h3>
				<dl>
					{#each g.items as [keys, what], i (i)}
						<dt>{#each keys as k, j (j)}{#if j}<span class="or">/</span>{/if}<kbd>{k}</kbd>{/each}</dt>
						<dd>{what}</dd>
					{/each}
				</dl>
			</section>
		{/each}
	</div>
</div>

<style>
	.backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.35);
		z-index: 150;
	}
	.sheet {
		position: fixed;
		z-index: 151;
		left: 50%;
		top: 50%;
		transform: translate(-50%, -50%);
		width: min(640px, calc(100vw - 32px));
		max-height: 85dvh;
		display: flex;
		flex-direction: column;
		background: var(--bg);
		border-radius: 14px;
		box-shadow: 0 10px 40px rgba(0, 0, 0, 0.3);
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 12px 12px 6px 18px;
	}
	h2 {
		font-size: 17px;
		margin: 0;
	}
	.body {
		overflow: auto;
		padding: 0 18px 18px;
		columns: 2 260px;
		column-gap: 28px;
	}
	section {
		break-inside: avoid;
		padding-top: 10px;
	}
	h3 {
		font-size: 12px;
		font-weight: 600;
		text-transform: uppercase;
		letter-spacing: 0.04em;
		color: var(--fg-secondary, inherit);
		opacity: 0.7;
		margin: 0 0 6px;
	}
	dl {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 5px 12px;
		margin: 0;
		align-items: baseline;
	}
	dt {
		white-space: nowrap;
		text-align: right;
	}
	dd {
		margin: 0;
		font-size: 13px;
	}
	kbd {
		display: inline-block;
		min-width: 1.6em;
		padding: 1px 6px;
		border-radius: 5px;
		border: 0.5px solid var(--separator);
		background: var(--bg-elevated);
		font: inherit;
		font-size: 12px;
		text-align: center;
	}
	.or {
		margin: 0 3px;
		font-size: 11px;
		opacity: 0.5;
	}
</style>
