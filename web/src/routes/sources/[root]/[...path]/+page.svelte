<script lang="ts">
	// The folders of a library source on an rclone remote (pCloud…), like Library folders.
	import { page } from '$app/state';
	import FolderView from '#lib/components/FolderView.svelte';
	import { app } from '#lib/state.svelte.ts';
	import type { RootName } from '#lib/api.ts';

	const root = $derived((page.params.root ?? '') as RootName);
	const title = $derived(app.folders.find((f) => f.root === root && f.relPath === '')?.name || 'Source');
</script>

<FolderView {root} relPath={decodeURIComponent(page.params.path ?? '')} base={`/sources/${root}`} rootTitle={title} />
