// Names the face groups found in the demo library (people.json: name → file names). Run via take-screenshots.sh.
import { readFileSync } from 'node:fs';
const BASE = process.argv[2];
const byFile = new Map(Object.entries(JSON.parse(readFileSync(new URL('people.json', import.meta.url)))).flatMap(([n, fs]) => fs.map((f) => [f, n])));
const get = async (p) => (await fetch(BASE + p)).json();
for (const person of await get('/api/people')) {
	const votes = new Map();
	for (const f of await get(`/api/people/${person.id}/faces`)) {
		const file = (await get(`/api/assets/${f.assetId}`)).files[0]?.split('/').pop();
		const n = byFile.get(file);
		if (n) votes.set(n, (votes.get(n) ?? 0) + 1);
	}
	const name = [...votes].sort((a, b) => b[1] - a[1])[0]?.[0];
	if (name) {
		await fetch(`${BASE}/api/people/${person.id}`, { method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name }) });
		console.log(`person ${person.id} → ${name}`);
	}
}
