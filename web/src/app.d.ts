// See https://svelte.dev/docs/kit/types#app.d.ts
declare global {
	/** Git commit (short), commit date (ISO) and uncommitted-changes flag of the web build. */
	const __APP_COMMIT__: string;
	const __APP_COMMIT_DATE__: string;
	const __APP_DIRTY__: boolean;

	namespace App {
		interface PageState {
			/** Asset id shown in the full-screen viewer (shallow routing, so Back closes it). */
			viewer?: string;
		}
	}
}

export {};
