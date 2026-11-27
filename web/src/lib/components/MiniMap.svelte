<script lang="ts">
	// A small, still map of where a photo was taken (info panel), with ways to look further: the app's
	// own Places map at that spot, or Google Maps. MapLibre is loaded only when the map is shown, so the
	// viewer stays light. Without a network (and no cached tiles) the links still work.
	import { onMount } from 'svelte';
	import type { Map as MlMap, Marker } from 'maplibre-gl';
	import { app } from '#lib/state.svelte.ts';
	import { mapPinElement } from '#lib/mapPin.ts';

	let { lat, lon }: { lat: number; lon: number } = $props();

	let el = $state<HTMLDivElement>();
	let map: MlMap | undefined;
	let marker: Marker | undefined;
	let failed = $state(false);

	const google = $derived(`https://www.google.com/maps/search/?api=1&query=${lat},${lon}`);
	const places = $derived(`/places?at=${lat.toFixed(6)},${lon.toFixed(6)}`);

	onMount(() => {
		let gone = false;
		(async () => {
			try {
				const [ml, worker] = await Promise.all([
					import('maplibre-gl'),
					// MapLibre finds its worker next to its own file, which bundling breaks: let Vite build it.
					import('maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url'),
					import('maplibre-gl/dist/maplibre-gl.css')
				]);
				if (gone || !el) return;
				ml.setWorkerUrl(worker.default);
				map = new ml.Map({
					container: el,
					style: app.server?.mapStyleURL ?? 'https://tiles.openfreemap.org/styles/liberty',
					center: [lon, lat],
					zoom: 13,
					interactive: false,
					attributionControl: false
				});
				marker = new ml.Marker({ element: mapPinElement(), anchor: 'bottom' }).setLngLat([lon, lat]).addTo(map);
			} catch {
				failed = true;
			}
		})();
		return () => {
			gone = true;
			map?.remove();
		};
	});

	// the next photo: the same map, moved
	$effect(() => {
		const c: [number, number] = [lon, lat];
		map?.jumpTo({ center: c });
		marker?.setLngLat(c);
	});
</script>

<div class="minimap">
	{#if !failed}
		<a class="map" href={google} target="_blank" rel="noreferrer" aria-label="Open in Google Maps"><div bind:this={el}></div></a>
	{/if}
	<div class="links">
		<a class="btn" href={places}>Open in Places</a>
		<a class="btn" href={google} target="_blank" rel="noreferrer">Open in Google Maps</a>
	</div>
</div>

<style>
	.minimap {
		margin-top: 14px;
		padding-top: 12px;
		border-top: 0.5px solid var(--separator);
	}
	.map {
		display: block;
		border-radius: 10px;
		overflow: hidden;
		background: var(--bg-elevated);
	}
	.map > div {
		width: 100%;
		height: 160px;
		/* a still map: the whole of it is the link */
		pointer-events: none;
	}
	.links {
		display: flex;
		gap: 8px;
		margin-top: 8px;
	}
	.links .btn {
		flex: 1;
		text-align: center;
		text-decoration: none;
		color: var(--accent);
		font-size: 13px;
	}

</style>
