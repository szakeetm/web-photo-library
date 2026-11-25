// See https://svelte.dev/docs/kit/types#app.d.ts
declare global {
	namespace App {
		interface PageState {
			/** Asset id shown in the full-screen viewer (shallow routing, so Back closes it). */
			viewer?: string;
		}
	}
}

export {};
