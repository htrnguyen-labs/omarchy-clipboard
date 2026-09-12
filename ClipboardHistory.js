var maxTextChars = 65536
var maxEntries = 50

function normalizeEntry(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { type: "text", text: value } : null

  if (!value || typeof value !== "object") return null

  var type = String(value.type || value.kind || "")
  if (type === "text") {
    var text = String(value.text || "")
    return text.trim().length > 0 && text.length <= maxTextChars ? { type: "text", text: text } : null
  }

  if (type === "image") {
    var path = String(value.path || "")
    if (!path || path.length > 1024) return null
    var entry = {
      type: "image",
      path: path,
      mime: String(value.mime || "image/png")
    }
    if (value.capturedAt !== undefined && value.capturedAt !== null)
      entry.capturedAt = String(value.capturedAt)
    return entry
  }

  return null
}

function entryKey(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image:" + String(entry.path || "")
  return "text:" + String(entry.text || "")
}

function parseHistory(raw) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    var next = []
    if (!Array.isArray(parsed)) return next

    for (var i = 0; i < parsed.length && next.length < maxEntries; i++) {
      var entry = normalizeEntry(parsed[i])
      if (entry) next.push(entry)
    }
    return next
  } catch (e) {
    return []
  }
}

function addEntry(history, entry, limit) {
  var normalized = normalizeEntry(entry)
  var max = limit === undefined || limit === null ? 100 : Number(limit)
  if (isNaN(max)) max = 100
  max = Math.min(maxEntries, Math.max(0, max))
  if (!normalized) return Array.isArray(history) ? history.slice(0, max) : []
  if (max === 0) return []

  var key = entryKey(normalized)
  var next = [normalized]
  var values = Array.isArray(history) ? history : []

  for (var i = 0; i < values.length && next.length < max; i++) {
    var existing = normalizeEntry(values[i])
    if (!existing || entryKey(existing) === key) continue
    next.push(existing)
  }

  return next
}

function removeEntryAt(history, index) {
  var values = Array.isArray(history) ? history : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= values.length) return values.slice()

  var next = values.slice()
  next.splice(target, 1)
  return next
}

function indexOfKey(entries, key) {
  var values = Array.isArray(entries) ? entries : []
  for (var i = 0; i < values.length; i++) {
    var existing = normalizeEntry(values[i])
    if (existing && entryKey(existing) === key) return i
  }
  return -1
}

function togglePin(pinned, entry, limit) {
  var normalized = normalizeEntry(entry)
  if (!normalized) return Array.isArray(pinned) ? pinned.slice() : []

  var key = entryKey(normalized)
  var values = Array.isArray(pinned) ? pinned.slice() : []
  var at = indexOfKey(values, key)
  if (at >= 0) values.splice(at, 1)
  else values.push(normalized)
  return values.slice(0, Math.min(maxEntries, Math.max(0, Number(limit) || maxEntries)))
}

function unpinAt(pinned, index) {
  return removeEntryAt(pinned, index)
}

function clearHistory() {
  return []
}

function parseEntryJson(line) {
  var raw = String(line || "").trim()
  if (!raw) return null
  try { return normalizeEntry(JSON.parse(raw)) } catch (e) { return null }
}

function searchableText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image screenshot " + String(entry.mime || "") + " " + String(entry.capturedAt || "")
  return String(entry.text || "") + " " + fileEntryText(entry)
}

function decodeFileUri(uri) {
  var value = String(uri || "").trim()
  if (value.indexOf("file://") !== 0) return ""

  var path = value.substring(7)
  if (path.indexOf("localhost/") === 0) path = path.substring(9)
  if (path.charAt(0) !== "/") return ""

  try { return decodeURIComponent(path) } catch (e) { return path }
}

function filePaths(entry) {
  if (!entry || entry.type !== "text") return []

  var lines = String(entry.text || "").split(/\r?\n/)
  var paths = []
  for (var i = 0; i < lines.length; i++) {
    var path = decodeFileUri(lines[i])
    if (path) paths.push(path)
  }
  return paths
}

function fileName(path) {
  var parts = String(path || "").split("/")
  return parts.length > 0 ? parts[parts.length - 1] : String(path || "")
}

function isImagePath(path) {
  return /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(String(path || ""))
}

function fileEntryText(entry) {
  var paths = filePaths(entry)
  if (paths.length === 0) return ""
  if (paths.length === 1) return fileName(paths[0])
  return paths.length + " files"
}

function imagePreviewText(entry) {
  var timestamp = String(entry && entry.capturedAt || "")
  if (!timestamp) return "Image"

  var label = String(entry && entry.mime || "") === "image/png" ? "Screenshot" : "Image"
  return label + " from " + timestamp
}

