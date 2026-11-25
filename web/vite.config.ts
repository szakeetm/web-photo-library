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
			// WEB_OUT lets a test build go elsewhere than the folder the running server serves.
			adapter: adapter({ fallback: 'index.html', pages: process.env.WEB_OUT ?? 'build', assets: process.env.WEB_OUT ?? 'build' }),
			// Check for a newer web build every 5 minutes (also on focus / visibility change).
			version: { pollInterval: 5 * 60 * 1000 },
			// Registered by the app (src/lib/sw.ts) so "Update now" can activate a waiting worker.
			serviceWorker: { register: false }
		})
	],
	server: {
		proxy: { '/api': 'http://127.0.0.1:8787' },
		// The edit shaders live in ../shaders (shared with the server).
		fs: { allow: ['..'] }
	},
	test: {
		include: ['src/**/*.test.ts']
	}
});
