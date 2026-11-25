import { describe, expect, it } from 'vitest';
import { codecLabel, contentRangeTotal, formatBytes, formatDuration, isStreamedMedia } from './video';
import { isCacheableImage } from './imageCache';

describe('formatDuration', () => {
	it('formats m:ss and h:mm:ss, flooring seconds', () => {
		expect(formatDuration(0.4)).toBe('0:00');
		expect(formatDuration(12.3)).toBe('0:12');
		expect(formatDuration(62)).toBe('1:02');
		expect(formatDuration(3723)).toBe('1:02:03');
	});
});

describe('isStreamedMedia', () => {
	it('matches video, motion and original, but not status or images', () => {
		expect(isStreamedMedia('/api/assets/ab/video')).toBe(true);
		expect(isStreamedMedia('/api/assets/ab/video/status')).toBe(false);
		expect(isStreamedMedia('/api/assets/ab/motion')).toBe(true);
		expect(isStreamedMedia('/api/assets/ab/original')).toBe(true);
		expect(isStreamedMedia('/api/thumb/ab')).toBe(false);
	});
	it('is never cacheable as an image', () => {
		for (const p of ['/api/assets/ab/video', '/api/assets/ab/motion', '/api/assets/ab/original']) expect(isCacheableImage(p)).toBe(false);
	});
});

describe('codecLabel', () => {
	it('names known codecs and upper-cases the rest', () => {
		expect(codecLabel('h264')).toBe('H.264');
		expect(codecLabel('hevc')).toBe('HEVC');
		expect(codecLabel('vp9')).toBe('VP9');
		expect(codecLabel('mjpeg')).toBe('MJPEG');
	});
});

describe('contentRangeTotal', () => {
	it('reads the total length of a range response', () => {
		expect(contentRangeTotal('bytes 0-0/12345')).toBe(12345);
		expect(contentRangeTotal('bytes 0-1/*')).toBeNull();
		expect(contentRangeTotal(null)).toBeNull();
	});
});

describe('formatBytes', () => {
	it('uses KB, MB and GB', () => {
		expect(formatBytes(840_000)).toBe('840 KB');
		expect(formatBytes(12_400_000)).toBe('12.4 MB');
		expect(formatBytes(240_000_000)).toBe('240 MB');
		expect(formatBytes(1_270_000_000)).toBe('1.27 GB');
	});
});
