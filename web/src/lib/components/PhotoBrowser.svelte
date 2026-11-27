<script lang="ts">
	// Grid + selection + viewer. The open photo lives in history state, so Back closes the viewer.
	import { pushState, replaceState } from '$app/navigation';
	import { page } from '$app/state';
	import type { Section } from '#lib/gridLayout.ts';
	import { applyView, FILTERS, gridView, naturalOrder, SORTS, type SortPolicy } from '#lib/gridView.svelte.ts';
	import { app } from '#lib/state.svelte.ts';
	import { Selection, SELECT_ALL_MAX, selectAllRefused } from '#lib/selection.svelte.ts';
	import { hint } from '#lib/hint.svelte.ts';
	import ActionBar from './ActionBar.svelte';
	import Grid from './Grid.svelte';
	import Viewer from './Viewer.svelte';
	import Icon from './Icon.svelte';

	let {
		sections,
		startAtEnd = false,
		albumId,
		selection = new Selection(),
		trash = false,
		sortable = true,
		order = null
	}: {
		sections: Section[];
		startAtEnd?: boolean;
		albumId?: number;
		selection?: Selection;
		trash?: boolean;
		/** the order can be changed */
		sortable?: boolean;
		/** the page's own order (see SortPolicy); otherwise the choice is kept for the session */
		order?: SortPolicy | null;
	} = $props();

	// Filter and sort (title bar menu); not in the Trash.
	$effect(() => {
		if (trash) return;
		return gridView.attach(page.url.pathname, sortable, order);
	});
	$effect(() => {
		gridView.natural = naturalOrder(sections, app.byId);
	});
	const filtered = $derived(!trash && gridView.enabled ? applyView(sections, app.byId, gridView.filter, gridView.sort) : sections);
	const ids = $derived(filtered.flatMap((s) => s.items));
	const filterLabel = $derived(
		[
			gridView.filter !== 'all' ? FILTERS.find((f) => f.key === gridView.filter)?.label : '',
			(gridView.sort ?? gridView.natural) !== gridView.baseline ? SORTS.find((s) => s.key === (gridView.sort ?? gridView.natural))?.label : ''
		]
			.filter(Boolean)
			.join(' · ')
	);
	const open = $derived(page.state.viewer && ids.includes(page.state.viewer) ? page.state.viewer : null);

	// Desktop: a click selects that photo and opens it (Space opens the selected one again),
	// ⌘/Ctrl-click adds and removes, shift-click selects a range; the action bar shows from two photos on.
	// Phones: a tap opens the photo; Select or a long press start selecting, and taps add and remove.
	const desktop = typeof matchMedia !== 'undefined' && matchMedia('(hover: hover) and (pointer: fine)').matches;

	function activate(id: string, e: MouseEvent) {
		if (e.shiftKey) {
			// a range from the last clicked photo
			if (!desktop) selection.start();
			if (selection.anchor && selection.ids.size) selection.extendTo(ids, id);
			else selection.toggle(id);
		} else if (e.metaKey || e.ctrlKey) {
			if (!desktop) selection.start();
			selection.toggle(id);
			// unselecting the last one ends selecting
			if (selection.count === 0) selection.clear();
		} else if (desktop && !selection.explicit) {
			// a click selects just that photo and opens it; closing the viewer leaves it selected
			selection.only(id);
			pushState('', { viewer: id });
		} else if (selection.active) {
			selection.toggle(id);
		} else {
			pushState('', { viewer: id });
		}
	}

	// Desktop: the photo last open in the viewer stays selected (unless Select was pressed), so Space
	// opens it again and the arrow keys move on from it.
	let lastOpen: string | null = null;
	$effect(() => {
		if (open) lastOpen = open;
		else if (lastOpen) {
			if (desktop && !selection.explicit && ids.includes(lastOpen)) selection.only(lastOpen);
			lastOpen = null;
		}
	});
	// photos that left this list (deleted, filtered out) leave the selection
	$effect(() => {
		const shown = new Set(ids);
		if ([...selection.ids].some((i) => !shown.has(i))) {
			const keep = [...selection.ids].filter((i) => shown.has(i));
			if (keep.length) selection.ids = new Set(keep);
			else selection.clear();
		}
	});

	$effect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (open || e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
			if ((e.metaKey || e.ctrlKey) && e.key === 'a') {
				e.preventDefault(); // not the page's text either
				if (ids.length <= SELECT_ALL_MAX) selection.selectAll(ids);
				else hint.show(selectAllRefused(ids.length));
			} else if (e.key === 'Escape' && (selection.count || selection.explicit)) selection.clear();
			else if (e.key === ' ' && !e.metaKey && !e.ctrlKey && !e.altKey && !document.querySelector('[role=dialog], [role=alertdialog]')) {
				// one selected photo opens; several: nothing; none: Space scrolls the page
				if (!selection.count) return;
				e.preventDefault();
				const target = selection.count === 1 ? selection.cursor : null;
				if (target && ids.includes(target)) pushState('', { viewer: target });
			}
		};
		window.addEventListener('keydown', onKey);
		return () => window.removeEventListener('keydown', onKey);
	});
</script>

{#if !trash && gridView.enabled && gridView.active}
	<div class="viewchip">
		<span>{filterLabel}</span>
		<button class="icon-btn" aria-label="Show all" title="Show all" onclick={() => gridView.set('all', null)}><Icon name="close" size={14} /></button>
	</div>
	{#if ids.length === 0 && sections.some((s) => s.items.length)}
		<p class="nomatch muted">Nothing here matches “{filterLabel}”.</p>
	{/if}
{/if}
<Grid sections={filtered} {startAtEnd} {selection} onFocusMove={desktop ? (id) => selection.only(id) : undefined} onActivate={activate} onLongPress={(id) => selection.start(id)} />
<!-- one photo selected on a desktop: no bar (open it to act on it), but its keys (⌫, L/R) work -->
{#if selection.active || selection.count}
	<ActionBar {selection} order={ids} {albumId} {trash} hidden={!selection.active} />
{/if}
{#if open}
	<Viewer {ids} id={open} onChange={(id) => replaceState('', { viewer: id })} onClose={() => history.back()} {trash} />
{/if}

<style>
	.viewchip {
		display: flex;
		align-items: center;
		gap: 2px;
		width: fit-content;
		margin: 2px 12px 6px;
		padding: 2px 4px 2px 12px;
		border-radius: 999px;
		font-size: 13px;
		font-weight: 600;
		color: var(--accent);
		background: color-mix(in srgb, var(--accent) 14%, transparent);
	}
	.viewchip .icon-btn {
		padding: 4px;
		color: inherit;
	}
	.nomatch {
		text-align: center;
		padding: 40px 20px;
	}
</style>
