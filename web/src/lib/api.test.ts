import { describe, expect, it } from 'vitest';
import { thumbUrl, previewUrl, originalUrl } from './api';

describe('api urls', () => {
	it('builds thumbnail urls with edit version and format', () => {
		expect(thumbUrl('abc', 0, 'heic')).toBe('/api/thumb/abc?e=0&fmt=heic&r=2');
		expect(previewUrl('abc', 3, 'jpeg')).toBe('/api/preview/abc?e=3&fmt=jpeg&r=2');
		expect(originalUrl('abc')).toBe('/api/assets/abc/original');
	});
});
