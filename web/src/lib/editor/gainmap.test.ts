import { describe, expect, it } from 'vitest';
import { decodeGainMap } from './gainmap';

/** Builds the wire format the server sends (NormalizedGainMap.encoded()). */
async function encode(pixels: Uint8Array<ArrayBuffer>, width: number, height: number, stops: number) {
	const head = new ArrayBuffer(16);
	const v = new DataView(head);
	new Uint8Array(head).set(new TextEncoder().encode('GMP1'));
	v.setUint32(4, width, true);
	v.setUint32(8, height, true);
	v.setFloat32(12, stops, true);
	const body = await new Response(new Blob([pixels]).stream().pipeThrough(new CompressionStream('deflate-raw'))).arrayBuffer();
	const out = new Uint8Array(16 + body.byteLength);
	out.set(new Uint8Array(head));
	out.set(new Uint8Array(body), 16);
	return out.buffer;
}

describe('gain map wire format', () => {
	it('round-trips', async () => {
		const pixels = Uint8Array.from({ length: 12 }, (_, i) => i * 20);
		const map = await decodeGainMap(await encode(pixels, 4, 3, 2.5));
		expect(map).toEqual({ pixels, width: 4, height: 3, stops: 2.5 });
	});

	it('rejects other data', async () => {
		await expect(decodeGainMap(new ArrayBuffer(8))).rejects.toThrow();
		const bad = await encode(new Uint8Array(5), 4, 3, 1);
		await expect(decodeGainMap(bad)).rejects.toThrow('Damaged');
	});
});
