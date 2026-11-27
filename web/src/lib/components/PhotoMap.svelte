<script lang="ts">
	// Photos on a map (MapLibre). Nearby photos cluster into one pin showing the newest photo and a
	// count; tapping a pin opens its photos. The view is remembered while the app is open.
	// A switch shows a heatmap instead (where you took most photos); tapping it opens the photos
	// around the tap. `focus` centres the map on one spot and marks it (Open in Places).
	import { onMount } from 'svelte';
	import * as maplibregl from 'maplibre-gl';
	import type { GeoJSONSource, MapGeoJSONFeature } from 'maplibre-gl';
	import type { FeatureCollection, Point } from 'geojson';
	import 'maplibre-gl/dist/maplibre-gl.css';
	// MapLibre finds its worker next to its own file, which bundling breaks: let Vite build it.
	import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url';
	import { thumbUrl, type CatalogAsset } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';

	let { assets, onOpen, focus }: { assets: CatalogAsset[]; onOpen: (ids: string[]) => void; focus?: MapFocus | null } = $props();

	let el: HTMLDivElement;
	let map: maplibregl.Map | undefined;
	let failed = $state(false);
	const markers = new Map<string, maplibregl.Marker>();
	let focusMarker: maplibregl.Marker | undefined;

	// Photos (thumbnail pins) or Heatmap, remembered for this browser session only.
	let mode = $state<'photos' | 'heat'>(readMode());
	function readMode(): 'photos' | 'heat' {
		try {
			return sessionStorage.getItem('placesMapMode') === 'heat' ? 'heat' : 'photos';
		} catch {
			return 'photos';
		}
	}
	$effect(() => {
		try {
			sessionStorage.setItem('placesMapMode', mode);
		} catch {
			/* private mode */
		}
	});

	const located = $derived(assets.filter((a) => a.loc));

	function geojson(list: CatalogAsset[]): FeatureCollection {
		return {
			type: 'FeatureCollection',
			// `i` = position in `list` (oldest first): the cluster keeps the largest = newest photo
			features: list.map((a, i) => ({
				type: 'Feature',
				id: i,
				properties: { i },
				geometry: { type: 'Point', coordinates: [a.loc![1], a.loc![0]] }
			}))
		};
	}

	function pinElement(asset: CatalogAsset, count: number) {
		const div = document.createElement('button');
		div.className = 'photo-pin';
		div.setAttribute('aria-label', count > 1 ? `${count} photos` : asset.name);
		const img = document.createElement('img');
		img.src = thumbUrl(asset.id, asset.ev, app.fmt);
		img.alt = '';
		img.draggable = false;
		div.appendChild(img);
		if (count > 1) {
			const badge = document.createElement('span');
			badge.textContent = count > 999 ? `${Math.round(count / 100) / 10}k` : String(count);
			div.appendChild(badge);
		}
		return div;
	}

	function clearMarkers() {
		for (const m of markers.values()) m.remove();
		markers.clear();
	}

	function updateMarkers() {
		if (!map || !map.getSource('photos')) return;
		// The heatmap replaces the pins (they would hide it).
		if (mode === 'heat') return clearMarkers();
		const list = located;
		const seen = new Set<string>();
		const features = map.querySourceFeatures('photos') as MapGeoJSONFeature[];
		for (const f of features) {
			const p = f.properties as { cluster?: boolean; cluster_id?: number; point_count?: number; i?: number; newest?: number };
			const key = p.cluster ? `c${p.cluster_id}` : `p${p.i}`;
			if (seen.has(key)) continue;
			seen.add(key);
			if (markers.has(key)) continue;
			const asset = list[p.cluster ? p.newest! : p.i!];
			if (!asset) continue;
			const count = p.cluster ? p.point_count! : 1;
			const node = pinElement(asset, count);
			const coords = (f.geometry as Point).coordinates as [number, number];
			node.addEventListener('click', async (e) => {
				e.stopPropagation();
				if (!p.cluster) return onOpen([asset.id]);
				const src = map!.getSource('photos') as GeoJSONSource;
				const zoom = await src.getClusterExpansionZoom(p.cluster_id!);
				if (zoom <= 14 && map!.getZoom() < 14) {
					map!.easeTo({ center: coords, zoom: zoom + 0.5 });
				} else {
					const leaves = await src.getClusterLeaves(p.cluster_id!, 10000, 0);
					onOpen(leaves.map((l) => list[(l.properties as { i: number }).i].id).reverse());
				}
			});
			markers.set(key, new maplibregl.Marker({ element: node }).setLngLat(coords).addTo(map));
		}
		for (const [key, m] of markers) {
			if (!seen.has(key)) {
				m.remove();
				markers.delete(key);
			}
		}
	}

	/** Photos within `radius` screen pixels of `point`, newest first (the order pins open them in). */
	function photosNear(point: maplibregl.Point, radius: number): string[] {
		if (!map) return [];
		// Rough lat/lon box first, so only photos nearby are projected to the screen.
		const a = map.unproject([point.x - radius, point.y - radius]);
		const b = map.unproject([point.x + radius, point.y + radius]);
		const [west, east] = [Math.min(a.lng, b.lng), Math.max(a.lng, b.lng)];
		const [south, north] = [Math.min(a.lat, b.lat), Math.max(a.lat, b.lat)];
		const list = located;
		const ids: string[] = [];
		for (let i = list.length - 1; i >= 0; i--) {
			const [lat, lon] = list[i].loc!;
			if (lat < south || lat > north || lon < west || lon > east) continue;
			const p = map.project([lon, lat]);
			if (Math.hypot(p.x - point.x, p.y - point.y) <= radius) ids.push(list[i].id);
		}
		return ids;
	}

	function applyMode(m: 'photos' | 'heat') {
		if (!map?.getLayer('photos-heat')) return;
		map.setLayoutProperty('photos-heat', 'visibility', m === 'heat' ? 'visible' : 'none');
		// Pins are drawn on render: ask for one so they come back (or go) straight away.
		map.triggerRepaint();
	}

	function placeFocusMarker() {
		focusMarker?.remove();
		focusMarker = undefined;
		if (!map || !focus) return;
		const ring = document.createElement('div');
		ring.className = 'focus-pin';
		ring.setAttribute('aria-hidden', 'true');
		focusMarker = new maplibregl.Marker({ element: ring }).setLngLat([focus.lon, focus.lat]).addTo(map);
	}

	onMount(() => {
		maplibregl.setWorkerUrl(workerUrl);
		// A spot asked for in the link wins over the remembered view, but only the first time: coming
		// back from its photos (or switching List and back) keeps where the user moved the map to.
		const key = focusKey(focus);
		const centre = key && (key !== centredFocus || !saved);
		if (centre) centredFocus = key;
		try {
			map = new maplibregl.Map({
				container: el,
				style: app.server?.mapStyleURL ?? 'https://tiles.openfreemap.org/styles/liberty',
				center: centre ? [focus!.lon, focus!.lat] : (saved?.center ?? [10, 30]),
				zoom: centre ? focus!.zoom : (saved?.zoom ?? 1.5),
				attributionControl: { compact: true },
				dragRotate: false,
				pitchWithRotate: false
			});
		} catch {
			failed = true;
			return;
		}
		map.touchZoomRotate.disableRotation();
		// Trackpads (Apple Maps style): two-finger scroll moves the map, pinch zooms. Pinches arrive as
		// ctrl+wheel and mouse wheels as coarse vertical steps: both are left to MapLibre's scroll zoom.
		const onWheel = (e: WheelEvent) => {
			if (e.ctrlKey || isMouseWheel(e)) return;
			e.preventDefault();
			e.stopPropagation();
			map!.panBy([e.deltaX, e.deltaY], { duration: 0 });
		};
		el.addEventListener('wheel', onWheel, { capture: true, passive: false });
		map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
		map.on('load', () => {
			map!.addSource('photos', {
				type: 'geojson',
				data: geojson(located),
				cluster: true,
				clusterRadius: 56,
				clusterMaxZoom: 17,
				clusterProperties: { newest: ['max', ['get', 'i']] }
			});
			// An invisible layer keeps the clustered tiles loaded so markers can be queried.
			map!.addLayer({ id: 'photos-hit', type: 'circle', source: 'photos', paint: { 'circle-radius': 1, 'circle-opacity': 0 } });
			// The heatmap needs every photo as its own point, so it has its own unclustered copy.
			map!.addSource('photos-heat', { type: 'geojson', data: geojson(located) });
			map!.addLayer({
				id: 'photos-heat',
				type: 'heatmap',
				source: 'photos-heat',
				layout: { visibility: mode === 'heat' ? 'visible' : 'none' },
				paint: {
					// A library has tens of thousands of photos, many at the same few places: each counts for
					// little, so only the places with very many photos turn yellow and the rest stay blue/purple
					// (like Google Photos). Zoomed in, photos spread out, so each counts for more.
					'heatmap-weight': 0.06,
					'heatmap-intensity': ['interpolate', ['linear'], ['zoom'], 0, 0.25, 9, 0.6, 14, 1.2, 18, 2.5],
					// Purple/blue where there are a few photos, through magenta and orange to yellow.
					'heatmap-color': [
						'interpolate',
						['linear'],
						['heatmap-density'],
						0,
						'rgba(70, 40, 160, 0)',
						0.08,
						'rgba(80, 60, 200, 0.55)',
						0.25,
						'rgb(120, 70, 230)',
						0.45,
						'rgb(200, 60, 200)',
						0.65,
						'rgb(240, 80, 120)',
						0.82,
						'rgb(255, 150, 50)',
						1,
						'rgb(255, 235, 80)'
					],
					// Big, soft blobs that grow with the zoom so single photos stay visible up close.
					'heatmap-radius': ['interpolate', ['linear'], ['zoom'], 0, 6, 6, 12, 12, 20, 18, 36],
					'heatmap-opacity': 0.8
				}
			});
			if (!saved && !focus && located.length) {
				const b = new maplibregl.LngLatBounds();
				for (const a of located) b.extend([a.loc![1], a.loc![0]]);
				map!.fitBounds(b, { padding: { top: 80, bottom: 70, left: 70, right: 80 }, maxZoom: 12, duration: 0 });
			}
		});
		map.on('render', updateMarkers);
		// Heatmap: a tap opens the photos within a finger's reach of it (pins handle their own taps).
		map.on('click', (e) => {
			if (mode !== 'heat') return;
			const ids = photosNear(e.point, 40);
			if (ids.length) onOpen(ids);
		});
		map.on('moveend', () => {
			saved = { center: map!.getCenter().toArray() as [number, number], zoom: map!.getZoom() };
		});
		map.on('error', () => {
			/* tile failures (offline): keep the photos visible */
		});
		return () => {
			el.removeEventListener('wheel', onWheel, { capture: true });
			clearMarkers();
			focusMarker?.remove();
			map?.remove();
		};
	});

	// Keep the pins in sync with the catalog (e.g. after a sync).
	$effect(() => {
		const data = geojson(located);
		const src = map?.getSource('photos') as GeoJSONSource | undefined;
		if (!src) return;
		clearMarkers();
		src.setData(data);
		(map!.getSource('photos-heat') as GeoJSONSource | undefined)?.setData(data);
	});

	$effect(() => applyMode(mode));

	// Marks the spot once the map exists (this runs after onMount), and moves to a new spot given
	// while the map is open (another Open in Places link).
	$effect(() => {
		const key = focusKey(focus);
		if (!map) return;
		placeFocusMarker();
		if (key && key !== centredFocus) {
			centredFocus = key;
			map.jumpTo({ center: [focus!.lon, focus!.lat], zoom: focus!.zoom });
		}
	});
