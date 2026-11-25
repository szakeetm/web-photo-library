<script lang="ts">
	// Grid + selection + viewer. The open photo lives in history state, so Back closes the viewer.
	import { pushState, replaceState } from '$app/navigation';
	import { page } from '$app/state';
	import type { Section } from '#lib/gridLayout.ts';
	import { Selection } from '#lib/selection.svelte.ts';
	import ActionBar from './ActionBar.svelte';
	import Grid from './Grid.svelte';
	import Viewer from './Viewer.svelte';

	let {
		sections,
		startAtEnd = false,
		albumId,
		selection = new Selection()
	}: { sections: Section[]; startAtEnd?: boolean; albumId?: number; selection?: Selection } = $props();
	const ids = $derived(sections.flatMap((s) => s.items));
	const open = $derived(page.state.viewer && ids.includes(page.state.viewer) ? page.state.viewer : null);

	function activate(id: string, e: MouseEvent) {
		if (e.shiftKey && (selection.active || selection.anchor)) {
			selection.start();
			selection.extendTo(ids, id);
		} else if (e.metaKey || e.ctrlKey) {
			selection.start();
			selection.toggle(id);
		} else if (selection.active) {
			selection.toggle(id);
		} else {
			pushState('', { viewer: id });
		}
	}

	$effect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (open || e.target instanceof HTMLInputElement) return;
			if ((e.metaKey || e.ctrlKey) && e.key === 'a') {
				e.preventDefault();
				selection.selectAll(ids);
			} else if (e.key === 'Escape' && selection.active) selection.clear();
		};
		window.addEventListener('keydown', onKey);
		return () => window.removeEventListener('keydown', onKey);
	});
</script>

<Grid {sections} {startAtEnd} {selection} onActivate={activate} onLongPress={(id) => selection.start(id)} />
{#if selection.active}
	<ActionBar {selection} order={ids} {albumId} />
{/if}
{#if open}
	<Viewer {ids} id={open} onChange={(id) => replaceState('', { viewer: id })} onClose={() => history.back()} />
{/if}
