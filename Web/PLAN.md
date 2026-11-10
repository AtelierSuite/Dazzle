# Plan: Dazzle for the web (WebAssembly + offline PWA)

## Goal

Ship Dazzle as an installable Progressive Web App that runs **entirely on the device**: after the first visit it opens, edits, plays and saves PowerPoint presentations, and opens and saves Keynote presentations, with no network connection and no server. The engine and the editing code are the same Swift the Apple apps use, compiled to WebAssembly, so presentations behave identically on every platform.

Constraints, as for Tables and Libretto: **no Node packages** (the build is Swift and a shell script; the page is plain HTML, CSS and JavaScript modules), and **the web build reads nothing from the Apple app targets** except `Common/`'s editing code, which it compiles as it is.

## Where things stand

The app works end to end: start screen; new presentations; opening `.pptx`, `.pptm`, `.ppsx` and single-file `.key`; the slide navigator (thumbnails, picking several, dragging into order, duplicating, hiding, deleting, copy and paste); new slides on any layout and changing a slide's layout; text boxes, shapes, tables, charts, pictures and movies; moving, resizing and turning with snapping; typing in place in shapes and table cells; character and paragraph formatting; fill, outline, shadow, reflection, picture crop and replace; arrangement, alignment, distribution and groups; links and descriptions; table rows, columns, header and banded rows and cell fills; chart type, grouping, title, legend, gridlines, value labels and data; animations (entrance, emphasis, exit; trigger, duration, delay, direction, order, preview); comments; header and footer; slide size; advancing and looping; background; speaker notes; find and replace; undo and redo; zoom; PDF by printing; the slideshow with a presenter view linked to an audience window on another display, or full screen in one window, with animations, media, links, blanking and auto-advance; light and dark; five languages; autosave and Open Recent; and an installable PWA whose service worker serves every file offline.

| Part | Where | Notes |
| --- | --- | --- |
| Engine | `Engine/` (Swift package) | Shared by the Xcode project (compiled in place) and the web build. The model and both file formats build for WebAssembly; Core Graphics and Core Text drawing, ImageIO and AVFoundation stay Apple-only |
| Editing | `Common/Editing` | `EditorState` and its extensions, compiled into the web build through `engine/swift/Sources/DazzleWasm/Shared` |
| WebAssembly interface | `Web/engine/` | C exports with JSON requests, the session and scene renderer, a WASI host, the worker, a strings tool, Node smoke tests |
| Window | `Web/app/` | Slides, canvas, navigator, inspector, slideshow and audience window, files, storage |
| Design system | `Web/design/` | Libretto's and Tables' tokens, components, menus and lint, in Dazzle's orange, with slides and a presenter view |

### What porting the engine took

| Problem | Fix |
| --- | --- |
| The engine lived in the Xcode project | Moved to `Engine/DazzleEngine` with a `Package.swift`; the Xcode project points at the new folder |
| `Compression` (ZIP deflate) | Libretto's plain-Swift raw DEFLATE (`Portable/RawDeflate.swift`) |
| `#bundle` string lookups | `Bundle.engine` on Apple platforms; elsewhere a string table the page loads, converted from the same catalogues (`Portable/PortableStrings.swift`) |
| `CGPath`, `CGMutablePath`, `CGAffineTransform` in preset geometry and animation masks | A portable path that keeps arcs as cubic Béziers and writes SVG (`Portable/PathStandIn.swift`) |
| `UTType` MIME lookups | A table of the types presentations hold (`MediaTypes`) |
| `FileWrapper` for Keynote packages | Libretto's stand-in; single-file Keynote documents only |
| Core Text font lookups when importing Keynote | Apple-only; elsewhere PostScript names are taken apart as for uninstalled fonts |
| Display P3 colours in Keynote | Converted to sRGB by hand where Core Graphics isn't there |
| Measuring text to fit Keynote's growing text boxes | Apple-only; elsewhere the frames Keynote saved are kept |
| ImageIO re-encoding of TIFF, HEIC and PDF pictures in Keynote documents | Apple-only; the browser re-encodes pictures it inserts itself |
| Text layout for grow-to-fit shapes in `EditorState.setTextBody` | The page measures the text and passes its height |
| Bullet, number and date labels lived in `TextRenderer` | Moved to `TextLabels`, shared |
| Group placement lived in `SlideRenderer` | Moved to `SlideShape.placed(from:into:)`, shared |
| Pasting lived beside the Apple pasteboard | Split into `SlideCopying.swift`, shared; the web app keeps its own clipboard of shapes and slides |
| `Int` is 32 bits on wasm32 | A slide layout id literal widened to `Int64` |

## Next

### Fidelity

- [ ] Draw charts with the theme's fonts measured, rather than estimated, for legends and axis labels.
- [ ] Transitions between slides (kept in the file; the slideshow cuts).
- [ ] Text on a path, WordArt warps, 3-D effects, pattern fills (drawn as their first colour on Apple platforms too).
- [ ] EMF and WMF pictures.
- [ ] Keynote packages (folders), with the File System Access directory picker.

### Editing parity with the Apple apps

1. Drawing (freehand ink) and custom colours with opacity.
2. Editing a motion path's points.
3. Export as images and as a movie (`SlideExporter`, `VideoExporter` are Core Graphics and AVFoundation).
4. Rich paste from other apps.
5. The watch remote (no web equivalent; a phone remote over WebRTC could stand in).

### Engine quality

- [ ] Run the engine test suite under WASI (`DazzleTests` mostly needs only `DazzleEngine`).
- [ ] **Size.** The release module is 54 MB (about 20 MB gzipped), mostly ICU data Foundation links. As for Tables: `wasm-opt -Oz`, `FoundationEssentials`, or trimmed ICU data.

### Release

- [ ] Browser tests in Chromium, WebKit and Firefox through WebDriver, including two-display presenting.
- [ ] Accessibility passes with VoiceOver and keyboard only.
- [ ] The App Store link in the Help menu, once Dazzle's listing is public (`APP_STORE_URL` in `app/window.js`).
- [ ] A social sharing picture, as Tables has.
