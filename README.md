# Gloss

**English** · [简体中文](README.zh-CN.md)

Gloss is a macOS menu bar app that translates the sentence you are typing, in any app, and shows it in a small bubble right below your cursor. Write in your native language to see how to say it in the language you're learning; write in the language you're learning to get it polished. New words are collected along the way so you can review them later.

The name comes from the old practice of writing *glosses* — small translations and notes between the lines of a text. Its Chinese name, 字里行间, means "between the lines".

## Features

- **Works in any text field.** Gloss reads the sentence at your cursor through the macOS Accessibility API, so it works in chat apps, mail, browsers, and editors without plugins.
- **Translates only the current sentence.** It waits for a short pause (0.6 s by default), skips half-typed pinyin, and ignores password fields.
- **Translate or polish.** Writing in your native language gives a translation. Writing in the language you're learning gives a more natural version, with deletions struck through and additions underlined.
- **Streams as it's generated.** The translation types itself out word by word, with a glowing border while it waits.
- **Replace with one shortcut.** Press ⌃⌥E, or click the replace button on the bubble, to swap your sentence for the translation.
- **Reads aloud.** Uses the built-in macOS voices, either with a shortcut (⌃⌥S) or automatically when a translation appears.
- **Learns your vocabulary.** The model picks 0–3 words worth learning, based on your level. Words you have seen fewer than three times get an orange dot, and right-clicking a word marks it as known. You can export everything to Anki.
- **Bring your own model.** Works with any OpenAI-compatible API: DeepSeek, Zhipu GLM, Qwen, Kimi, OpenAI, and others. Add, edit, and switch models in Settings.
- **Seven languages.** Chinese, English, Japanese, Korean, Spanish, French, and German, as both the languages you translate between and the app's interface language.

## Requirements

- macOS 13 Ventura or later, Apple silicon
- An API key for an OpenAI-compatible model service
- Accessibility permission, so Gloss can read and replace text in other apps

## Build

There is no Xcode project. The build script compiles the sources with `swiftc` and signs the app:

```bash
./scripts/build.sh
```

The app is written to `dist/Gloss.app`, and the build ends with a self-test. By default it signs with a fixed certificate, so the Accessibility permission survives rebuilds. To use your own certificate:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" ./scripts/build.sh
```

## First run

1. Open `dist/Gloss.app`. The 文/A icon appears in the menu bar.
2. When macOS asks, allow Gloss in **System Settings → Privacy & Security → Accessibility**.
3. Open **Settings… (⌘,) → Model**, edit a model or add a new one, and enter your API key.
4. In **Languages**, choose your native language, the language you're learning, and your level.
5. Start typing anywhere.

If the menu bar is too crowded to show the icon, open Gloss again from Spotlight to bring up Settings.

## Using it

| Action | How |
| --- | --- |
| Replace the sentence with the translation | ⌃⌥E, or the ↩ button that appears when you hover over the bubble |
| Read the translation aloud | ⌃⌥S, or the speaker button |
| Copy the translation | The copy button |
| Hear a single word | Click the word |
| Mark a word as known | Right-click the word |
| Hide the bubble | Esc, sending the message with Return, or waiting 15 s |
| Turn Gloss off | The switch at the top of the menu (the icon turns gray) |

You can change both shortcuts in **Settings → Shortcuts** by clicking a shortcut and pressing a new combination.

## Settings

| Tab | What's there |
| --- | --- |
| General | Interface language, on/off, Open at Login, polishing, streaming, pause before translating, auto-hide delay |
| Languages | Native language, language you're learning, your level (CEFR A1–C2) |
| Model | List of models, switch the active one, add, edit, and delete; extra request parameters under *Advanced* |
| Read aloud | Off, with shortcut, or automatic; voice, speed, and preview |
| Shortcuts | Replace and read-aloud shortcuts |
| Appearance | Glow colors: Aurora, Ocean, Sunset, Mono |

Everything is stored in `~/Library/Application Support/LiveTranslate/config.json`, which you can also edit by hand. The file contains your API keys and is created with `600` permissions.

### Extra parameters

Some model services can "think" before answering, which makes translations slower. In **Model → Edit → Advanced**, you can add parameters that are merged into every request. For example:

- DeepSeek: `{"reasoning_effort":"none"}`
- Zhipu GLM: `{"thinking":{"type":"disabled"}}`

If a service rejects them, Gloss retries once without them. With thinking turned off, DeepSeek usually takes about 1.4 s per sentence; with it on, about 2.8 s.

## Vocabulary and Anki

Words are saved per language in `~/Library/Application Support/LiveTranslate/vocab-<language>.json`. A word counts as seen once each time you finish a sentence, not on every pause.

**Export words to Anki** in the menu writes a tab-separated file to your Downloads folder. In Anki, choose **File → Import** and pick that file. Each card has the word on the front. The back shows its meaning, the sentence you actually wrote, and its translation. Anki matches notes by their front side, so with the default import options, importing again updates existing cards instead of duplicating them.

## Privacy

- The sentence at your cursor is sent only to the model service you configured. Gloss has no server of its own.
- Password fields are always skipped.
- API keys stay in your local config file.

## Known limitations

- **Terminals built on web technology** (such as Orca and other xterm.js-based terminals) don't expose the line you're typing. Gloss only sees fragments there, so translations may be incomplete.
- In a few Electron and Chromium apps, selecting text through Accessibility doesn't work. Gloss then falls back to selecting with ⇧← and pasting.
- Only Apple silicon builds are produced.

## Project layout

```
Sources/
  main.swift                  App delegate, main loop, menu, self-test, --demo mode
  Accessibility.swift         Reading the focused field, caret position, replacing text
  Sentence.swift              Finding the sentence at the cursor, pinyin detection
  Language.swift              Supported languages and language detection
  LLMClient.swift             OpenAI-compatible client, streaming (SSE), prompts
  Overlay.swift               The bubble: glow, streaming text, hover toolbar, word chips
  Diff.swift                  Word-level diff for polished sentences
  Settings.swift              Settings window (SwiftUI)
  Localization*.swift         Interface strings in seven languages
  Vocab.swift / Speech.swift  Vocabulary store and text-to-speech
assets/AppIcon-1024.png       App icon source (the build turns it into AppIcon.icns)
scripts/build.sh              Build, sign, and self-test
```

To preview the bubble without typing anywhere, run `dist/Gloss.app/Contents/MacOS/Gloss --demo <waiting|streaming|refreshing|done|polish> [aurora|ocean|sunset|mono] [--light]`.
