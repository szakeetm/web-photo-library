<script lang="ts">
	import type { Snippet } from 'svelte';
	import Icon from './Icon.svelte';
	import FilterMenu from './FilterMenu.svelte';
	import { gridView } from '#lib/gridView.svelte.ts';

	let { title, subtitle, back, crumbs, actions }: {
		title: string;
		subtitle?: string;
		back?: string;
		crumbs?: Snippet;
		actions?: Snippet;
	} = $props();
</script>

<header class="titlebar">
	{#if back}<a class="back" href={back} aria-label="Back"><Icon name="back" size={20} /></a>{/if}
	<div class="titles">
		{#if crumbs}<nav class="crumbs muted">{@render crumbs()}</nav>{/if}
		<h1><span class="t">{title}</span> {#if subtitle}<span class="sub muted">{subtitle}</span>{/if}</h1>
	</div>
	{#if actions || gridView.enabled}
		<div class="actions">
			{#if gridView.enabled}<FilterMenu />{/if}
			{#if actions}{@render actions()}{/if}
		</div>
	{/if}
</header>

<style>
	.titlebar {
		position: sticky;
		top: 0;
		z-index: 10;
		display: flex;
		align-items: center;
		gap: 6px;
		padding: calc(env(safe-area-inset-top) + 8px) 12px 8px 14px;
		background: var(--bg-bar);
		backdrop-filter: saturate(180%) blur(20px);
		-webkit-backdrop-filter: saturate(180%) blur(20px);
		min-height: 52px;
	}
	.back {
		display: flex;
		padding: 4px;
	}
	.titles {
		min-width: 0;
		flex: 1;
	}
	.crumbs {
		font-size: 12px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.crumbs :global(a) {
		color: inherit;
	}
	h1 {
		margin: 0;
		font-size: 24px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.sub {
		font-size: 14px;
		font-weight: 400;
		margin-left: 4px;
	}
	/* Phones: the subtitle (count, download status) gets its own line instead of being cut off. */
	@media (max-width: 600px) {
		h1 .t,
		h1 .sub {
			display: block;
			overflow: hidden;
			text-overflow: ellipsis;
		}
		h1 .sub {
			margin: 1px 0 0;
			font-size: 13px;
			line-height: 1.2;
		}
	}
	.actions {
		display: flex;
		gap: 4px;
		align-items: center;
	}
	.actions :global(.btn) {
		padding: 5px 12px;
		font-size: 14px;
	}
</style>
