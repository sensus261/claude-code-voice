// Markdown parser test: swiftc -swift-version 5 Sources/{Speaker,Store,Markdown}.swift tests/markdown/main.swift
import Foundation

let sample = """
## Result
Fixed **two** bugs in `auth.ts` → tests pass. See [the docs](https://x.com) e.g. here.

- First item with `code`
  continued on the next line.
- Second item
  1. Nested numbered

| File | Status |
|---|---|
| a.ts | **done** |
| b.ts | ~5 min |

> A quoted note.

```swift
let x = 1
```

---
Want me to ship it?
"""

let doc = ReplyDoc.parse(sample)
for b in doc.blocks {
    print("block \(b.id): \(b.kind)  \(b.kind == .table ? "\(b.rows)" : b.plain)")
}
print("---")
for (i, s) in doc.spoken.enumerated() {
    let r = s.range.map { "\($0.location)+\($0.length)" } ?? "-"
    print("\(i): [block \(s.block) range \(r) row \(s.row.map(String.init) ?? "-")] \(s.text)")
}
