import type { CatalogAsset } from './api';

export interface LocalParts {
	year: number;
	month: number; // 1-12
	day: number;
	hour: number;
	minute: number;
}

/** Wall-clock time where the photo was taken (capture offset applied; null offset = UTC). */
export function localParts(t: string, tz: number | null): LocalParts {
	const d = new Date(Date.parse(t) + (tz ?? 0) * 1000);
	return {
		year: d.getUTCFullYear(),
		month: d.getUTCMonth() + 1,
		day: d.getUTCDate(),
		hour: d.getUTCHours(),
		minute: d.getUTCMinutes()
	};
}

export function monthKey(a: Pick<CatalogAsset, 't' | 'tz'>): string {
	const p = localParts(a.t, a.tz);
	return `${p.year}-${String(p.month).padStart(2, '0')}`;
}

export interface MonthGroup<T> {
	key: string; // YYYY-MM
	items: T[];
}

/** Consecutive runs of the same local month, preserving input order. */
export function groupByMonth<T extends Pick<CatalogAsset, 't' | 'tz'>>(assets: T[]): MonthGroup<T>[] {
	const groups: MonthGroup<T>[] = [];
	for (const a of assets) {
		const key = monthKey(a);
		const last = groups[groups.length - 1];
		if (last && last.key === key) last.items.push(a);
		else groups.push({ key, items: [a] });
	}
	return groups;
}

export function monthLabel(key: string, locale?: string): string {
	const [y, m] = key.split('-').map(Number);
	return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString(locale, { month: 'long', year: 'numeric', timeZone: 'UTC' });
}

/** e.g. "Sunday, 4 July 2021 at 15:30" in the capture's local time. */
export function captureLabel(t: string, tz: number | null, locale?: string): string {
	const d = new Date(Date.parse(t) + (tz ?? 0) * 1000);
	return d.toLocaleString(locale, {
		weekday: 'long',
		day: 'numeric',
		month: 'long',
		year: 'numeric',
		hour: '2-digit',
		minute: '2-digit',
		timeZone: 'UTC'
	});
}

export function offsetLabel(tz: number | null): string {
	if (tz == null) return '';
	const sign = tz < 0 ? '−' : '+';
	const abs = Math.abs(tz);
	const h = Math.floor(abs / 3600);
	const m = Math.floor((abs % 3600) / 60);
	return `UTC${sign}${h}${m ? ':' + String(m).padStart(2, '0') : ''}`;
}