function previewText(entry) {
  if (!entry) return ""
  if (entry.type === "image") return imagePreviewText(entry)
  var fileText = fileEntryText(entry)
  if (fileText) return fileText
  return String(entry.text || "").replace(/\s+/g, " ")
}

function fullText(entry) {
  if (!entry) return ""
  var paths = filePaths(entry)
  if (paths.length > 0) return paths.join("\n")
  return String(entry.text || "")
}

// The picker only ever searches and renders a prefix of an entry, so scan and
// render just that much. A single huge paste otherwise costs hundreds of
// megabytes of string work on every keystroke and stalls the whole shell.
// Pasting reads the full entry back from history by index, so nothing is lost.
var displayTextLimit = 8192

function cappedEntry(entry) {
  if (!entry || entry.type !== "text" || entry.text.length <= displayTextLimit) return entry

  // Cut on a line break so a file:// URI never truncates into a bogus path.
  var cut = entry.text.lastIndexOf("\n", displayTextLimit)
  return { type: "text", text: entry.text.slice(0, cut > 0 ? cut : displayTextLimit) }
}

function sectionRow(label, icon, hint) {
  return {
    entryType: "section",
    sectionLabel: String(label || ""),
    sectionIcon: String(icon || ""),
    sectionHint: String(hint || ""),
    fullText: "",
    previewText: "",
    previewImage: "",
    path: "",
    mime: "",
    index: -1,
    pinnedIndex: -1,
    pinned: false
  }
}

function displayRows(history, pinned, query, limit) {
  var values = Array.isArray(history) ? history : []
  var saved = Array.isArray(pinned) ? pinned : []
  var needle = String(query || "").trim().toLowerCase()
  var max = limit === undefined || limit === null ? 50 : Number(limit)
  if (isNaN(max)) max = 50
  max = Math.max(0, max)
  if (max === 0) return []

  var pinnedRows = []
  var historyRows = []

  for (var p = 0; p < saved.length; p++) {
    var pinnedEntry = cappedEntry(normalizeEntry(saved[p]))
    if (!pinnedEntry) continue
    if (needle && searchableText(pinnedEntry).toLowerCase().indexOf(needle) < 0) continue
    pinnedRows.push(buildRow(pinnedEntry, -1, p, true))
  }

  for (var i = 0; i < values.length && historyRows.length < max; i++) {
    var entry = cappedEntry(normalizeEntry(values[i]))
    if (!entry) continue
    // A pinned copy already represents this entry in the list.
    if (indexOfKey(saved, entryKey(entry)) >= 0) continue
    if (needle && searchableText(entry).toLowerCase().indexOf(needle) < 0) continue

    historyRows.push(buildRow(entry, i, -1, false))
  }

  if (pinnedRows.length === 0 && historyRows.length === 0) return []

  var rows = []
  rows.push(sectionRow("Pinned", "\uD83D\uDCCC", pinnedRows.length === 0 ? "press Ctrl+P to pin" : ""))
  rows = rows.concat(pinnedRows)
  if (historyRows.length > 0) {
    rows.push(sectionRow("History", "\uD83D\uDD58", ""))
    rows = rows.concat(historyRows)
  }
  return rows
}

function buildRow(entry, historyIndex, pinnedIndex, isPinned) {
  var paths = filePaths(entry)
  var isFile = paths.length > 0
  var isImage = entry.type === "image"
  var previewPath = isImage ? String(entry.path || "") : (isFile && paths.length === 1 && isImagePath(paths[0]) ? paths[0] : "")
  return {
    entryType: isFile ? "file" : entry.type,
    fullText: isImage ? "" : fullText(entry),
    previewText: previewText(entry),
    previewImage: previewPath,
    path: isImage ? String(entry.path || "") : (isFile && paths.length === 1 ? paths[0] : ""),
    mime: isImage ? String(entry.mime || "image/png") : "text/plain",
    index: historyIndex,
    pinnedIndex: pinnedIndex,
    pinned: isPinned,
    sectionLabel: "",
    sectionIcon: "",
    sectionHint: ""
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeEntry: normalizeEntry,
    entryKey: entryKey,
    parseHistory: parseHistory,
    addEntry: addEntry,
    removeEntryAt: removeEntryAt,
    indexOfKey: indexOfKey,
    togglePin: togglePin,
    unpinAt: unpinAt,
    clearHistory: clearHistory,
    parseEntryJson: parseEntryJson,
    searchableText: searchableText,
    previewText: previewText,
    imagePreviewText: imagePreviewText,
    filePaths: filePaths,
    fileEntryText: fileEntryText,
    fullText: fullText,
    displayRows: displayRows
  }
}
