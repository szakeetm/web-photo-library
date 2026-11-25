import { describe, expect, it } from 'vitest';
import { formatDuration, isStreamedMedia } from './video';
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
