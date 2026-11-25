// Crop / straighten / rotate / flip helpers. Crop rects are normalised to the rotated+flipped frame
// (the same convention as the shader): the frame is the source turned by `rotate` quarter turns.
import { frameSize, type Crop, type Recipe } from './recipe';

export const FULL: Crop = { x: 0, y: 0, w: 1, h: 1 };

/** True when every corner of `crop` lies on the image after straightening by `angle` degrees. */
export function cropInside(crop: Crop, angle: number, fw: number, fh: number, eps = 1e-6): boolean {
	const a = (angle * Math.PI) / 180;
	const c = Math.cos(a);
	const s = Math.sin(a);
	for (const [u, v] of [
		[crop.x, crop.y],
		[crop.x + crop.w, crop.y],
		[crop.x, crop.y + crop.h],
		[crop.x + crop.w, crop.y + crop.h]
	]) {
		// same inverse mapping as source_uv() in the shader
		const fx = (u - 0.5) * fw;
		const fy = (v - 0.5) * fh;
		const qx = (c * fx + s * fy) / fw + 0.5;
		const qy = (-s * fx + c * fy) / fh + 0.5;
		if (qx < -eps || qx > 1 + eps || qy < -eps || qy > 1 + eps) return false;
	}
	return true;
}

/** Shrinks `crop` about its centre (keeping its aspect) until it fits the straightened image. */
export function fitCrop(crop: Crop, angle: number, fw: number, fh: number): Crop {
	const scaled = (k: number): Crop => {
		const cx = crop.x + crop.w / 2;
		const cy = crop.y + crop.h / 2;
		const w = crop.w * k;
		const h = crop.h * k;
		return { x: cx - w / 2, y: cy - h / 2, w, h };
	};
	if (cropInside(crop, angle, fw, fh)) return crop;
	let lo = 0;
	let hi = 1;
	for (let i = 0; i < 40; i++) {
		const mid = (lo + hi) / 2;
		if (cropInside(scaled(mid), angle, fw, fh)) lo = mid;
		else hi = mid;
	}
	return clampToUnit(scaled(lo));
}

function clampToUnit(c: Crop): Crop {
	const w = Math.min(1, Math.max(0.01, c.w));
	const h = Math.min(1, Math.max(0.01, c.h));
	return { x: Math.min(1 - w, Math.max(0, c.x)), y: Math.min(1 - h, Math.max(0, c.y)), w, h };
}

/** The furthest point from `from` towards `to` (linear in all four values) that stays on the image. */
export function constrainCrop(from: Crop, to: Crop, angle: number, fw: number, fh: number): Crop {
	const lerp = (t: number): Crop => ({
		x: from.x + (to.x - from.x) * t,
		y: from.y + (to.y - from.y) * t,
		w: from.w + (to.w - from.w) * t,
		h: from.h + (to.h - from.h) * t
	});
	const target = clampToUnit(to);
	if (cropInside(target, angle, fw, fh)) return target;
	let lo = 0;
	let hi = 1;
	for (let i = 0; i < 30; i++) {
		const mid = (lo + hi) / 2;
		if (cropInside(clampToUnit(lerp(mid)), angle, fw, fh)) lo = mid;
		else hi = mid;
	}
	return clampToUnit(lerp(lo));
}

/** Rotates the whole edit a quarter turn clockwise (the crop turns with the image). */
export function rotateClockwise(r: Recipe): Recipe {
	const c = r.crop ?? FULL;
	// A point (x, y) in the old frame lands at (1 - y, x) in the new one.
	const crop = { x: 1 - (c.y + c.h), y: c.x, w: c.h, h: c.w };
	// Flips are defined in the rotated frame: turning swaps which axis they mirror.
	return { ...r, rotate: ((r.rotate ?? 0) + 1) % 4, crop, flipH: r.flipV, flipV: r.flipH };
}

/** A quarter turn counter-clockwise (three clockwise turns). */
export function rotateCounterClockwise(r: Recipe): Recipe {
	return rotateClockwise(rotateClockwise(rotateClockwise(r)));
}

export function flipHorizontal(r: Recipe): Recipe {
	const c = r.crop ?? FULL;
	return { ...r, flipH: !r.flipH, straighten: -(r.straighten ?? 0) || undefined, crop: { ...c, x: 1 - c.x - c.w } };
}

/** Largest crop with `aspect` (w/h, in pixels) centred on the current crop, fitted to the image. */
export function cropWithAspect(r: Recipe, aspect: number | null, srcW: number, srcH: number): Crop {
	const { w: fw, h: fh } = frameSize(r, srcW, srcH);
	const c = r.crop ?? FULL;
	if (aspect == null) return c;
	const cx = c.x + c.w / 2;
	const cy = c.y + c.h / 2;
	// normalised w/h for the pixel aspect
	let w = 1;
	let h = (fw / aspect) / fh;
	if (h > 1) {
		h = 1;
		w = (fh * aspect) / fw;
	}
	const x = Math.min(1 - w, Math.max(0, cx - w / 2));
	const y = Math.min(1 - h, Math.max(0, cy - h / 2));
	return fitCrop({ x, y, w, h }, r.straighten ?? 0, fw, fh);
}

export const ASPECTS: { label: string; value: number | null | 'original' }[] = [
	{ label: 'Freeform', value: null },
	{ label: 'Original', value: 'original' },
	{ label: 'Square', value: 1 },
	{ label: '4:3', value: 4 / 3 },
	{ label: '3:4', value: 3 / 4 },
	{ label: '16:9', value: 16 / 9 },
	{ label: '9:16', value: 9 / 16 },
	{ label: '3:2', value: 3 / 2 },
	{ label: '2:3', value: 2 / 3 }
];
