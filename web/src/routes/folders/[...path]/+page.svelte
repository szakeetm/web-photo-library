<script lang="ts">
	import { page } from '$app/state';
	import FolderView from '#lib/components/FolderView.svelte';
</script>

<FolderView root="library" relPath={decodeURIComponent(page.params.path ?? '')} base="/folders" rootTitle="Folders" />