</script>

<script lang="ts" module>
	/** A mouse wheel notch (lines/pages, or a large whole-pixel vertical step) rather than a trackpad swipe. */
	export function isMouseWheel(e: Pick<WheelEvent, 'deltaMode' | 'deltaX' | 'deltaY'>) {
		if (e.deltaMode !== 0) return true;
		return e.deltaX === 0 && Number.isInteger(e.deltaY) && Math.abs(e.deltaY) >= 50 && Math.abs(e.deltaY) % 25 === 0;
	}
	/** Last map view, kept while the app runs (returning from a photo restores it). */
	let saved: { center: [number, number]; zoom: number } | null = null;
	/** The `focus` the map was last centred on, so returning to the same link keeps the user's view. */
	let centredFocus: string | null = null;

	/** A spot to centre the map on and mark. */
	export type MapFocus = { lat: number; lon: number; zoom: number };

	function focusKey(f: MapFocus | null | undefined) {
		return f ? `${f.lat},${f.lon},${f.zoom}` : null;
	}

	/** Reads `at=LAT,LON` and `z=ZOOM` (default 15) from a link; null when `at` is missing or invalid. */
	export function parseFocus(at: string | null, z: string | null): MapFocus | null {
		if (!at) return null;
		const parts = at.split(',');
		if (parts.length !== 2 || parts.some((p) => p.trim() === '')) return null;
		const [lat, lon] = parts.map(Number);
		if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
		const zoom = z != null && z.trim() !== '' ? Number(z) : NaN;
		return { lat, lon, zoom: Number.isFinite(zoom) && zoom >= 0 && zoom <= 22 ? zoom : 15 };
	}
