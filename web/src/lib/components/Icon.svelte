<script lang="ts">
	// Small inline SVG icon set (SF Symbols–like strokes).
	let { name, size = 22 }: { name: string; size?: number } = $props();
	const paths: Record<string, string> = {
		photos: 'M4 5h16v14H4z M4 15l4.5-4.5 3.5 3.5 2.5-2.5L20 17 M15.5 8.5a1.5 1.5 0 1 0 0 .01',
		folder: 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
		settings:
			'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
		close: 'M6 6l12 12 M18 6L6 18',
		back: 'M15 5l-7 7 7 7',
		chevron: 'M9 5l7 7-7 7',
		info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 11v5 M12 7.5v.01',
		download: 'M12 4v11 M7 10l5 5 5-5 M5 20h14',
		left: 'M15 5l-7 7 7 7',
		right: 'M9 5l7 7-7 7',
		up: 'M12 19V5 M5 12l7-7 7 7',
		albumAdd: 'M4 7h12v12H4z M8 3h12v12 M10 10v6 M7 13h6',
		minus: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M8 12h8',
		search: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13z M20 20l-4.6-4.6',
		albums: 'M4 4h7v7H4z M13 4h7v7h-7z M4 13h7v7H4z M13 13h7v7h-7z',
		upload: 'M12 20V8 M7 13l5-5 5 5 M5 4h14',
		select: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M8 12l3 3 5-6',
		heart: 'M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z'
	};
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
	stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
	<path d={paths[name] ?? ''} />
</svg>
