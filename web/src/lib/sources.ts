// Where photos come from, as the app shows them: the library folder on the Mac, more folders on the
// Mac, Apple Photos libraries and folders on rclone remotes — each a "source" with its own folders.
import type { FolderNode, RootName } from './api.ts';

export type SourceKind = 'library' | 'folder' | 'photos' | 'remote';

export interface Source {
	root: RootName;
	kind: SourceKind;
	/** its top folder (relPath '') */
	folder: FolderNode;
	title: string;
}

export function kindOf(root: string): SourceKind | null {
	if (root === 'library') return 'library';
	if (root.startsWith('folder-')) return 'folder';
	if (root.startsWith('photos-')) return 'photos';
	if (root.startsWith('remote-')) return 'remote';
	return null;
}

export const kindIcon: Record<SourceKind, string> = { library: 'folder', folder: 'folder', photos: 'photos', remote: 'cloud' };
export const kindLabel: Record<SourceKind, string> = {
	library: 'Folder on this Mac',
	folder: 'Folder on this Mac',
	photos: 'Apple Photos library',
	remote: 'rclone folder'
};

const order: Record<SourceKind, number> = { library: 0, folder: 1, photos: 2, remote: 3 };

/** The sources, library folder first, then folders on the Mac, Photos libraries, rclone folders. */
export function sources(folders: FolderNode[]): Source[] {
	const out: Source[] = [];
	for (const f of folders) {
		if (f.relPath !== '') continue;
		const kind = kindOf(f.root);
		if (!kind) continue;
		out.push({ root: f.root, kind, folder: f, title: f.name || (kind === 'library' ? 'Library folder' : 'Source') });
	}
	return out.sort((a, b) => order[a.kind] - order[b.kind] || a.title.localeCompare(b.title));
}

/** A source's folders are shown flat (an Apple Photos library's folders are 0…F). */
export const isFlat = (s: { kind: SourceKind }) => s.kind === 'photos';

/** The page of a source's folder (/folders is the overview of all sources). */
export function folderHref(root: string, relPath: string) {
	const path = relPath ? '/' + relPath.split('/').map(encodeURIComponent).join('/') : '';
	return root === 'uploads' ? `/uploads${path}` : `/sources/${root}${path}`;
}
