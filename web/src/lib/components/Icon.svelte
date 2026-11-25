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
		more: 'M5 12h.01 M12 12h.01 M19 12h.01',
		heart: 'M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z',
		people: 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M2 21v-1a6 6 0 0 1 6-6h2a6 6 0 0 1 6 6v1 M16 3.1a4 4 0 0 1 0 7.8 M22 21v-1a6 6 0 0 0-4-5.6',
		map: 'M9 4L3 6v14l6-2 6 2 6-2V4l-6 2z M9 4v14 M15 6v14',
		edit: 'M4 7h9 M17 7h3 M15 5v4 M4 17h3 M11 17h9 M9 15v4 M4 12h12 M19 10v4',
		share: 'M12 15V3 M8 7l4-4 4 4 M5 11v8a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-8',
		undo: 'M9 14L4 9l5-5 M4 9h10.5a5.5 5.5 0 0 1 0 11H11',
		redo: 'M15 14l5-5-5-5 M20 9H9.5a5.5 5.5 0 0 0 0 11H13',
		crop: 'M6 2v14a2 2 0 0 0 2 2h14 M2 6h14a2 2 0 0 1 2 2v14',
		rotate: 'M3 12a9 9 0 1 0 3-6.7 M3 3v6h6',
		flip: 'M12 3v18 M8 7L3 17h5z M16 7l5 10h-5z',
		wand: 'M15 4V2 M15 16v-2 M8 9h2 M20 9h2 M17.8 11.8L19 13 M17.8 6.2L19 5 M12.2 6.2L11 5 M3 21l9-9',
		aspect: 'M3 6h18v12H3z M7 10v4 M17 10v4',
		reset: 'M3 12a9 9 0 1 0 9-9 M3 4v5h5',
		compare: 'M12 3v18 M5 5h14v14H5z',
		exposure: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 3v18 M7 9h3 M8.5 7.5v3 M14 15h3',
		brilliance: 'M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z',
		highlights: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 3v18 M12 7h6 M12 11h8 M12 15h7',
		shadows: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 3v18 M6 7h6 M4 11h8 M5 15h7',
		brightness: 'M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M12 2v2 M12 20v2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M2 12h2 M20 12h2 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4',
		contrast: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 3a9 9 0 0 1 0 18z',
		blackPoint: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
		saturation: 'M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z',
		vibrance: 'M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z M9 14a3 3 0 0 0 3 3',
		warmth: 'M14 14.8V5a2 2 0 0 0-4 0v9.8a4 4 0 1 0 4 0z M12 10v6',
		tint: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M7 12a5 5 0 0 1 10 0',
		sharpen: 'M3 20L12 4l9 16z M12 10v6',
		vignette: 'M3 5h18v14H3z M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8z'
	};
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
	stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
	<path d={paths[name] ?? ''} />
</svg>
