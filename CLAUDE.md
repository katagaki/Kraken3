# CLAUDE.md

## Code Style

- Do NOT write code comments, except to explain gotchas, hacks, or workarounds.

## Client UI

- Do NOT allow text selection in the client UI under any circumstance, unless the element is explicitly a text field (e.g. input, textarea).
- Do NOT use `cursor: pointer` on any client UI components.

## Platform Support

- Kraken is optimized for mobile. Desktop should still work, but with limited support - do not compromise the mobile experience for desktop features.
