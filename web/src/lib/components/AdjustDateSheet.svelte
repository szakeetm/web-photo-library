<script lang="ts">
	// Adjust Date & Time for one photo or a selection. The change is kept on the server only (the
	// library's files are never touched); exports with edits write it into the copies. With several
	// photos the earliest one gets the chosen time and the others move by the same amount (keeping
	// their spacing), or all of them get exactly that time.
	import { app, changeDates, revertDates } from '#lib/state.svelte.ts';
	import { captureLabel, dateChangeFor, instantOf, localInput, offsetLabel, shiftLabel, TZ_OFFSETS, type DateEdit } from '#lib/dates.ts';
	import Icon from './Icon.svelte';

	let { ids, onClose }: { ids: string[]; onClose: () => void } = $props();

	const assets = $derived(ids.map((i) => app.byId.get(i)).filter((a) => a != null));
	// svelte-ignore state_referenced_locally
	const first = assets.reduce((m, a) => (Date.parse(a.t) < Date.parse(m.t) ? a : m), assets[0]);
	const startTz = first?.tz ?? -new Date().getTimezoneOffset() * 60;

	let date = $state(first ? localInput(first.t, startTz).slice(0, 10) : '');
	let time = $state(first ? localInput(first.t, startTz).slice(11) : '');
	let tz = $state(startTz);
	let mode = $state<DateEdit['mode']>('shift');
	let busy = $state(false);
	let error = $state('');

	const many = $derived(assets.length > 1);
	const adjusted = $derived(assets.filter((a) => a.md).length);
	const valid = $derived(/^\d{4}-\d{2}-\d{2}$/.test(date) && /^\d{2}:\d{2}$/.test(time));
	const edit = $derived<DateEdit>({ local: `${date}T${time}`, tz, mode });
	const shift = $derived(valid && first ? (instantOf(edit.local, tz) - Date.parse(first.t)) / 1000 : 0);
	const offsets = $derived(TZ_OFFSETS.includes(startTz) ? TZ_OFFSETS : [...TZ_OFFSETS, startTz].sort((a, b) => a - b));

	async function run(work: () => Promise<void>) {
		busy = true;
		error = '';
		try {
			await work();
			onClose();
		} catch (e) {
			error = (e as Error).message;
		} finally {
			busy = false;
		}
	}

	const save = () => run(() => changeDates(ids, dateChangeFor(assets, edit)));
	const revert = () => run(() => revertDates(ids.filter((i) => app.byId.get(i)?.md)));
</script>

<div class="backdrop" role="presentation" onclick={onClose}></div>
<div class="sheet" role="dialog" aria-modal="true" aria-label="Adjust date and time">
	<header>
		<h2>Adjust Date & Time</h2>
		<button class="icon-btn" onclick={onClose} aria-label="Close"><Icon name="close" /></button>
	</header>
	<div class="body">
		{#if first}
			<p class="muted current">
				{many ? `${assets.length} photos, from` : 'Now'}
				{captureLabel(first.t, first.tz)}
				{offsetLabel(first.tz)}
			</p>
		{/if}
		<div class="fields">
			<label>Date <input type="date" bind:value={date} required /></label>
			<label>Time <input type="time" bind:value={time} required /></label>
			<label class="tz"
				>Time zone
				<select bind:value={tz}>
					{#each offsets as o (o)}
						<option value={o}>{offsetLabel(o).replace('UTC+0', 'UTC')}</option>
					{/each}
				</select>
			</label>
		</div>
		{#if many}
			<fieldset>
				<label><input type="radio" bind:group={mode} value="shift" /> Shift all by the same amount
					<span class="muted">(the first photo gets this time; spacing kept)</span></label>
				<label><input type="radio" bind:group={mode} value="same" /> Set all to this time</label>
			</fieldset>
		{/if}
		{#if valid && mode === 'shift'}
			<p class="muted">
				{Math.abs(shift) < 60 ? 'Same time' : `${many ? 'All photos move' : 'Moves'} ${shiftLabel(shift)}`}{tz !== startTz
					? ` · time zone ${offsetLabel(tz)}`
					: ''}
			</p>
		{/if}
		<p class="muted note">The original files aren't changed. Exports with edits carry the new date.</p>
		{#if error}<p class="error">{error}</p>{/if}
	</div>
	<footer>
		{#if adjusted}
			<button class="btn" disabled={busy} onclick={revert}
				>Revert to Original{many ? ` (${adjusted})` : ''}</button
			>
		{/if}
		<span class="spacer"></span>
		<button class="btn" onclick={onClose}>Cancel</button>
		<button class="btn primary" disabled={busy || !valid} onclick={save}>Adjust</button>
	</footer>
</div>

<style>
	.backdrop {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.35);
		z-index: 150;
	}
	.sheet {
		position: fixed;
		z-index: 151;
		left: 50%;
		bottom: 0;
		transform: translateX(-50%);
		width: min(480px, 100vw);
		max-height: 85dvh;
		display: flex;
		flex-direction: column;
		background: var(--bg);
		border-radius: 14px 14px 0 0;
		padding-bottom: env(safe-area-inset-bottom);
		box-shadow: 0 -10px 40px rgba(0, 0, 0, 0.3);
	}
	@media (min-width: 768px) {
		.sheet {
			bottom: auto;
			top: 50%;
			transform: translate(-50%, -50%);
			border-radius: 14px;
		}
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 12px 12px 6px 18px;
	}
	h2 {
		font-size: 17px;
		margin: 0;
	}
	.body {
		padding: 0 18px;
		overflow: auto;
	}
	.current {
		margin: 0 0 12px;
	}
	.fields {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 10px;
	}
	.fields label {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: 13px;
		color: var(--text-secondary, inherit);
	}
	.tz {
		grid-column: 1 / -1;
	}
	input[type='date'],
	input[type='time'],
	select {
		border: 0.5px solid var(--separator);
		background: var(--bg-elevated);
		border-radius: 8px;
		padding: 8px 10px;
		/* 16px: iOS doesn't zoom into the field */
		font: inherit;
		font-size: 16px;
		color: inherit;
		min-height: 40px;
	}
	fieldset {
		border: none;
		padding: 0;
		margin: 14px 0 0;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}
	fieldset .muted {
		font-size: 12px;
	}
	.note {
		font-size: 12px;
	}
	.error {
		color: var(--danger);
	}
	footer {
		display: flex;
		gap: 8px;
		padding: 12px 18px 14px;
	}
	.spacer {
		flex: 1;
	}
</style>
