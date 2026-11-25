import { describe, expect, it } from 'vitest';
import { constrainCrop, cropInside, cropWithAspect, fitCrop, flipHorizontal, FULL, rotateClockwise } from './geometry';
import { normalize, outputSize, shaderParams, type Recipe } from './recipe';

describe('crop geometry', () => {
	it('detects crops that leave the straightened image', () => {
		expect(cropInside(FULL, 0, 400, 300)).toBe(true);
		expect(cropInside(FULL, 10, 400, 300)).toBe(false);
		expect(cropInside({ x: 0.3, y: 0.3, w: 0.4, h: 0.4 }, 10, 400, 300)).toBe(true);
	});

	it('shrinks about the centre to fit when straightening', () => {
		const c = fitCrop(FULL, 12, 400, 300);
		expect(cropInside(c, 12, 400, 300)).toBe(true);
		expect(c.w).toBeLessThan(1);
		expect(c.w / c.h).toBeCloseTo(1, 5); // aspect kept (normalised)
		expect(c.x + c.w / 2).toBeCloseTo(0.5, 5);
		// and the result is tight: a slightly larger crop no longer fits
		const bigger = { x: c.x - 0.005, y: c.y - 0.005, w: c.w + 0.01, h: c.h + 0.01 };
		expect(cropInside(bigger, 12, 400, 300)).toBe(false);
	});

	it('stops a drag at the image edge', () => {
		const from = { x: 0.2, y: 0.2, w: 0.5, h: 0.5 };
		const out = constrainCrop(from, { ...from, x: -0.3 }, 0, 400, 300);
		expect(out.x).toBeCloseTo(0, 5);
		expect(out.w).toBeCloseTo(0.5, 5);
	});

	it('four quarter turns are the identity; output size follows', () => {
		let r: Recipe = { schema: 1, crop: { x: 0.1, y: 0.2, w: 0.3, h: 0.4 }, flipH: true };
		const once = rotateClockwise(r);
		expect(once.rotate).toBe(1);
		expect(once.crop!.x).toBeCloseTo(0.4, 10);
		expect(once.crop!.y).toBeCloseTo(0.1, 10);
		expect([once.crop!.w, once.crop!.h]).toEqual([0.4, 0.3]);
		expect(once.flipV).toBe(true);
		expect(outputSize(once, 400, 300)).toEqual({ w: Math.round(0.4 * 300), h: Math.round(0.3 * 400) });
		for (let i = 0; i < 4; i++) r = rotateClockwise(r);
		expect(r.rotate).toBe(0);
		expect(r.crop!.x).toBeCloseTo(0.1, 10);
		expect(r.crop!.h).toBeCloseTo(0.4, 10);
	});

	it('flipping mirrors the crop and the straighten angle', () => {
		const r = flipHorizontal({ schema: 1, straighten: 5, crop: { x: 0.1, y: 0, w: 0.5, h: 1 } });
		expect(r.flipH).toBe(true);
		expect(r.straighten).toBe(-5);
		expect(r.crop!.x).toBeCloseTo(0.4, 10);
	});

	it('aspect presets produce the pixel aspect', () => {
		const c = cropWithAspect({ schema: 1 }, 1, 400, 300);
		expect((c.w * 400) / (c.h * 300)).toBeCloseTo(1, 5);
	});
});

describe('recipe', () => {
	it('normalizes defaults away and packs the uniform block like the server', () => {
		expect(normalize({ schema: 1, exposure: 0, rotate: 4, flipH: false, curve: [[0, 0], [1, 1]] })).toEqual({ schema: 1 });
		const v = shaderParams({ schema: 1, exposure: 1.5, curve: [[0, 0.1], [1, 0.9]], rotate: 1 }, 30, 40, 40, 30);
		expect([...v.slice(0, 4)]).toEqual([30, 40, 40, 30]);
		expect(v[9]).toBe(1); // rotate
		expect(v[12]).toBe(1.5); // exposure
		expect(v[25]).toBe(2); // curve count
		expect([...v.slice(28, 32)]).toEqual([0, 0, 256, 192]);
		expect(v[33]).toBeCloseTo(0.1, 6);
	});
});
