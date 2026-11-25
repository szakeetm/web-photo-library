// HDR gain maps for the editor. Browsers hand WebGPU only the SDR pixels of a gain-map photo, so the
// server sends the gain map separately (GET /api/gainmap/:id, NormalizedGainMap.swift): one byte per
// pixel, same framing as the preview, 255 = `stops` stops brighter than the SDR value.
import { gainMapUrl } from '#lib/api.ts';

export interface GainMap {
	pixels: Uint8Array;
	width: number;
	height: number;
	stops: number;
}

/** "GMP1", width, height (u32 LE), stops (f32 LE), then the pixels as raw DEFLATE. */
export async function decodeGainMap(buf: ArrayBuffer): Promise<GainMap> {
	const v = new DataView(buf);
	if (buf.byteLength < 16 || new TextDecoder().decode(new Uint8Array(buf, 0, 4)) !== 'GMP1') throw new Error('Not a gain map.');
	const width = v.getUint32(4, true);
	const height = v.getUint32(8, true);
	const stops = v.getFloat32(12, true);
	const stream = new Blob([new Uint8Array(buf, 16)]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
	const pixels = new Uint8Array(await new Response(stream).arrayBuffer());
	if (pixels.length !== width * height) throw new Error('Damaged gain map.');
	return { pixels, width, height, stops };
}

/** The photo's gain map, or null for an SDR photo (or when it can't be loaded: the editor then edits in SDR). */
export async function fetchGainMap(id: string): Promise<GainMap | null> {
	try {
		const res = await fetch(gainMapUrl(id));
		if (res.status !== 200) return null;
		return await decodeGainMap(await res.arrayBuffer());
	} catch {
		return null;
	}
}
