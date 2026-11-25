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
});
