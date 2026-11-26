<script lang="ts">
	// The Folders page: a section per source. (/folders/<path> is the library folder's <path>, from
	// links made before the sources had pages of their own.)
	import { page } from '$app/state';
	import FolderView from '#lib/components/FolderView.svelte';
	import FoldersOverview from '#lib/components/FoldersOverview.svelte';
	import { LOCAL_FOLDERS } from '#lib/sources.ts';

	const path = $derived(decodeURIComponent(page.params.path ?? ''));
</script>

{#if path}
	<FolderView root="library" relPath={path} base="/sources/library" rootTitle={LOCAL_FOLDERS} />
{:else}
	<FoldersOverview />
{/if}
