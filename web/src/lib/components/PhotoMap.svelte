<script lang="ts">
	// Photos on a map (MapLibre). Nearby photos cluster into one pin showing the newest photo and a
	// count; tapping a pin opens its photos. The view is remembered while the app is open.
	import { onMount } from 'svelte';
	import * as maplibregl from 'maplibre-gl';
	import type { GeoJSONSource, MapGeoJSONFeature } from 'maplibre-gl';
	import type { FeatureCollection, Point } from 'geojson';
	import 'maplibre-gl/dist/maplibre-gl.css';
	// MapLibre finds its worker next to its own file, which bundling breaks: let Vite build it.
	import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url';
	import { thumbUrl, type CatalogAsset } from '#lib/api.ts';
	import { app } from '#lib/state.svelte.ts';

	let { assets, onOpen }: { assets: CatalogAsset[]; onOpen: (ids: string[]) => void } = $props();

	let el: HTMLDivElement;
	let map: maplibregl.Map | undefined;
	let failed = $state(false);
	const markers = new Map<string, maplibregl.Marker>();

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

	function updateMarkers() {
		if (!map || !map.getSource('photos')) return;
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

	onMount(() => {
		maplibregl.setWorkerUrl(workerUrl);
		try {
			map = new maplibregl.Map({
				container: el,
				style: app.server?.mapStyleURL ?? 'https://tiles.openfreemap.org/styles/liberty',
				center: saved?.center ?? [10, 30],
				zoom: saved?.zoom ?? 1.5,
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
			if (!saved && located.length) {
				const b = new maplibregl.LngLatBounds();
				for (const a of located) b.extend([a.loc![1], a.loc![0]]);
				map!.fitBounds(b, { padding: { top: 80, bottom: 70, left: 70, right: 80 }, maxZoom: 12, duration: 0 });
			}
		});
		map.on('render', updateMarkers);
		map.on('moveend', () => {
			saved = { center: map!.getCenter().toArray() as [number, number], zoom: map!.getZoom() };
		});
		map.on('error', () => {
			/* tile failures (offline): keep the photos visible */
		});
		return () => {
			el.removeEventListener('wheel', onWheel, { capture: true });
			for (const m of markers.values()) m.remove();
			markers.clear();
			map?.remove();
		};
	});

	// Keep the pins in sync with the catalog (e.g. after a sync).
	$effect(() => {
		const data = geojson(located);
		const src = map?.getSource('photos') as GeoJSONSource | undefined;
		if (!src) return;
		for (const m of markers.values()) m.remove();
		markers.clear();
		src.setData(data);
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
</script>

<div class="map" bind:this={el}>
	{#if failed}<p class="fallback muted">The map can't be shown in this browser.</p>{/if}
</div>

<style>
	.map {
		position: absolute;
		inset: 0;
	}
	.fallback {
		text-align: center;
		padding-top: 30vh;
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
