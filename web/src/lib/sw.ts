// Service worker registration and the "Update now" flow.
let registration: ServiceWorkerRegistration | undefined;

export async function registerServiceWorker() {
	if (!('serviceWorker' in navigator) || import.meta.env.DEV) return;
	try {
		registration = await navigator.serviceWorker.register('/service-worker.js', { updateViaCache: 'none' });
	} catch {
		/* not supported here (e.g. private window): online only */
	}
}

function installed(worker: ServiceWorker) {
	return new Promise<void>((resolve) => {
		if (worker.state === 'installed' || worker.state === 'activated') return resolve();
		worker.addEventListener('statechange', () => {
			if (worker.state === 'installed' || worker.state === 'activated' || worker.state === 'redundant') resolve();
		});
	});
}

/** Fetches the server's current build into the service worker, activates it, and reloads. */
export async function applyUpdate() {
	const reg = registration ?? (await navigator.serviceWorker?.getRegistration());
	if (reg) {
		try {
			await reg.update();
			const worker = reg.waiting ?? reg.installing;
			if (worker) {
				await Promise.race([installed(worker), new Promise((r) => setTimeout(r, 15000))]);
				const changed = new Promise((r) => navigator.serviceWorker.addEventListener('controllerchange', r, { once: true }));
				(reg.waiting ?? worker).postMessage('skipWaiting');
				await Promise.race([changed, new Promise((r) => setTimeout(r, 3000))]);
			}
		} catch {
			/* offline: the reload below still gets whatever is reachable */
		}
	}
	location.reload();
}
