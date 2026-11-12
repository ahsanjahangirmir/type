# Type

A calm, distraction-free Markdown writing app for macOS 26, built natively in SwiftUI + AppKit with Liquid Glass chrome. Its feature set is modeled on Calmly Writer.

## Features

- **Notebooks & pages**: a sidebar of notebooks with each notebook's pages listed beneath it, next to the editor, with the page outline in a right-hand inspector. A notebook is a folder and a page is a Markdown file in your library folder (default `~/Documents/Type`, changeable in Settings ▸ General). Pages save automatically; if another app changes the file while you have unsaved edits, your version is kept and the other one is saved beside it as “<name> (conflict <date>)”. A page is named after its first heading, like OneNote, and its file is renamed to match when you leave the page. Create a page with ⌘N and a notebook with ⇧⌘N; double-click to rename (renaming a page rewrites its heading); drag a page onto a notebook to move it (its images come along); Duplicate, Show in Finder and Move to Trash are in the context menu. Hide the sidebar to focus on the page with the toolbar's sidebar button or ⌃⌘S. Open more library windows with ⌥⌘N or as native tabs.
- **Images**: paste a screenshot (⌘V) or drop image files. They're saved next to the page (`<Notebook>/.assets/`) and shown inline with rounded corners. Drag the edge or corner handle to resize; double-click to open in Preview; the right-click menu has Actual Size, Fit Width, Copy, Show in Finder and Delete. The width is stored as `![alt](path "width=480")`, which stays valid Markdown.
- **What you see is what you get**: pages are stored as plain Markdown, but the editor never shows or interprets Markdown syntax. Headings, bold/italic, strikethrough, highlight, inline and fenced code, links (⌘-click to open), images, quotes, nested lists, checklists, tables and dividers are drawn formatted; bullets become •, checklists become clickable checkboxes, quotes get an accent bar and dividers become hairlines. Characters you type are always literal: `#`, `*`, `- `, `7. ` or `==` stay text (they're saved as Markdown escapes such as `\*`), so structure comes only from the slash menu, the toolbar and shortcuts. Typing at the end of formatted text continues the formatting, and spaces or Return there never expose markers. Plain text pasted from other apps is literal; copying inside Type keeps formatting, and copying to other apps gives clean text.
- **Formatting that nests cleanly**: ⌘B, ⌘I, strikethrough, highlight and code toggle on and off without exposing Markdown. They work per line and per table cell, never wrap a heading or list prefix, merge with or split existing formatting, and work inside words (`I*ncome*`). With nothing selected they apply to the next text you type, like a word processor.
- **Smooth typing** (Settings ▸ Typography ▸ Cursor): the caret glides to each new position, typed letters fade in and deleted letters fade out. The caret is always the height of the text, whatever the line spacing. Turned off when Reduce Motion is on.
- **Images and dividers are single objects**: the caret steps over them, typing next to one starts a new line, and Backspace after one selects it (a second Backspace deletes it).
- **Links** (⌘K): a popover to add, edit or remove the link at the selection.
- **Focus mode** (⇧⌘F): dims everything except the current paragraph, with adjustable opacity.
- **Typewriter scrolling** (⌃⌘T): keeps the caret line vertically centered.
- **Typing sounds** (⌥⌘S): six synthesized profiles (Mechanical, Typewriter with a return bell, Soft Keys, Thock, Clicky, Bubble), each with distinct key, space, return and delete sounds. Pick and preview them in Settings ▸ Sound, in View ▸ Typing Sound, or by holding the toolbar speaker button.
- **Smart typing**: curly quotes, `--` → —, `...` → …, `->` → →, `=>` → ⇒, `<-` → ←, optional auto-capitalization. Turned off inside code and comments.
- **Lists**: indented from the body text with hanging wrapped lines; each nesting level steps in further. Return continues bullets, numbers and checklists (with renumbering), Return on an empty item ends the list, Tab/⇧Tab indent.
- **Slash menu**: type `/` on an empty line to insert headings, lists, checklists, quotes, code blocks, tables, images, dividers, comments or today's date. Select some text and type `/` for the **Format menu**: Text (clears formatting), Bold, Italic, Strikethrough, Highlight, Inline Code, Link, headings, quote and lists, with checkmarks on formats the selection already has. Type to filter, ↑/↓ and Return to apply, Esc to close. Near the bottom of the window either menu opens above the text.
- **Tables**: shown as a grid with aligned columns, rows of any length line up. Tab / ⇧Tab move between cells, Return adds a row (Return on an empty last row ends the table), and the right-click Table menu inserts or deletes rows and columns.
- **Comments**: `<!-- … -->` shows as a tinted private note and is left out of counts and exports.
- **Statistics** (⌃⌘W to show or hide): a glass pill with word, character and reading-time counts, and a popover with full stats.
- **Writing goals**: a progress ring and a celebration toast when you reach the goal (saved per page).
- **Outline**: a heading list in the right-hand inspector (⌥⌘O, also in View ▸ Outline, so it works while the toolbar is hidden); click a heading to jump to it.
- **Glass toolbar**: formatting, insert, focus/typewriter/sound toggles and export. It hides while you type and comes back when you move the mouse.
- **Standalone documents**: Markdown and text files opened from Finder (or File ▸ New Standalone Document, ⌃⌘N) use the native macOS document model, so you get Open Recent, autosave, **Versions** (File ▸ Revert To ▸ Browse All Versions), Duplicate, Rename and crash recovery.
- **Open**: Markdown, plain text, RTF and Word (.docx). Rich text is converted to Markdown.
- **Export**: PDF, HTML, Word, RTF, Markdown and plain text. PDF and printing are laid out by WebKit with a print stylesheet (0.75 in margins; quotes, code blocks, tables and checklists keep their styling). Print with ⌘P.
- **Customization**: New York / SF Pro / SF Rounded / SF Mono or any installed font, size, line height, paragraph spacing, text width, writing direction (including RTL), caret color, hidden caret, selection color (preset tints or any custom color, in Settings ▸ Typography ▸ Selection), Paper/Sepia/Slate backgrounds, Light/Dark/System appearance, and zoom (⌘= ⌘- ⌘0).

## Build

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Type.xcodeproj -scheme Type -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Type.app
```

Run the tests with `xcodebuild -project Type.xcodeproj -scheme Type -derivedDataPath build test`. The app that hosts the tests uses a temporary library and never saves preferences, so running them can't touch your notes.
To also render the editor to PNGs for a visual check, add `TEST_RUNNER_TYPE_SNAPSHOT_DIR=/some/dir` in front of that command.

The app icon is generated by `swift scripts/make-icon.swift <dir>`.

## Layout

```
Type/
  App/        App entry, settings store, menu commands, debug snapshot hook
  Document/   FileDocument + RTF/DOCX → Markdown importer
  Editor/     TypeTextView (TextKit 1), Markdown styler, hidden-syntax glyphs, image blocks, controller, sounds, stats
  Library/    Notebook library store, page model (autosave), folder watcher, three-column window
  Export/     Markdown → HTML renderer, exporter (PDF/HTML/DOCX/RTF/MD/TXT/print)
  UI/         Shared editor pane + toolbar, standalone document window, glass components, settings
TypeTests/    Smart typing, lists, formatting, hidden syntax, library, images, sounds, export round-trips, visual renders
```
