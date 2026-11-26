// Reveal in Finder (local mode only: the server opens the Finder on its own Mac).
import { api } from './api';

export async function reveal(what: Parameters<typeof api.reveal>[0]) {
	try {
		await api.reveal(what);
	} catch (e) {
		alert((e as Error).message);
	}
}
