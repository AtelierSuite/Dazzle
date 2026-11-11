// The table size picker, a popover under the toolbar's table button: point at
// the grid and click (or drag and let go) to insert, use the arrow keys and
// Return on the grid, or set the size with the steppers and press Insert.

import { t } from "./i18n.js";
import { escapeHTML } from "./inspector.js";
import { COLUMN_LIMIT, LARGEST_GRID, ROW_LIMIT, TableSizeSelection, cellAt } from "./table-size.js";

const CELL = 18;
const GAP = 3;
const PITCH = CELL + GAP;
const MARGIN = 8;
/** The grid's padding, inside its focus outline (--ds-spacing-02). */
const PADDING = 4;

let open = null;

/** Closes the picker if it is open, and says whether it was. */
export function closeTablePicker() {
  if (!open) return false;
  open.close();
  return true;
}

/**
 * Opens the picker under `anchor`.
 * @param {HTMLElement} root the window to put it in
 * @param {HTMLElement} anchor what it points at
 * @param {{ icon: (name: string) => string, onInsert: (size: { rows: number, columns: number }) => void }} options
 */
export function openTablePicker(root, anchor, { icon, onInsert }) {
  closeTablePicker();
  const opener = document.activeElement;
  // What the steppers, Return or a click chose; the pointer only previews over it.
  const chosen = new TableSizeSelection();
  const shown = new TableSizeSelection();

  const popover = document.createElement("form");
  popover.className = "ds-popover app__table-picker";
  popover.setAttribute("role", "dialog");
  popover.setAttribute("aria-label", t("Menu.Insert.Table"));
  popover.innerHTML = `
    <p class="ds-popover__title ds-numeric app__table-picker-size" aria-hidden="true"></p>
    <div class="app__table-grid" tabindex="0" role="button" aria-label="${escapeHTML(t("Table.Picker.Grid"))}"
      aria-describedby="table-picker-spoken table-picker-hint">
      ${Array.from({ length: LARGEST_GRID.rows * LARGEST_GRID.columns }, (_, index) =>
        `<span class="app__table-cell" data-row="${Math.floor(index / LARGEST_GRID.columns)}" data-column="${index % LARGEST_GRID.columns}"></span>`).join("")}
    </div>
    <p class="ds-visually-hidden" id="table-picker-spoken" aria-live="polite"></p>
    <p class="ds-visually-hidden" id="table-picker-hint">${escapeHTML(t("Table.Picker.Hint"))}</p>
    <div class="ds-form app__table-picker-form">
      ${stepper("columns", t("Table.Columns"), COLUMN_LIMIT, icon)}
      ${stepper("rows", t("Table.Rows"), ROW_LIMIT, icon)}
    </div>
    <div class="app__table-picker-buttons">
      <button class="ds-button ds-button--primary" type="submit">${escapeHTML(t("Table.Insert"))}</button>
    </div>`;

  const grid = popover.querySelector(".app__table-grid");
  const cells = [...grid.children];
  const size = popover.querySelector(".app__table-picker-size");
  const spoken = popover.querySelector("#table-picker-spoken");
  const fields = { rows: popover.querySelector("[data-dimension=rows]"), columns: popover.querySelector("[data-dimension=columns]") };
  grid.style.setProperty("--app-table-columns", LARGEST_GRID.columns);

  const render = () => {
    size.textContent = t("Table.Size", shown.columns, shown.rows);
    const words = t("Table.Size.Spoken", shown.columns, shown.rows);
    if (spoken.textContent !== words) spoken.textContent = words;
    for (const cell of cells) {
      const row = Number(cell.dataset.row);
      const column = Number(cell.dataset.column);
      cell.classList.toggle("is-selected", shown.contains(row, column));
      cell.classList.toggle("is-shown", shown.shows(row, column));
    }
    for (const [dimension, field] of Object.entries(fields)) {
      if (document.activeElement !== field || Number(field.value) !== shown[dimension]) field.value = String(shown[dimension]);
    }
  };
  const preview = (cell) => {
    shown.select(cell.row, cell.column);
    render();
  };
  const choose = (change) => {
    chosen.set(change);
    shown.set({ rows: chosen.rows, columns: chosen.columns });
    render();
  };
  const insert = () => {
    const picked = { rows: shown.rows, columns: shown.columns };
    close();
    onInsert(picked);
  };

  // The pointer: a mouse previews by hovering and inserts with a click; a pen
  // or finger drags across the cells and inserts on letting go.
  let pressed = false;
  const cellFor = (event) => {
    const rect = grid.getBoundingClientRect();
    return cellAt(Math.max(event.clientX - rect.left - PADDING, 0), Math.max(event.clientY - rect.top - PADDING, 0), PITCH);
  };
  grid.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    grid.focus();
    grid.setPointerCapture(event.pointerId);
    pressed = true;
    const cell = cellFor(event);
    if (cell) choose({ rows: cell.row + 1, columns: cell.column + 1 });
  });
  grid.addEventListener("pointermove", (event) => {
    const cell = cellFor(event);
    if (!cell) return;
    if (pressed) choose({ rows: cell.row + 1, columns: cell.column + 1 });
    else if (event.pointerType === "mouse") preview(cell);
  });
  grid.addEventListener("pointerup", (event) => {
    if (!pressed) return;
    pressed = false;
    const cell = cellFor(event);
    if (cell) choose({ rows: cell.row + 1, columns: cell.column + 1 });
    insert();
  });
  grid.addEventListener("pointercancel", () => { pressed = false; });
  grid.addEventListener("pointerleave", () => {
    if (pressed) return;
    shown.set({ rows: chosen.rows, columns: chosen.columns });
    render();
  });
  grid.addEventListener("keydown", (event) => {
    const direction = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" }[event.key];
    if (direction) {
      event.preventDefault();
      chosen.move(direction);
      choose({});
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      insert();
    }
  });

  // The steppers.
  for (const [dimension, field] of Object.entries(fields)) {
    field.addEventListener("input", () => {
      if (field.value !== "") choose({ [dimension]: field.value });
    });
    field.addEventListener("change", () => choose({ [dimension]: field.value }));
  }
  for (const arrow of popover.querySelectorAll(".ds-stepper__arrow")) {
    arrow.addEventListener("mousedown", (event) => event.preventDefault());
    arrow.addEventListener("click", () => {
      const field = arrow.closest(".ds-stepper").querySelector("input");
      choose({ [field.dataset.dimension]: chosen[field.dataset.dimension] + Number(arrow.dataset.step) });
    });
  }
  popover.addEventListener("submit", (event) => {
    event.preventDefault();
    for (const [dimension, field] of Object.entries(fields)) chosen.set({ [dimension]: field.value });
    shown.set({ rows: chosen.rows, columns: chosen.columns });
    insert();
  });

  // Closing: Escape, a press outside, or the window changing under it.
  const outside = (event) => {
    if (!popover.contains(event.target) && !anchor.contains(event.target)) close();
  };
  const onKey = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      close();
      opener?.focus?.();
    }
  };
  function close() {
    if (!popover.isConnected) return;
    popover.remove();
    document.removeEventListener("pointerdown", outside, true);
    window.removeEventListener("resize", close);
    window.removeEventListener("blur", close);
    if (open?.popover === popover) open = null;
  }
  popover.addEventListener("keydown", onKey);
  document.addEventListener("pointerdown", outside, true);
  window.addEventListener("resize", close);
  window.addEventListener("blur", close);

  root.append(popover);
  place(popover, anchor);
  render();
  grid.focus();
  open = { popover, close };
  return open;
}

