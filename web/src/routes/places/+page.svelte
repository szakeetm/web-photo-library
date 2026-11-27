<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { thumbUrl } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';
	import { groupPlaces, mapPick } from '#lib/places.svelte.ts';
	import PhotoMap, { parseFocus } from '#lib/components/PhotoMap.svelte';
	import TitleBar from '#lib/components/TitleBar.svelte';

	// `/places?at=LAT,LON&z=ZOOM` (Open in Places on a photo): the map centred on that spot, marked.
	const focus = $derived(parseFocus(page.url.searchParams.get('at'), page.url.searchParams.get('z')));
	// A link to a spot always shows the map, even if the list was last used.
	const linked = parseFocus(page.url.searchParams.get('at'), page.url.searchParams.get('z')) != null;
	let view = $state<'map' | 'list'>(!linked && typeof sessionStorage !== 'undefined' && sessionStorage.getItem('placesView') === 'list' ? 'list' : 'map');
	// …also when such a link is followed while Places is already open.
	$effect.pre(() => {
		if (focus) view = 'map';
	});
	$effect(() => {
		try {
			sessionStorage.setItem('placesView', view);
		} catch {
			/* private mode */
		}
	});
	const located = $derived(app.index.located);
	const groups = $derived(groupPlaces(app.assets, app.places));

	function open(ids: string[]) {
		if (ids.length === 1) {
			mapPick.ids = ids;
			goto('/places/selection', { state: { viewer: ids[0] } });
			return;
		}
		mapPick.ids = ids;
		goto('/places/selection');
	}
</script>

<TitleBar title="Places" subtitle={located.length ? `${located.length.toLocaleString()} photos with a location` : undefined}>
	{#snippet actions()}
		<div class="seg" role="tablist" aria-label="View">
			<button role="tab" aria-selected={view === 'map'} class:on={view === 'map'} onclick={() => (view = 'map')}>Map</button>
			<button role="tab" aria-selected={view === 'list'} class:on={view === 'list'} onclick={() => (view = 'list')}>List</button>
		</div>
	{/snippet}
</TitleBar>

{#if app.loaded && located.length === 0}
	<p class="empty muted">None of your photos has a location yet. Photos taken with location services on appear here.</p>
{:else if view === 'map'}
	<div class="mapwrap"><PhotoMap assets={app.assets} onOpen={open} {focus} /></div>
{:else}
	{#each groups as g (g.cc)}
		<section>
			<a class="country" href="/places/country/{g.cc}">
				<h2>{g.country}</h2>
				<span class="muted">{g.count.toLocaleString()}</span>
			</a>
			<div class="cities">
				{#each g.cities as c (c.place.id)}
					{@const a = c.cover ? app.byId.get(c.cover) : undefined}
					<a class="city" href="/places/{c.place.id}">
						<div class="cover">{#if a}<img src={thumbUrl(a.id, a.ev, app.fmt)} alt="" loading="lazy" />{/if}</div>
						<div class="name">{c.place.name}</div>
						<div class="muted small">{c.place.region ? `${c.place.region} · ` : ''}{c.count.toLocaleString()}</div>
					</a>
				{/each}
			</div>
		</section>
	{/each}
{/if}

<style>
	.seg {
		display: inline-flex;
		background: var(--bg-elevated);
		border-radius: 8px;
		padding: 2px;
	}
	.seg button {
		border: none;
		background: none;
		padding: 5px 12px;
		border-radius: 6px;
		cursor: pointer;
		font: inherit;
		font-size: 13px;
		color: var(--fg);
	}
	.seg button.on {
		background: var(--bg);
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
		font-weight: 600;
	}
	.mapwrap {
		position: relative;
		height: calc(100dvh - 56px - var(--tabbar-h) - env(safe-area-inset-bottom) - env(safe-area-inset-top));
	}
	@media (min-width: 768px) {
		.mapwrap {
			height: calc(100dvh - 56px);
		}
	}
	section {
		padding: 4px 0 12px;
	}
	.country {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 8px 16px 4px;
		color: var(--fg);
	}
	.country h2 {
		font-size: 19px;
		margin: 0;
	}
	.cities {
		display: grid;
		grid-auto-flow: column;
		grid-auto-columns: 150px;
		gap: 12px;
		overflow-x: auto;
		padding: 4px 16px 8px;
		scrollbar-width: thin;
	}
	.city {
		color: var(--fg);
		min-width: 0;
	}
	.cover {
		aspect-ratio: 1;
		border-radius: 10px;
		overflow: hidden;
		background: var(--bg-elevated);
	}
	.cover img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}
	.name {
		font-weight: 500;
		margin-top: 6px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.small {
		font-size: 12px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.empty {
		text-align: center;
		padding: 80px 20px;
	}
</style>
