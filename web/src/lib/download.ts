// Saving files from the app. In an iPhone/iPad Home Screen app a download (an <a download> link or
// a blob URL) replaces the whole app with iOS's file preview, which has no way back: the app has to
// be force-quit. Opening the URL in a new window doesn't help either (same-origin pages open inside
// the app). There, files go through the share sheet instead (Save Image/Video, Save to Files).

/** Running as an iOS Home Screen app (navigator.standalone exists only on iOS). */
export const iosStandalone =
	typeof navigator !== 'undefined' && (navigator as Navigator & { standalone?: boolean }).standalone === true;

/** Downloads a file held in memory. Never call it in an iOS Home Screen app (see above). */
export function saveBlob(f: File) {
	const a = document.createElement('a');
	a.href = URL.createObjectURL(f);
	a.download = f.name;
	document.body.appendChild(a);
	a.click();
	a.remove();
	setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
}

/** Downloads a URL (the server sends it as an attachment). Never in an iOS Home Screen app. */
export function downloadUrl(url: string, name = '') {
	const a = document.createElement('a');
	a.href = url;
	a.download = name;
	document.body.appendChild(a);
	a.click();
	a.remove();
}
