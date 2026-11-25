// Places helpers: grouping the catalog's places by country, and the photos picked on the map.
import type { CatalogAsset, CatalogPlace } from './api';

export interface CountryGroup {
	cc: string;
	country: string;
	count: number;
	cover: string | null;
	cities: { place: CatalogPlace; count: number; cover: string | null }[];
}

/** Countries (most photos first) with their cities (most photos first); covers are the newest photo. */
export function groupPlaces(assets: CatalogAsset[], places: CatalogPlace[]): CountryGroup[] {
	const byPlace = new Map<number, { count: number; cover: string | null }>();
	for (const a of assets) {
		if (a.pl == null) continue;
		const e = byPlace.get(a.pl) ?? { count: 0, cover: null };
		e.count++;
		e.cover = a.id; // assets are oldest first: the last one wins
		byPlace.set(a.pl, e);
	}
	const countries = new Map<string, CountryGroup>();
	for (const p of places) {
		const e = byPlace.get(p.id);
		if (!e) continue;
		const g = countries.get(p.cc) ?? { cc: p.cc, country: p.country, count: 0, cover: null, cities: [] };
		g.count += e.count;
		g.cities.push({ place: p, count: e.count, cover: e.cover });
		countries.set(p.cc, g);
	}
	const out = [...countries.values()];
	for (const g of out) {
		g.cities.sort((a, b) => b.count - a.count || a.place.name.localeCompare(b.place.name));
		g.cover = g.cities[0]?.cover ?? null;
	}
	return out.sort((a, b) => b.count - a.count || a.country.localeCompare(b.country));
}

/** Photos chosen by tapping a map pin (shown on /places/selection). */
export const mapPick = $state<{ ids: string[] }>({ ids: [] });
