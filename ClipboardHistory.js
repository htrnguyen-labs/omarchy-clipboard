var maxTextChars = 65536
var maxEntries = 300
var maxStateChars = 60 * 1024

function withinStateLimit(values, entry) {
  return JSON.stringify(values.concat([entry])).length <= maxStateChars
}

function normalizeEntry(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { type: "text", text: value } : null

  if (!value || typeof value !== "object") return null

  var type = String(value.type || value.kind || "")
  if (type === "text") {
    var text = String(value.text || "")
    return text.trim().length > 0 && text.length <= maxTextChars ? { type: "text", text: text, pinned: value.pinned === true } : null
  }

  if (type === "image") {
    var path = String(value.path || "")
    if (!path || path.length > 1024) return null
    var entry = {
      type: "image",
      path: path,
      mime: String(value.mime || "image/png"),
      pinned: value.pinned === true
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
      if (entry && withinStateLimit(next, entry)) next.push(entry)
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
  if (!withinStateLimit([], normalized)) return Array.isArray(history) ? history.slice(0, max) : []

  var key = entryKey(normalized)
  var values = Array.isArray(history) ? history : []
  for (var p = 0; p < values.length; p++) {
    var prior = normalizeEntry(values[p])
    if (prior && entryKey(prior) === key) normalized.pinned = prior.pinned
  }
  var next = [normalized]

  for (var j = 0; j < values.length && next.length < max; j++) {
    var pinned = normalizeEntry(values[j])
    if (!pinned || !pinned.pinned || entryKey(pinned) === key) continue
    if (withinStateLimit(next, pinned)) next.push(pinned)
  }

  for (var i = 0; i < values.length && next.length < max; i++) {
    var existing = normalizeEntry(values[i])
    if (!existing || existing.pinned || entryKey(existing) === key) continue
    if (withinStateLimit(next, existing)) next.push(existing)
  }

  return next
}

function togglePinAt(history, index) {
  var next = Array.isArray(history) ? history.slice() : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= next.length) return next
  var entry = normalizeEntry(next[target])
  if (!entry) return next
  entry.pinned = !entry.pinned
  next[target] = entry
  next.sort(function(a, b) { return Number(Boolean(b.pinned)) - Number(Boolean(a.pinned)) })
  return next
}

function movePinnedAt(history, index, direction) {
  var next = Array.isArray(history) ? history.slice() : []
  var target = Number(index)
  var step = Number(direction) < 0 ? -1 : 1
  if (isNaN(target) || target < 0 || target >= next.length) return next
  var entry = normalizeEntry(next[target])
  if (!entry || !entry.pinned) return next

  for (var i = target + step; i >= 0 && i < next.length; i += step) {
    var neighbor = normalizeEntry(next[i])
    if (!neighbor || !neighbor.pinned) continue
    var swap = next[target]
    next[target] = next[i]
    next[i] = swap
    break
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
  return { type: "text", text: entry.text.slice(0, cut > 0 ? cut : displayTextLimit), pinned: entry.pinned === true }
}

function displayRows(history, query, limit) {
  var values = Array.isArray(history) ? history : []
  var needle = String(query || "").trim().toLowerCase()
  var max = limit === undefined || limit === null ? 50 : Number(limit)
  if (isNaN(max)) max = 50
  max = Math.max(0, max)
  if (max === 0) return []

  var pinnedRows = []
  var historyRows = []

  for (var i = 0; i < values.length; i++) {
    var entry = cappedEntry(normalizeEntry(values[i]))
    if (!entry) continue
    if (needle && searchableText(entry).toLowerCase().indexOf(needle) < 0) continue

    var paths = filePaths(entry)
    var isFile = paths.length > 0
    var isImage = entry.type === "image"
    var previewPath = isImage ? String(entry.path || "") : (isFile && paths.length === 1 && isImagePath(paths[0]) ? paths[0] : "")
    var row = {
      entryType: isFile ? "file" : entry.type,
      fullText: isImage ? "" : fullText(entry),
      previewText: previewText(entry),
      previewImage: previewPath,
      path: isImage ? String(entry.path || "") : (isFile && paths.length === 1 ? paths[0] : ""),
      mime: isImage ? String(entry.mime || "image/png") : "text/plain",
      index: i,
      pinned: entry.pinned === true
    }
    if (entry.pinned) pinnedRows.push(row)
    else historyRows.push(row)
    if (pinnedRows.length + historyRows.length >= max) break
  }

  var rows = []
  if (pinnedRows.length) {
    rows.push({ entryType: "section", previewText: "📌  Pinned", fullText: "", previewImage: "", path: "", mime: "", index: -1, pinned: false })
    rows = rows.concat(pinnedRows)
  }
  if (historyRows.length) {
    rows.push({ entryType: "section", previewText: "History", fullText: "", previewImage: "", path: "", mime: "", index: -1, pinned: false })
    rows = rows.concat(historyRows)
  }
  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeEntry: normalizeEntry,
    entryKey: entryKey,
    parseHistory: parseHistory,
    addEntry: addEntry,
    removeEntryAt: removeEntryAt,
    togglePinAt: togglePinAt,
    movePinnedAt: movePinnedAt,
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
