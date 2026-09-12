function empty() {
  return { offset: 0, pending: "" }
}

function consume(state, text, byteLength, maxBytes, maxLineChars) {
  var source = String(text || "")
  var current = state && state.offset <= source.length ? state : empty()
  if (Number(byteLength) > Number(maxBytes))
    return { state: current, lines: [], overflow: true }

  var combined = current.pending + source.slice(current.offset)
  var parts = combined.split("\n")
  var pending = parts.pop()
  if (pending.length > maxLineChars)
    return { state: current, lines: [], overflow: true }
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].length > maxLineChars)
      return { state: current, lines: [], overflow: true }
  }
  return {
    state: { offset: source.length, pending: pending },
    lines: parts,
    overflow: false
  }
}

if (typeof module !== "undefined") module.exports = { empty: empty, consume: consume }
