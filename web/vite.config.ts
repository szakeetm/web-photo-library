import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';
import { execSync } from 'node:child_process';

/** Git info of the checkout being built, shown in Settings → About. */
function git(args: string) {
	try {
		return execSync(`git ${args}`, { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
	} catch {
		return '';
	}
}

export default defineConfig({
	define: {
		__APP_COMMIT__: JSON.stringify(git('rev-parse --short HEAD')),
		__APP_COMMIT_DATE__: JSON.stringify(git('log -1 --format=%cI')),
		__APP_DIRTY__: JSON.stringify(git('status --porcelain --untracked-files=no -- .') !== '')
	},
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
