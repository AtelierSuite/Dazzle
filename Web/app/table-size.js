// The rows and columns picked for a new table, kept within limits, and the
// grid of cells the picker shows them on: the web app's copy of
// TableSizeSelection in Common/Editing. The grid starts small and grows to keep
// a spare row and column past the selection, up to its largest; sizes past the
// grid are reached with the steppers.

export const ROW_LIMIT = { min: 1, max: 50 };
export const COLUMN_LIMIT = { min: 1, max: 30 };
/** The grid's size when the picker opens. */
export const INITIAL_GRID = { rows: 5, columns: 6 };
/** The most cells the grid grows to. */
export const LARGEST_GRID = { rows: 10, columns: 10 };

const clamp = (value, { min, max }) => Math.min(Math.max(Math.trunc(Number(value)) || min, min), max);

export class TableSizeSelection {
  constructor(rows = 3, columns = 3) {
    this.gridRows = INITIAL_GRID.rows;
    this.gridColumns = INITIAL_GRID.columns;
    this.set({ rows, columns });
  }

  /** Sets the size, keeping it within the limits. */
  set({ rows = this.rows, columns = this.columns } = {}) {
    this.rows = clamp(rows, ROW_LIMIT);
    this.columns = clamp(columns, COLUMN_LIMIT);
    // The grid only grows while the picker is open, so it doesn't jump about under the pointer.
    this.gridRows = Math.min(Math.max(this.gridRows, this.rows + 1), LARGEST_GRID.rows);
    this.gridColumns = Math.min(Math.max(this.gridColumns, this.columns + 1), LARGEST_GRID.columns);
    return this;
  }

  /** Picks the size that ends at a cell of the grid, counted from zero. */
  select(row, column) {
    return this.set({ rows: Math.min(row, LARGEST_GRID.rows - 1) + 1, columns: Math.min(column, LARGEST_GRID.columns - 1) + 1 });
  }

  /** Grows or shrinks the selection by a row or a column, as the arrow keys do. */
  move(direction) {
    const change = { up: { rows: this.rows - 1 }, down: { rows: this.rows + 1 }, left: { columns: this.columns - 1 }, right: { columns: this.columns + 1 } }[direction];
    return change ? this.set(change) : this;
  }

  /** Whether a cell of the grid, counted from zero, is within the selection. */
  contains(row, column) {
    return row < this.rows && column < this.columns;
  }

  /** Whether a cell is part of the grid shown so far. */
  shows(row, column) {
    return row < this.gridRows && column < this.gridColumns;
  }
}

/** The cell under a point, for a grid whose cells are `pitch` apart, or null before the first cell. */
export function cellAt(x, y, pitch) {
  if (!(pitch > 0) || x < 0 || y < 0) return null;
  return { row: Math.min(Math.floor(y / pitch), LARGEST_GRID.rows - 1), column: Math.min(Math.floor(x / pitch), LARGEST_GRID.columns - 1) };
}
