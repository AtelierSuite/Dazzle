// Exporting slides as printed pages, as the Mac's ExportController does with
// SlideExporter: a page per slide, notes pages, or handouts.

/** The page layouts offered for PDF, as on the Mac: slides, notes pages, and handouts of 2, 3, 4 or 6. */
export const PAGE_LAYOUTS = [
  ["slides", "Export.Layout.Slides"], ["notes", "Export.Layout.Notes"],
  ["handouts2", "Mac.Export.Layout.Handouts2"], ["handouts3", "Mac.Export.Layout.Handouts3"],
  ["handouts4", "Mac.Export.Layout.Handouts4"], ["handouts6", "Mac.Export.Layout.Handouts6"],
];

// MARK: - Pages for printing

/** Paper for notes and handouts, in points: Letter where US measures are used, A4 elsewhere. */
export function paperSize(language = navigator.language) {
  let region = "";
  try {
    region = new Intl.Locale(language).maximize().region ?? "";
  } catch {
    // A tag the browser can't read is taken as metric.
  }
  return ["US", "LR", "MM"].includes(region) ? { w: 612, h: 792 } : { w: 595, h: 842 };
}

/** The largest slide-shaped rectangle in `box`, centred, in points. */
function fitted(size, box) {
  const aspect = size.w / size.h;
  let w = box.w;
  let h = box.w / aspect;
  if (h > box.h) {
    h = box.h;
    w = box.h * aspect;
  }
  return { x: box.x + (box.w - w) / 2, y: box.y + (box.h - h) / 2, w, h };
}

/**
 * Lays out printed pages, as SlideExporter's PDFs on the Mac: a page per slide
 * at its own size, notes pages with the slide above its notes, or handouts.
 * `place(page, slide, rect)` puts slide number `slide` on `page` in `rect`, in points.
 * @returns {{ size: { w: number, h: number }, pages: HTMLElement[] }}
 */
export function layoutPages({ slides, size, layout, place }) {
  const pages = [];
  const page = (paper) => {
    const element = document.createElement("div");
    element.className = "app__print-page";
    element.style.width = `${paper.w}pt`;
    element.style.height = `${paper.h}pt`;
    pages.push(element);
    return element;
  };
  const absolute = (element, rect) => Object.assign(element.style, {
    position: "absolute", left: `${rect.x}pt`, top: `${rect.y}pt`, width: `${rect.w}pt`, ...(rect.h != null ? { height: `${rect.h}pt` } : {}),
  });
  const framed = (target, index, rect) => {
    place(target, index, rect);
    // A hairline round each slide on paper.
    const frame = document.createElement("div");
    frame.className = "app__print-frame";
    absolute(frame, rect);
    target.append(frame);
  };
  const number = (target, paper, value) => {
    const label = document.createElement("div");
    label.className = "app__print-number";
    absolute(label, { x: 0, y: paper.h - 30, w: paper.w });
    label.textContent = String(value);
    target.append(label);
  };

  if (layout === "slides") {
    for (let index = 0; index < slides.length; index++) place(page(size), index, { x: 0, y: 0, w: size.w, h: size.h });
    return { size, pages };
  }
  const paper = paperSize();
  if (layout === "notes") {
    const margin = 54;
    slides.forEach((slide, index) => {
      const target = page(paper);
      const rect = fitted(size, { x: margin, y: margin, w: paper.w - margin * 2, h: paper.h * 0.42 });
      framed(target, index, rect);
      const notes = document.createElement("div");
      notes.className = "app__print-notes";
      absolute(notes, { x: margin, y: rect.y + rect.h + 28, w: paper.w - margin * 2, h: paper.h - (rect.y + rect.h) - 28 - margin });
      notes.textContent = slide.notes ?? "";
      target.append(notes);
      number(target, paper, index + 1);
    });
    return { size: paper, pages };
  }
  const count = Number(layout.replace("handouts", "")) || 6;
  // Columns and rows for each count; three to a page leave room to write beside them.
  const [columns, rows] = { 1: [1, 1], 2: [1, 2], 3: [1, 3], 4: [2, 2], 6: [2, 3] }[count] ?? [3, 3];
  const margin = 40;
  const area = { x: margin, y: margin, w: paper.w - margin * 2, h: paper.h - margin * 2 - 24 };
  const slideArea = count === 3 ? { ...area, w: area.w * 0.5 } : area;
  const cell = { w: slideArea.w / columns, h: slideArea.h / rows };
  const pageCount = Math.max(Math.ceil(slides.length / count), 1);
  for (let pageIndex = 0; pageIndex < pageCount; pageIndex++) {
    const target = page(paper);
    for (let position = 0; position < count; position++) {
      const index = pageIndex * count + position;
      if (index >= slides.length) break;
      const column = position % columns;
      const row = Math.floor(position / columns);
      const box = { x: slideArea.x + column * cell.w + 10, y: slideArea.y + row * cell.h + 10, w: cell.w - 20, h: cell.h - 20 };
      const rect = fitted(size, box);
      framed(target, index, rect);
      if (count === 3) {
        // Lines to write notes on, beside the slide.
        for (let y = rect.y + 18; y < rect.y + rect.h; y += 18) {
          const line = document.createElement("div");
          line.className = "app__print-line";
          absolute(line, { x: area.x + area.w / 2 + 16, y, w: area.w / 2 - 16 });
          target.append(line);
        }
      }
    }
    number(target, paper, pageIndex + 1);
  }
  return { size: paper, pages };
}
