import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			// Single-page app served by the Swift server; unknown paths fall back to index.html.
			adapter: adapter({ fallback: 'index.html' }),
			// Check for a newer web build every 5 minutes (also on focus / visibility change).
			version: { pollInterval: 5 * 60 * 1000 }
		})
	],
	server: {
		proxy: { '/api': 'http://127.0.0.1:8787' }
	},
	test: {
		include: ['src/**/*.test.ts']
	}
});
