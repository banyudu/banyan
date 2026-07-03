# Banyan Agent Instructions

- Prefer native SwiftUI controls, toolbar items, window styling, and layout APIs for the macOS app. Avoid custom AppKit titlebar/accessory replacements unless there is no native SwiftUI path and the tradeoff is explicitly accepted.
- When spawning child terminals or coding-agent sessions while working on Banyan, use Banyan-native commands such as `banyanctl session new` or `banyanctl agent run`. Do not depend on personal `agent-run`/iTerm helper skills unless the user explicitly asks for that external workflow.
