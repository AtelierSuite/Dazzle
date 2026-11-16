// Opening and saving files on the user's device. Where the browser has the File
// System Access API, documents save back in place; elsewhere they open through
// a file picker and save as downloads.

import { t } from "./i18n.js";
import { zip } from "./export.js";

const openTypes = () => [
  {
    description: t("Web.FileType.Presentations"),
    accept: {
      "application/vnd.openxmlformats-officedocument.presentationml.presentation": [".pptx"],
      "application/vnd.ms-powerpoint.presentation.macroEnabled.12": [".pptm"],
      "application/vnd.openxmlformats-officedocument.presentationml.slideshow": [".ppsx"],
      "application/vnd.apple.keynote": [".key"],
    },
  },
];

const pictureTypes = () => [
  { description: t("Web.FileType.Pictures"), accept: { "image/png": [".png"], "image/jpeg": [".jpg", ".jpeg"], "image/gif": [".gif"], "image/webp": [".webp"], "image/heic": [".heic"], "image/svg+xml": [".svg"] } },
];

const movieTypes = () => [
  { description: t("Web.FileType.Movies"), accept: { "video/mp4": [".mp4", ".m4v"], "video/quicktime": [".mov"], "video/webm": [".webm"] } },
];

export const canSaveInPlace = typeof window.showSaveFilePicker === "function";

/**
 * Asks the user for a file to open, or a picture to put in.
 * @returns {Promise<{ name: string, bytes: Uint8Array, handle?: FileSystemFileHandle } | null>}
 */
export async function pickFile({ pictures = false, movies = false } = {}) {
  const types = pictures ? pictureTypes() : movies ? movieTypes() : openTypes();
  if (typeof window.showOpenFilePicker === "function") {
    try {
      const [handle] = await window.showOpenFilePicker({ types, excludeAcceptAllOption: false, multiple: false });
      return readHandle(handle);
    } catch (error) {
      if (error?.name === "AbortError") return null;
      throw error;
    }
  }
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = types.flatMap((type) => Object.values(type.accept).flat()).join(",");
    input.addEventListener("change", async () => {
      const file = input.files?.[0];
      resolve(file ? { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) } : null);
    });
    input.addEventListener("cancel", () => resolve(null));
    input.click();
  });
}

/** Reads a file the user picked earlier, or a Keynote package (a folder), asking again for permission when the browser wants that. */
export async function readHandle(handle) {
  if (handle.queryPermission && (await handle.queryPermission({ mode: "read" })) !== "granted") {
    if ((await handle.requestPermission({ mode: "read" })) !== "granted") return null;
  }
  if (handle.kind === "directory") return readPackage(handle);
  const file = await handle.getFile();
  return { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()), handle };
}

/** Writes bytes into a file the user picked, or a Keynote package back into its folder, asking for permission to write when needed. */
export async function writeHandle(handle, bytes) {
  if (handle.queryPermission && (await handle.queryPermission({ mode: "readwrite" })) !== "granted") {
    if ((await handle.requestPermission({ mode: "readwrite" })) !== "granted") return false;
  }
  if (handle.kind === "directory") {
    await writePackage(handle, bytes);
    return true;
  }
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
  return true;
}

/**
 * Asks where to save, and saves there; downloads instead where the browser can't ask.
 * @returns {Promise<{ name: string, handle?: FileSystemFileHandle } | null>}
 */
export async function saveFileAs(bytes, suggestedName, { mime, extension, description }) {
  if (canSaveInPlace) {
    try {
      const handle = await window.showSaveFilePicker({
        suggestedName,
        types: [{ description, accept: { [mime]: [`.${extension}`] } }],
      });
      await writeHandle(handle, bytes);
      return { name: handle.name, handle };
    } catch (error) {
      if (error?.name === "AbortError") return null;
      throw error;
    }
  }
  download(bytes, suggestedName, mime);
  return { name: suggestedName };
}

