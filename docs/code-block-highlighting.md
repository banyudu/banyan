# Code block highlighting

`CodeBlockView` is the single native renderer for assistant Markdown fences,
Codex output, and Puck tool details. It provides:

- Optional language metadata and a small language label.
- Copy-to-clipboard and selectable text.
- Horizontal and vertical scrolling for the bounded preview.
- Expand/collapse when content exceeds the preview heuristic.
- A plain-text fallback before highlighting finishes, for unknown languages,
  and for oversized input.

The Markdown parser keeps a fence's full info string as its language metadata.
`CodeBlockLanguage` then normalizes the first token, leading dots/braces, and
common aliases such as `js`, `tsx`, `zsh`, `yml`, `patch`, and `language-html`.

## Splash spike

The evaluation started with `JohnSundell/Splash`, pinned at
`2e3f17c2d09689c8bf175c4a84ff7f2ad3353301` (2022-06-08). On this machine:

- The `Splash` source target is 132 KB, with no transitive SwiftPM packages and
  no JavaScript runtime.
- A release build produced a 292 KB `libSplash.a` and a 282 KB `Splash.o`.
- A clean release build completed in 6.8 seconds (10.2 seconds wall time).
- Its attributed-string output is backed by `NSAttributedString`, and its
  current package emits a Swift 6 default-argument warning because `AppKit` is
  not imported in `Theme.swift`.
- The package ships only a Swift grammar. Covering the other languages shown in
  chat output would require custom grammars or a second dependency.

Splash was therefore not adopted. The incremental binary cost would have been
several hundred kilobytes plus a new pinned dependency for one language, while
the shared code block needs cheap coverage across common output types. The
chosen implementation is a first-party tokenizer with no additional binary or
package dependency. The syntax policy and static rules occupy 367 lines; the
shared view and cache occupy another 241 lines.

## Highlighting policy

The first-party highlighter recognizes Swift, JavaScript/TypeScript, JSON,
Python, shell, SQL, YAML, diff, and markup. Unknown or missing languages stay as
plain monospaced text.

Highlighting is deliberately bounded:

- At most 40,000 characters and 2,000 lines are tokenized. Larger input stays
  plain, including the 64 KB Codex output budget edge case.
- Tokenization runs in an actor off the SwiftUI render path and caches the last
  64 text+language results.
- A stale result is never displayed after its text or language changes.
- The initial render and the fallback path use plain `Text`, so the main thread
  does not build an attributed string for large output.

The collapsed preview is capped at 220 points (180 in Puck tool details). Code
with more than 12 lines or 900 characters exposes the expand action; expanded
code grows into the surrounding transcript scroll view while retaining
horizontal scrolling.

## Tests

`Tests/BanyanTests/CodeBlockSyntaxTests.swift` covers alias normalization,
unknown/missing fallback, semantic token spans, the size cutoff, and Markdown
fenced-code language parsing. The shared view itself is exercised through the
existing Codex and Puck transcript UI tests.