</script>

<!-- The switch sits beside the map's container, not in it, so its taps never reach the map. -->
<div class="wrap">
	<div class="map" bind:this={el}>
		{#if failed}<p class="fallback muted">The map can't be shown in this browser.</p>{/if}
	</div>
	{#if !failed}
		<div class="mode" role="radiogroup" aria-label="Map shows">
			<button role="radio" aria-checked={mode === 'photos'} class:on={mode === 'photos'} onclick={() => (mode = 'photos')}>Photos</button>
			<button role="radio" aria-checked={mode === 'heat'} class:on={mode === 'heat'} onclick={() => (mode = 'heat')}>Heatmap</button>
		</div>
	{/if}
</div>

<style>
	.wrap,
	.map {
		position: absolute;
		inset: 0;
	}
	.fallback {
		text-align: center;
		padding-top: 30vh;
	}
	/* Floats over the map's top-left corner (zoom buttons are top-right), above MapLibre's canvas. */
	.mode {
		position: absolute;
		top: 10px;
		left: 10px;
		z-index: 2;
		display: inline-flex;
		background: var(--bg-elevated);
		border-radius: 8px;
		padding: 2px;
		box-shadow: 0 1px 6px rgba(0, 0, 0, 0.3);
	}
	.mode button {
		border: none;
		background: none;
		padding: 6px 12px;
		border-radius: 6px;
		cursor: pointer;
		font: inherit;
		font-size: 13px;
		color: var(--fg);
	}
	.mode button.on {
		background: var(--bg);
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
		font-weight: 600;
	}
	/* The linked spot: an accent dot in a pulsing ring, over the pins but never catching taps. */
	:global(.focus-pin) {
		width: 18px;
		height: 18px;
		border-radius: 50%;
		background: var(--accent);
		border: 3px solid white;
		box-shadow:
			0 0 0 4px color-mix(in srgb, var(--accent) 35%, transparent),
			0 1px 4px rgba(0, 0, 0, 0.4);
		pointer-events: none;
		z-index: 3;
		animation: focus-pulse 1.8s ease-out infinite;
	}
	@keyframes -global-focus-pulse {
		0% {
			box-shadow:
				0 0 0 0 color-mix(in srgb, var(--accent) 55%, transparent),
				0 1px 4px rgba(0, 0, 0, 0.4);
		}
		100% {
			box-shadow:
				0 0 0 16px color-mix(in srgb, var(--accent) 0%, transparent),
				0 1px 4px rgba(0, 0, 0, 0.4);
		}
	}
	@media (prefers-reduced-motion: reduce) {
		:global(.focus-pin) {
			animation: none;
		}
	}
	/* no `position` here: MapLibre positions markers absolutely (which also anchors the badge) */
	:global(.photo-pin) {
		width: 52px;
		height: 52px;
		padding: 0;
		border: 2.5px solid white;
		border-radius: 10px;
		background: #ddd;
		box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35);
		cursor: pointer;
		overflow: visible;
	}
	:global(.photo-pin img) {
		width: 100%;
		height: 100%;
		object-fit: cover;
		border-radius: 7px;
		display: block;
	}
	:global(.photo-pin span) {
		position: absolute;
		top: -9px;
		right: -9px;
		min-width: 22px;
		height: 22px;
		padding: 0 6px;
		border-radius: 11px;
		background: var(--accent);
		color: white;
		font-size: 12px;
		font-weight: 600;
		line-height: 22px;
		text-align: center;
		box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3);
	}
</style>