/**
 * Asks where to save a file before it is made, while the click that asked
 * still counts. Resolves with a handle, null if the user cancelled, or
 * undefined where the browser can't ask (the file is then downloaded).
 */
export async function pickSaveHandle(suggestedName, { mime, extension, description }) {
  if (!canSaveInPlace) return undefined;
  try {
    return await window.showSaveFilePicker({ suggestedName, types: [{ description, accept: { [mime]: [`.${extension}`] } }] });
  } catch (error) {
    if (error?.name === "AbortError") return null;
    throw error;
  }
}

export const canPickFolders = typeof window.showDirectoryPicker === "function";

/** Asks for a folder to write files into. Resolves with its handle, or null if the user cancelled. */
export async function pickFolder() {
  try {
    return await window.showDirectoryPicker({ mode: "readwrite", id: "export" });
  } catch (error) {
    if (error?.name === "AbortError") return null;
    throw error;
  }
}

/** Writes a file into a folder the user picked, replacing one of the same name. */
export async function writeIntoFolder(folder, name, bytes) {
  const handle = await folder.getFileHandle(name, { create: true });
  await writeHandle(handle, bytes);
}

// MARK: - Keynote packages

// A Keynote document saved as a package is a folder (Name.key/Index, Data,
// Metadata) rather than one file. The same files zipped together are a
// single-file Keynote document, which is what the engine reads and writes;
// so a package opens as its files zipped up, and saves by writing the
// engine's zip back into the folder, file by file.

/** What each package held when it was read or last written, so saving writes only what changed. */
const packageContents = new WeakMap();

/** Whether this browser can open a package by asking for its folder. */
export const canPickPackages = typeof window.showDirectoryPicker === "function";

/** Asks for a Keynote package (a folder) and reads it. */
export async function pickPackage() {
  try {
    const handle = await window.showDirectoryPicker({ mode: "readwrite", id: "keynote" });
    return readPackage(handle);
  } catch (error) {
    if (error?.name === "AbortError") return null;
    throw error;
  }
}

/** A package's files, path by path, from a folder handle. */
async function packageFiles(folder, prefix = "", files = []) {
  for await (const [name, child] of folder.entries()) {
    if (name === ".DS_Store") continue;
    if (child.kind === "directory") await packageFiles(child, `${prefix}${name}/`, files);
    else files.push({ name: `${prefix}${name}`, bytes: new Uint8Array(await (await child.getFile()).arrayBuffer()) });
  }
  return files;
}

/**
 * Reads a package folder as a single-file Keynote document.
 * @returns {Promise<{ name: string, bytes: Uint8Array, handle: FileSystemDirectoryHandle }>}
 */
export async function readPackage(handle) {
  const files = (await packageFiles(handle)).sort((a, b) => a.name.localeCompare(b.name));
  packageContents.set(handle, new Map(files.map((file) => [file.name, file.bytes])));
  return { name: handle.name, bytes: zip(files), handle };
}

/** Reads a package dropped where the browser gives a folder entry rather than a handle (Safari, Firefox). */
export async function readPackageEntry(entry) {
  const files = [];
  const read = (directory, prefix) => new Promise((resolve, reject) => {
    const reader = directory.createReader();
    const children = [];
    const more = () => reader.readEntries(async (batch) => {
      if (batch.length) {
        children.push(...batch);
        more();
        return;
      }
      try {
        for (const child of children) {
          if (child.name === ".DS_Store") continue;
          if (child.isDirectory) await read(child, `${prefix}${child.name}/`);
          else files.push({ name: `${prefix}${child.name}`, bytes: new Uint8Array(await (await new Promise((done, fail) => child.file(done, fail))).arrayBuffer()) });
        }
        resolve();
      } catch (error) {
        reject(error);
      }
    }, reject);
    more();
  });
  await read(entry, "");
  files.sort((a, b) => a.name.localeCompare(b.name));
  return { name: entry.name, bytes: zip(files) };
}

