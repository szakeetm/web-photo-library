<script lang="ts">
	// Grid + viewer pair. The open photo lives in history state, so Back closes the viewer.
	import { pushState, replaceState } from '$app/navigation';
	import { page } from '$app/state';
	import type { Section } from '#lib/gridLayout.ts';
	import Grid from './Grid.svelte';
	import Viewer from './Viewer.svelte';

	let { sections, startAtEnd = false }: { sections: Section[]; startAtEnd?: boolean } = $props();
	const ids = $derived(sections.flatMap((s) => s.items));
	const open = $derived(page.state.viewer && ids.includes(page.state.viewer) ? page.state.viewer : null);
</script>

<Grid {sections} {startAtEnd} onOpen={(id) => pushState('', { viewer: id })} />
{#if open}
	<Viewer {ids} id={open} onChange={(id) => replaceState('', { viewer: id })} onClose={() => history.back()} />
{/if}