function stepper(dimension, label, limit, icon) {
  const id = `table-picker-${dimension}`;
  return `
    <label class="ds-form__label" for="${id}">${escapeHTML(label)}</label>
    <span class="ds-form__control">
      <span class="ds-stepper ds-stepper--xs">
        <input class="ds-stepper__input ds-numeric" id="${id}" type="number" step="1" min="${limit.min}" max="${limit.max}" data-dimension="${dimension}">
        <span class="ds-stepper__arrows">
          <button class="ds-stepper__arrow" type="button" data-step="1" tabindex="-1" aria-label="${escapeHTML(label)} +">${icon("chevronUp")}</button>
          <button class="ds-stepper__arrow" type="button" data-step="-1" tabindex="-1" aria-label="${escapeHTML(label)} −">${icon("chevronDown")}</button>
        </span>
      </span>
    </span>`;
}

/** Puts the popover under its anchor, inside the window, with its arrow pointing at the anchor. */
function place(popover, anchor) {
  const rect = anchor.getBoundingClientRect();
  const width = popover.offsetWidth;
  const centre = rect.left + rect.width / 2;
  const left = Math.min(Math.max(centre - width / 2, MARGIN), window.innerWidth - width - MARGIN);
  popover.style.left = `${left}px`;
  popover.style.top = `${rect.bottom + MARGIN}px`;
  popover.style.setProperty("--ds-popover-arrow", `${Math.min(Math.max(centre - left - 5, 12), width - 22)}px`);
}
