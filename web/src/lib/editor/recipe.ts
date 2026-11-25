// Edit recipe (schema 1) — mirrors server EditRecipe.swift. Hosts only copy these numbers into the
// shader's uniform block; the edit maths lives in shaders/edit.wgsl.

export const RECIPE_SCHEMA = 1;

export interface Crop {
	x: number;
	y: number;
	w: number;
	h: number;
}

export interface Recipe {
	schema: number;
	crop?: Crop;
	straighten?: number; // degrees, -45..45
	rotate?: number; // clockwise quarter turns 0..3
	flipH?: boolean;
	flipV?: boolean;
	exposure?: number; // EV -3..3
	brilliance?: number;
	highlights?: number;
	shadows?: number;
	brightness?: number;
	contrast?: number;
	blackPoint?: number;
	saturation?: number;
	vibrance?: number;
	warmth?: number;
	tint?: number;
	curve?: [number, number][];
	vignette?: number;
	sharpen?: number; // 0..1
}

export type Adjustment =
	| 'exposure'
	| 'brilliance'
	| 'highlights'
	| 'shadows'
	| 'brightness'
	| 'contrast'
	| 'blackPoint'
	| 'saturation'
	| 'vibrance'
	| 'warmth'
	| 'tint'
	| 'vignette'
	| 'sharpen';

export interface AdjustmentInfo {
	key: Adjustment;
	label: string;
	min: number;
	max: number;
	group: 'light' | 'color' | 'effects';
	icon: string;
}

export const ADJUSTMENTS: AdjustmentInfo[] = [
	{ key: 'exposure', label: 'Exposure', min: -3, max: 3, group: 'light', icon: 'exposure' },
	{ key: 'brilliance', label: 'Brilliance', min: -1, max: 1, group: 'light', icon: 'brilliance' },
	{ key: 'highlights', label: 'Highlights', min: -1, max: 1, group: 'light', icon: 'highlights' },
	{ key: 'shadows', label: 'Shadows', min: -1, max: 1, group: 'light', icon: 'shadows' },
	{ key: 'brightness', label: 'Brightness', min: -1, max: 1, group: 'light', icon: 'brightness' },
	{ key: 'contrast', label: 'Contrast', min: -1, max: 1, group: 'light', icon: 'contrast' },
	{ key: 'blackPoint', label: 'Black Point', min: -1, max: 1, group: 'light', icon: 'blackPoint' },
	{ key: 'saturation', label: 'Saturation', min: -1, max: 1, group: 'color', icon: 'saturation' },
	{ key: 'vibrance', label: 'Vibrance', min: -1, max: 1, group: 'color', icon: 'vibrance' },
	{ key: 'warmth', label: 'Warmth', min: -1, max: 1, group: 'color', icon: 'warmth' },
	{ key: 'tint', label: 'Tint', min: -1, max: 1, group: 'color', icon: 'tint' },
	{ key: 'sharpen', label: 'Sharpness', min: 0, max: 1, group: 'effects', icon: 'sharpen' },
	{ key: 'vignette', label: 'Vignette', min: -1, max: 1, group: 'effects', icon: 'vignette' }
];

export const emptyRecipe = (): Recipe => ({ schema: RECIPE_SCHEMA });

const FULL: Crop = { x: 0, y: 0, w: 1, h: 1 };

/** Drops default values so equal edits compare equal (same rules as the server). */
export function normalize(r: Recipe): Recipe {
	const out: Recipe = { schema: r.schema };
	for (const a of ADJUSTMENTS) {
		const v = r[a.key];
		if (v != null && v !== 0) out[a.key] = round(v);
	}
	if (r.straighten) out.straighten = round(r.straighten);
	if (r.rotate) out.rotate = ((r.rotate % 4) + 4) % 4 || undefined;
	if (!out.rotate) delete out.rotate;
	if (r.flipH) out.flipH = true;
	if (r.flipV) out.flipV = true;
	if (r.crop && !(r.crop.x === 0 && r.crop.y === 0 && r.crop.w === 1 && r.crop.h === 1)) {
		out.crop = { x: round(r.crop.x), y: round(r.crop.y), w: round(r.crop.w), h: round(r.crop.h) };
	}
	if (r.curve && r.curve.length >= 2 && !isIdentityCurve(r.curve)) out.curve = r.curve.map(([x, y]) => [round(x), round(y)]);
	return out;
}

const round = (v: number) => Math.round(v * 1e4) / 1e4;

export function isIdentityCurve(c: [number, number][]) {
	return c.length === 2 && c[0][0] === 0 && c[0][1] === 0 && c[1][0] === 1 && c[1][1] === 1;
}

export function isIdentity(r: Recipe) {
	return Object.keys(normalize(r)).length === 1;
}

export function sameRecipe(a: Recipe, b: Recipe) {
	return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
}

/** Size of the rotated/flipped frame that crop coordinates refer to. */
export function frameSize(r: Recipe, srcW: number, srcH: number) {
	const odd = ((r.rotate ?? 0) & 1) === 1;
	return odd ? { w: srcH, h: srcW } : { w: srcW, h: srcH };
}

export function outputSize(r: Recipe, srcW: number, srcH: number) {
	const f = frameSize(r, srcW, srcH);
	const c = r.crop ?? FULL;
	// Math.round matches Swift's .rounded() (half away from zero) for positive values.
	return { w: Math.max(1, Math.round(c.w * f.w)), h: Math.max(1, Math.round(c.h * f.h)) };
}

export function lumaSize(w: number, h: number) {
	if (w >= h) return { w: 256, h: Math.max(1, Math.round((256 * h) / w)) };
	return { w: Math.max(1, Math.round((256 * w) / h)), h: 256 };
}

/** The shader's 16 × vec4<f32> uniform block (layout in shaders/edit.wgsl). */
export function shaderParams(r: Recipe, outW: number, outH: number, srcW: number, srcH: number, blur: [number, number] = [0, 0]) {
	const v = new Float32Array(64);
	const set = (i: number, a: number, b: number, c: number, d: number) => v.set([a, b, c, d], i * 4);
	const c = r.crop ?? FULL;
	const luma = lumaSize(srcW, srcH);
	const pts = r.curve && r.curve.length >= 2 ? r.curve.slice(0, 16) : [];
	set(0, outW, outH, srcW, srcH);
	set(1, c.x, c.y, c.w, c.h);
	set(2, r.straighten ?? 0, r.rotate ?? 0, r.flipH ? 1 : 0, r.flipV ? 1 : 0);
	set(3, r.exposure ?? 0, r.brilliance ?? 0, r.highlights ?? 0, r.shadows ?? 0);
	set(4, r.brightness ?? 0, r.contrast ?? 0, r.blackPoint ?? 0, r.saturation ?? 0);
	set(5, r.vibrance ?? 0, r.warmth ?? 0, r.tint ?? 0, r.vignette ?? 0);
	set(6, r.sharpen ?? 0, pts.length, 0, 0);
	set(7, blur[0], blur[1], luma.w, luma.h);
	pts.forEach(([x, y], i) => v.set([x, y], 32 + i * 2));
	return v;
}
