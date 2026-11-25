import { describe, expect, it, vi } from 'vitest';
import { thumbUrl, previewUrl, originalUrl, api } from './api';

describe('api urls', () => {
	it('builds thumbnail urls with edit version and format', () => {
		expect(thumbUrl('abc', 0, 'heic')).toBe('/api/thumb/abc?e=0&fmt=heic&r=2');
		expect(previewUrl('abc', 3, 'jpeg')).toBe('/api/preview/abc?e=3&fmt=jpeg&r=2');
		expect(originalUrl('abc')).toBe('/api/assets/abc/original');
	});
});

describe('video urls', () => {
	it('builds video, status and motion urls', async () => {
		const { videoUrl, videoStatusUrl, motionUrl, CLIENT_API_VERSION, CATALOG_FORMAT } = await import('./api');
		expect(videoUrl('ab')).toBe('/api/assets/ab/video');
		expect(videoStatusUrl('ab')).toBe('/api/assets/ab/video/status');
		expect(motionUrl('ab')).toBe('/api/assets/ab/motion');
		expect(CLIENT_API_VERSION).toBe(5);
		expect(CATALOG_FORMAT).toBe(5);
	});
});

describe('api.videoStatus', () => {
	it('unwraps the server\'s {status} body', async () => {
		vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ status: { state: 'converting', progress: 0.4 } }), { status: 200 })));
		const s = await api.videoStatus('ab');
		vi.unstubAllGlobals();
		expect(s.state).toBe('converting');
		expect(s.progress).toBe(0.4);
	});
});
