// The browser pipeline (WebGPU, here via Dawn) must reproduce the server's Metal reference renders.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { create, globals } from 'webgpu';
import { EditRenderer } from './renderer';
import type { Recipe } from './recipe';

Object.assign(globalThis, globals);
const dir = new URL('../../../../shaders/fixtures/', import.meta.url);
const TOLERANCE = 1;

describe('edit pipeline parity with the server', async () => {
	const renderer = await EditRenderer.create(create([]) as unknown as GPU);
	const recipes = JSON.parse(readFileSync(new URL('recipes.json', dir), 'utf8')) as Record<string, Recipe>;
	const sizes = JSON.parse(readFileSync(new URL('golden/sizes.json', dir), 'utf8')) as Record<string, [number, number]>;

	it('has a GPU', () => expect(renderer).not.toBeNull());

	for (const [name, recipe] of Object.entries(recipes)) {
		it(name, async () => {
			renderer!.setSource({ data: new Uint8Array(readFileSync(new URL('fixture-96x64.rgba', dir))), width: 96, height: 64 });
			const out = await renderer!.renderPixels(recipe);
			expect([out.width, out.height]).toEqual(sizes[name]);
			const golden = new Uint8Array(readFileSync(new URL(`golden/${name}.rgba`, dir)));
			let max = 0;
			for (let i = 0; i < golden.length; i++) max = Math.max(max, Math.abs(golden[i] - out.data[i]));
			expect(max, `max channel difference for ${name}`).toBeLessThanOrEqual(TOLERANCE);
		});
	}

	// HDR rendition (gain-map photos): same fixture plus a gain map; see EditRenderTests.hdrRendersMatchGoldens.
	for (const name of ['identity', 'exposure', 'light', 'everything']) {
		it(`HDR ${name}`, async () => {
			renderer!.setSource({ data: new Uint8Array(readFileSync(new URL('fixture-96x64.rgba', dir))), width: 96, height: 64 });
			renderer!.setGainMap({ pixels: new Uint8Array(readFileSync(new URL('gain-96x64.r8', dir))), width: 96, height: 64, stops: 2 });
			const out = await renderer!.renderHDRPixels(recipes[name]);
			renderer!.setGainMap(null);
			const file = readFileSync(new URL(`golden/hdr-${name}.rgba16f`, dir));
			const golden = new Uint16Array(file.buffer, file.byteOffset, file.byteLength / 2);
			expect(out.data.length).toBe(golden.length);
			let max = 0;
			for (let i = 0; i < golden.length; i++) max = Math.max(max, Math.abs(half(golden[i]) - half(out.data[i])));
			expect(max, `max difference for HDR ${name}`).toBeLessThanOrEqual(0.01);
		});
	}
});

function half(h: number) {
	const e = (h >> 10) & 31;
	const m = h & 1023;
	const v = e === 0 ? (m / 1024) * 2 ** -14 : e === 31 ? (m ? NaN : Infinity) : (1 + m / 1024) * 2 ** (e - 15);
	return h >> 15 ? -v : v;
}
