<script lang="ts">
	import { page } from '$app/state';
	import FolderView from '#lib/components/FolderView.svelte';
</script>

<FolderView root="uploads" relPath={decodeURIComponent(page.params.path ?? '')} base="/uploads" rootTitle="Uploads" />
