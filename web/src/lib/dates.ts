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

/** Local wall-clock time as a sortable number (ms). */
export const localTime = (a: Pick<CatalogAsset, 't' | 'tz'>) => Date.parse(a.t) + (a.tz ?? 0) * 1000;

/** Oldest first by the time shown to the user (local time where each photo was taken). */
export function sortByLocalTime<T extends Pick<CatalogAsset, 't' | 'tz' | 'id'>>(assets: T[]): T[] {
	return assets.slice().sort((x, y) => localTime(x) - localTime(y) || (x.id < y.id ? -1 : 1));
}

/** Groups by local month in first-seen order; one group per month even if input isn't sorted. */
export function groupByMonth<T extends Pick<CatalogAsset, 't' | 'tz'>>(assets: T[]): MonthGroup<T>[] {
	const groups = new Map<string, MonthGroup<T>>();
	for (const a of assets) {
		const key = monthKey(a);
		let g = groups.get(key);
		if (!g) groups.set(key, (g = { key, items: [] }));
		g.items.push(a);
	}
	return [...groups.values()];
}

export function monthLabel(key: string, locale?: string): string {
	const [y, m] = key.split('-').map(Number);
	return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString(locale, { month: 'long', year: 'numeric', timeZone: 'UTC' });
}

/** e.g. "Sunday, 4 July 2021 at 15:30" in the capture's local time. */
export function captureLabel(t: string, tz: number | null): string {
	// ISO style everywhere in the app: 2026-02-15 14:32 (24-hour), local time where it was taken
	return isoLabel(t, tz);
}

/** "2026-02-15 14:32" in this device's time zone: when something happened (a scan, a backup, an edit). */
export function isoDateTime(d: Date | string | number): string {
	const x = new Date(d);
	const p = (n: number) => String(n).padStart(2, '0');
	return `${x.getFullYear()}-${p(x.getMonth() + 1)}-${p(x.getDate())} ${p(x.getHours())}:${p(x.getMinutes())}`;
}

/** "2026-02-15 14:32": the local date and time where the photo was taken. */
export function isoLabel(t: string, tz: number | null): string {
	const d = new Date(Date.parse(t) + (tz ?? 0) * 1000);
	return d.toISOString().slice(0, 16).replace('T', ' ');
}

/** "2026-02-15 14:32:07": like isoLabel, with seconds (comparing copies of a photo). */
export function isoLabelSeconds(t: string, tz: number | null): string {
	const d = new Date(Date.parse(t) + (tz ?? 0) * 1000);
	return d.toISOString().slice(0, 19).replace('T', ' ');
}

export function offsetLabel(tz: number | null): string {
	if (tz == null) return '';
	const sign = tz < 0 ? '−' : '+';
	const abs = Math.abs(tz);
	const h = Math.floor(abs / 3600);
	const m = Math.floor((abs % 3600) / 60);
	return `UTC${sign}${h}${m ? ':' + String(m).padStart(2, '0') : ''}`;
}

/** "YYYY-MM-DDTHH:mm" in the photo's local time (for date/time inputs). */
export function localInput(t: string, tz: number | null): string {
	const p = localParts(t, tz);
	const pad = (n: number) => String(n).padStart(2, '0');
	return `${p.year}-${pad(p.month)}-${pad(p.day)}T${pad(p.hour)}:${pad(p.minute)}`;
}

/** The instant (ms) of a wall-clock "YYYY-MM-DDTHH:mm[:ss]" at offset `tz` (seconds east of UTC). */
export function instantOf(local: string, tz: number): number {
	return Date.parse(local.length === 16 ? `${local}:00Z` : `${local}Z`) - tz * 1000;
}

export interface DateEdit {
	/** wall clock "YYYY-MM-DDTHH:mm" chosen for the first (earliest) photo, or for all of them */
	local: string;
	/** time zone the wall clock is in (seconds east of UTC) */
	tz: number;
	/** shift every photo by the same amount (keeps their spacing), or set them all to the same time */
	mode: 'shift' | 'same';
}

/** The server change that makes the earliest photo show `edit.local` in `edit.tz`. */
export function dateChangeFor(assets: Pick<CatalogAsset, 't' | 'tz'>[], edit: DateEdit) {
	const target = instantOf(edit.local, edit.tz);
	const tzChanged = assets.some((a) => a.tz !== edit.tz);
	if (edit.mode === 'same') return { shift: 0, setTo: new Date(target).toISOString().replace('.000Z', 'Z'), tzOffset: edit.tz };
	const earliest = Math.min(...assets.map((a) => Date.parse(a.t)));
	return { shift: (target - earliest) / 1000, tzOffset: tzChanged ? edit.tz : null, keepWallClock: false };
}

/** Time zones offered when adjusting a date: UTC−12 … UTC+14 (quarter hours where used). */
export const TZ_OFFSETS: number[] = [
	-12, -11, -10, -9.5, -9, -8, -7, -6, -5, -4, -3.5, -3, -2, -1, 0, 1, 2, 3, 3.5, 4, 4.5, 5, 5.5, 5.75, 6, 6.5, 7, 8,
	8.75, 9, 9.5, 10, 10.5, 11, 12, 12.75, 13, 14
].map((h) => Math.round(h * 3600));

/** e.g. "+1 h 20 min", "−3 days 2 h" (for showing a shift). */
export function shiftLabel(seconds: number): string {
	if (Math.abs(seconds) < 60) return 'no change';
	const sign = seconds < 0 ? '−' : '+';
	let s = Math.round(Math.abs(seconds) / 60);
	const days = Math.floor(s / 1440);
	s -= days * 1440;
	const h = Math.floor(s / 60);
	const m = s % 60;
	const parts = [days ? `${days} day${days === 1 ? '' : 's'}` : '', h ? `${h} h` : '', m ? `${m} min` : ''].filter(Boolean);
	return sign + parts.join(' ');
}