/** The files in a zip archive, stored or deflated. */
export async function unzip(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = bytes.length - 22;
  while (end >= 0 && view.getUint32(end, true) !== 0x06054b50) end--;
  if (end < 0) throw new Error("Not a zip archive.");
  const count = view.getUint16(end + 10, true);
  let at = view.getUint32(end + 16, true);
  const decoder = new TextDecoder();
  const files = [];
  for (let index = 0; index < count; index++) {
    const method = view.getUint16(at + 10, true);
    const size = view.getUint32(at + 20, true);
    const nameLength = view.getUint16(at + 28, true);
    const extra = view.getUint16(at + 30, true);
    const comment = view.getUint16(at + 32, true);
    const offset = view.getUint32(at + 42, true);
    const name = decoder.decode(bytes.subarray(at + 46, at + 46 + nameLength));
    const start = offset + 30 + view.getUint16(offset + 26, true) + view.getUint16(offset + 28, true);
    let data = bytes.subarray(start, start + size);
    if (method === 8) data = new Uint8Array(await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream("deflate-raw"))).arrayBuffer());
    if (!name.endsWith("/")) files.push({ name, bytes: data });
    at += 46 + nameLength + extra + comment;
  }
  return files;
}

const sameBytes = (a, b) => a?.length === b.length && a.every((value, index) => value === b[index]);

/** Writes a single-file Keynote document's files into its package folder, only those that changed. */
async function writePackage(folder, bytes) {
  const known = packageContents.get(folder) ?? new Map();
  for (const file of await unzip(bytes)) {
    if (sameBytes(known.get(file.name), file.bytes)) continue;
    const parts = file.name.split("/");
    const name = parts.pop();
    let directory = folder;
    for (const part of parts) directory = await directory.getDirectoryHandle(part, { create: true });
    const writable = await (await directory.getFileHandle(name, { create: true })).createWritable();
    await writable.write(file.bytes);
    await writable.close();
    known.set(file.name, file.bytes.slice());
  }
  packageContents.set(folder, known);
}

export function download(bytes, name, mime) {
  const url = URL.createObjectURL(new Blob([bytes], { type: mime }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.hidden = true;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

/** Files the operating system asked the installed app to open (manifest file_handlers). */
export function onLaunchFiles(callback) {
  if (!("launchQueue" in window)) return;
  window.launchQueue.setConsumer(async (params) => {
    const handle = params.files?.[0];
    if (handle) callback(await readHandle(handle));
  });
}

/** Files dropped onto the window. */
export function onDroppedFiles(element, callback, onHover) {
  element.addEventListener("dragover", (event) => {
    if (![...(event.dataTransfer?.types ?? [])].includes("Files")) return;
    event.preventDefault();
    onHover?.(true);
  });
  element.addEventListener("dragleave", (event) => {
    if (event.relatedTarget && element.contains(event.relatedTarget)) return;
    onHover?.(false);
  });
  element.addEventListener("drop", async (event) => {
    onHover?.(false);
    const item = [...(event.dataTransfer?.items ?? [])].find((entry) => entry.kind === "file");
    if (!item) return;
    event.preventDefault();
    // Where it was let go, and the file, read before the event is over.
    const where = { clientX: event.clientX, clientY: event.clientY, target: event.target };
    const file = item.getAsFile();
    // A Keynote package is a folder.
    const entry = item.webkitGetAsEntry?.();
    const handle = await item.getAsFileSystemHandle?.();
    if (handle?.kind === "file" || handle?.kind === "directory" && /\.key$/i.test(handle.name)) {
      callback(await readHandle(handle), where);
      return;
    }
    if (entry?.isDirectory) {
      if (/\.key$/i.test(entry.name)) callback(await readPackageEntry(entry), where);
      return;
    }
    if (file) callback({ name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) }, where);
  });
}
