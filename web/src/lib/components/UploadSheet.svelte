<script lang="ts">
	import { uploads, uploadUI } from '#lib/uploadsInstance.svelte.ts';
	import Icon from './Icon.svelte';

	const label: Record<string, string> = {
		queued: 'Waiting',
		hashing: 'Preparing…',
		checking: 'Checking…',
		uploading: 'Uploading',
		duplicate: 'Already in library',
		done: 'Uploaded',
		failed: 'Failed'
	};
	const failed = $derived(uploads.items.filter((i) => i.status === 'failed').length);
	const mb = (n: number) => `${(n / 1e6).toFixed(1)} MB`;
</script>

{#if uploadUI.open}
	<div class="sheet" role="dialog" aria-label="Uploads">
		<header>
			<strong>Uploads</strong>
			<span class="muted">{uploads.active ? `${uploads.active} remaining` : 'All done'}</span>
			<button class="icon-btn" onclick={() => (uploadUI.open = false)} aria-label="Close"><Icon name="close" size={18} /></button>
		</header>
		{#if uploads.active}
			<p class="note muted">Keep this app open until uploads finish. Unfinished uploads continue next time you open it.</p>
		{/if}
		<ul>
			{#each uploads.items.toReversed() as i (i.id)}
				<li class={i.status}>
					<div class="name">{i.name}</div>
					<div class="status muted">
						{label[i.status]}{i.status === 'uploading' ? ` ${Math.round(i.progress * 100)}%` : ''} · {mb(i.size)}
						{#if i.error}<span class="err">— {i.error}</span>{/if}
					</div>
					{#if i.status === 'uploading'}<div class="bar"><div style="width: {i.progress * 100}%"></div></div>{/if}
				</li>
			{/each}
		</ul>
		<footer>
			{#if failed}<button class="btn" onclick={() => uploads.retryFailed()}>Retry failed</button>{/if}
			<button class="btn" onclick={() => uploads.clearFinished()}>Clear finished</button>
		</footer>
	</div>
{/if}

<style>
	.sheet {
		position: fixed;
		z-index: 160;
		right: 12px;
		bottom: calc(var(--tabbar-h) + env(safe-area-inset-bottom) + 12px);
		width: min(380px, calc(100vw - 24px));
		max-height: 55dvh;
		display: flex;
		flex-direction: column;
		background: var(--bg);
		border-radius: 14px;
		box-shadow: 0 10px 40px rgba(0, 0, 0, 0.3);
		border: 0.5px solid var(--separator);
	}
	@media (min-width: 768px) {
		.sheet {
			bottom: 16px;
		}
	}
	header {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 10px 8px 6px 14px;
	}
	header .muted {
		flex: 1;
		font-size: 13px;
	}
	.note {
		font-size: 12px;
		margin: 0 14px 6px;
	}
	ul {
		list-style: none;
		margin: 0;
		padding: 0 14px;
		overflow: auto;
		flex: 1;
	}
	li {
		padding: 7px 0;
		border-bottom: 0.5px solid var(--separator);
		font-size: 13px;
	}
	.name {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
	.status {
		font-size: 12px;
	}
	li.done .status,
	li.duplicate .status {
		color: #34c759;
	}
	li.failed .status,
	.err {
		color: var(--danger);
	}
	.bar {
		height: 3px;
		background: var(--separator);
		border-radius: 2px;
		margin-top: 4px;
		overflow: hidden;
	}
	.bar div {
		height: 100%;
		background: var(--accent);
	}
	footer {
		display: flex;
		gap: 8px;
		justify-content: flex-end;
		padding: 8px 12px 12px;
	}
</style>
