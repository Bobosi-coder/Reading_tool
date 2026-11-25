# Dive in

A personal EPUB reader for iPad, built in SwiftUI. It does two things Apple Books doesn't:

- **Your own fonts**: separate fonts for Chinese and Latin text, with a curated set bundled (LXGW WenKai, LXGW Neo ZhiSong, Literata, EB Garamond) plus Apple's New York, Charter and others. Import any `.ttf` / `.otf` / `.ttc` (e.g. your own copy of Bookerly). Size, line height, letter and paragraph spacing, margins and four themes are adjustable.
- **Ask AI about a passage**: select text → **问 AI** (what does this mean?) or **译 · 释** (translate + explain words, grammar and background). Answers stream into a side panel with follow-up chips, using any OpenAI-compatible API (base URL, model and key set in-app; key stored in the Keychain).

Also: page-curl / slide page turns, reading-position memory, TOC, and drag-and-drop import of books and fonts via Finder file sharing.

## Build

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open Reader.xcodeproj
```

- `TestBooks/make_test_epub.py` generates a small Chinese/English EPUB for testing.
- `Design/make_icon.swift` renders the app icon: `xcrun swift Design/make_icon.swift Reader/Assets.xcassets/AppIcon.appiconset/icon.png`

## Font licenses

Bundled fonts are redistributed under their own licenses (see `Licenses/`):
LXGW WenKai, Literata and EB Garamond under the SIL Open Font License 1.1; LXGW Neo ZhiSong under the IPA Font License.
