<script lang="ts">
	// The Folders page: a section per source. (/folders/<path> is the library folder's <path>, from
	// links made before the sources had pages of their own.)
	import { page } from '$app/state';
	import FolderView from '#lib/components/FolderView.svelte';
	import FoldersOverview from '#lib/components/FoldersOverview.svelte';
	import { app } from '#lib/state.svelte.ts';

	const path = $derived(decodeURIComponent(page.params.path ?? ''));
	const title = $derived(app.folders.find((f) => f.root === 'library' && f.relPath === '')?.name || 'Library folder');
</script>

{#if path}
	<FolderView root="library" relPath={path} base="/sources/library" rootTitle={title} />
{:else}
	<FoldersOverview />
{/if}
