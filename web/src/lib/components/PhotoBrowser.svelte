<script lang="ts">
	// Grid + selection + viewer. The open photo lives in history state, so Back closes the viewer.
	import { pushState, replaceState } from '$app/navigation';
	import { page } from '$app/state';
	import type { Section } from '#lib/gridLayout.ts';
	import { applyView, FILTERS, gridView, naturalOrder, SORTS } from '#lib/gridView.svelte.ts';
	import { app, deletePhotos } from '#lib/state.svelte.ts';
	import { deleteFlow, deleteKey, deleteQuestion } from '#lib/deleteFlow.svelte.ts';
	import { net } from '#lib/net.svelte.ts';
	import { Selection } from '#lib/selection.svelte.ts';
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
		sortable = albumId == null
	}: {
		sections: Section[];
		startAtEnd?: boolean;
		albumId?: number;
		selection?: Selection;
		trash?: boolean;
		/** the order can be changed (albums: always oldest to newest) */
		sortable?: boolean;
	} = $props();

	// Filter and sort (title bar menu); not in the Trash.
	$effect(() => {
		if (trash) return;
		return gridView.attach(page.url.pathname, sortable);
	});
	$effect(() => {
		gridView.natural = naturalOrder(sections, app.byId);
	});
	const filtered = $derived(!trash && gridView.enabled ? applyView(sections, app.byId, gridView.filter, gridView.sort) : sections);
	const ids = $derived(filtered.flatMap((s) => s.items));
	const filterLabel = $derived(
		[
			gridView.filter !== 'all' ? FILTERS.find((f) => f.key === gridView.filter)?.label : '',
			gridView.sort && gridView.sort !== gridView.natural ? SORTS.find((s) => s.key === gridView.sort)?.label : ''
		]
			.filter(Boolean)
			.join(' · ')
	);
	const open = $derived(page.state.viewer && ids.includes(page.state.viewer) ? page.state.viewer : null);

	function activate(id: string, e: MouseEvent) {
		if (e.shiftKey) {
			// a range from the last clicked photo; the first shift-click starts selecting
			selection.start();
			if (selection.anchor && selection.ids.size) selection.extendTo(ids, id);
			else selection.toggle(id);
		} else if (e.metaKey || e.ctrlKey) {
			selection.start();
			selection.toggle(id);
			// unselecting the last one ends selecting
			if (selection.count === 0) selection.clear();
		} else if (selection.active) {
			selection.toggle(id);
		} else {
			pushState('', { viewer: id });
		}
	}

	// Desktop: the photo last open in the viewer stays framed in the grid, and Space opens it again
	// (Photos on the Mac). Phones don't frame it.
	const desktop = typeof matchMedia !== 'undefined' && matchMedia('(hover: hover) and (pointer: fine)').matches;
	let focused = $state<string | null>(null);
	let lastOpen: string | null = null;
	$effect(() => {
		if (open) lastOpen = open;
		else if (lastOpen) {
			if (desktop && ids.includes(lastOpen)) focused = lastOpen;
			lastOpen = null;
		}
	});
	$effect(() => {
		if (focused && !ids.includes(focused)) focused = null;
	});

	$effect(() => {
		const onKey = (e: KeyboardEvent) => {
			if (open || e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
			// Backspace/Delete on the bookmarked photo (nothing selected; the selection bar handles a selection)
			const del = deleteKey(e);
			if (del) {
				if (trash || selection.active || !focused || !net.online || document.querySelector('[role=dialog], [role=alertdialog]')) return;
				e.preventDefault();
				const id = focused;
				const q = deleteQuestion([id], (i) => app.isUpload(i));
				deleteFlow
					.remove([id], q.title, q.message, () => deletePhotos([id]), del === 'now')
					.then((done) => done && focused === id && (focused = null))
					.catch((err) => alert((err as Error).message));
				return;
			}
			if ((e.metaKey || e.ctrlKey) && e.key === 'a') {
				e.preventDefault();
				selection.selectAll(ids);
			} else if (e.key === 'Escape' && selection.active) selection.clear();
			else if (e.key === 'Escape') focused = null;
			else if (e.key === ' ' && !e.metaKey && !e.ctrlKey && !e.altKey && !document.querySelector('[role=dialog]')) {
				// one selected photo, or the framed one; several selected: nothing
				const target = selection.active ? (selection.count === 1 ? [...selection.ids][0] : null) : focused;
				if (!target && !(selection.active && selection.count > 1)) return; // nothing framed: Space scrolls
				e.preventDefault();
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
<Grid sections={filtered} {startAtEnd} {selection} {focused} onFocusMove={desktop ? (id) => (focused = id) : undefined} onActivate={activate} onLongPress={(id) => selection.start(id)} />
{#if selection.active}
	<ActionBar {selection} order={ids} {albumId} {trash} />
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
