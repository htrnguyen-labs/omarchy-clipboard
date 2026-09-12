const assert = require("assert")

let Guard
try {
  Guard = require("./StreamGuard.js")
} catch (_) {
  assert.fail("StreamGuard is required")
}

let state = Guard.empty()
let result = Guard.consume(state, "one\ntw", 6, 32, 8)
assert.deepStrictEqual(result.lines, ["one"])
assert.strictEqual(result.overflow, false)

result = Guard.consume(result.state, "one\ntwo\n", 8, 32, 8)
assert.deepStrictEqual(result.lines, ["two"])
assert.strictEqual(result.overflow, false)

result = Guard.consume(Guard.empty(), "unterminated", 12, 32, 8)
assert.strictEqual(result.overflow, true)

result = Guard.consume(Guard.empty(), "x", 33, 32, 64)
assert.strictEqual(result.overflow, true)
