// One editing session: the current recipe with undo/redo. A slider drag is one undo step:
// `preview()` while dragging, `commit()` when the gesture ends.
import { emptyRecipe, normalize, sameRecipe, type Recipe } from './recipe';

export class EditorSession {
	recipe = $state.raw<Recipe>(emptyRecipe());
	/** The recipe the photo had when the editor opened. */
	saved = $state.raw<Recipe>(emptyRecipe());
	private undoStack = $state.raw<Recipe[]>([]);
	private redoStack = $state.raw<Recipe[]>([]);
	private gestureStart: Recipe | null = null;

	canUndo = $derived(this.undoStack.length > 0);
	canRedo = $derived(this.redoStack.length > 0);
	dirty = $derived(!sameRecipe(this.recipe, this.saved));

	reset(saved: Recipe) {
		this.saved = saved;
		this.recipe = saved;
		this.undoStack = [];
		this.redoStack = [];
		this.gestureStart = null;
	}

	/** Live change during a gesture. */
	preview(next: Recipe) {
		this.gestureStart ??= this.recipe;
		this.recipe = next;
	}

	/** Ends a gesture: one undo step if anything changed. */
	commit() {
		const start = this.gestureStart;
		this.gestureStart = null;
		if (start && !sameRecipe(start, this.recipe)) {
			this.undoStack = [...this.undoStack, start];
			this.redoStack = [];
		}
	}

	set(next: Recipe) {
		this.preview(next);
		this.commit();
	}

	undo() {
		this.commit();
		const prev = this.undoStack.at(-1);
		if (!prev) return;
		this.undoStack = this.undoStack.slice(0, -1);
		this.redoStack = [...this.redoStack, this.recipe];
		this.recipe = prev;
	}

	redo() {
		const next = this.redoStack.at(-1);
		if (!next) return;
		this.redoStack = this.redoStack.slice(0, -1);
		this.undoStack = [...this.undoStack, this.recipe];
		this.recipe = next;
	}

	/** What gets saved. */
	result(): Recipe {
		return normalize(this.recipe);
	}
}
