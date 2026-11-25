# 阅读 · Personal EPUB Reader for iPad

A personal iPad EPUB reader built in SwiftUI. It does two things Apple Books doesn't:

- **Your own fonts**: import `.ttf` / `.otf` / `.ttc` files (e.g. LXGW WenKai), set separate CJK and Latin fonts, and adjust size, line height, letter spacing, paragraph spacing, margins and themes.
- **Ask AI about a passage**: select text → "问 AI / 解释 / 翻译" → a streaming chat panel backed by any OpenAI-compatible API (base URL, model and key set in-app; key stored in the Keychain).

## Build

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open Reader.xcodeproj
```

`TestBooks/make_test_epub.py` generates a small Chinese/English EPUB for testing.
