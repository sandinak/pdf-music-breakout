# pdf-music-breakout

Split a combined music PDF — the kind where every instrument's part is
concatenated into one "ALL" file — into one printable PDF per part.

It works out which pages belong to which part by reading the part name printed
in each page's header, so you don't have to hunt through the file counting
pages.

```
Abracadabra-ALL.pdf  (30 pages)
   ├── 03-Abracadabra-Score.pdf         6 pp
   ├── 03-Abracadabra-Piano.pdf         7 pp
   ├── 03-Abracadabra-Synth.pdf         2 pp
   ├── 03-Abracadabra-Guitar.pdf        2 pp
   ├── 03-Abracadabra-Bass_Guitar.pdf   1 pp
   ├── 03-Abracadabra-Clarinet1.pdf     1 pp
   └── … 15 parts in total
```

## Install

Any of these puts a `pdf-music-breakout` command on your PATH.

**Homebrew** — this repository doubles as its own tap, so there's no separate
tap repo to add:

```bash
brew tap sandinak/tap https://github.com/sandinak/pdf-music-breakout
brew install sandinak/tap/pdf-music-breakout
```

To upgrade later: `brew update && brew upgrade pdf-music-breakout`.

**uv** or **pipx**, straight from this repository:

```bash
uv tool install git+https://github.com/sandinak/pdf-music-breakout
# or
pipx install git+https://github.com/sandinak/pdf-music-breakout
```

**Windows** — two downloads on
[Releases](https://github.com/sandinak/pdf-music-breakout/releases/latest),
depending on what you want:

- `PDF Music Breakout Setup.exe` — the app, in its own window. Install it,
  then open a combined PDF with it.
- `pdf-music-breakout.exe` — the command on its own, a single file with
  Python and everything else already inside. Run it from a command prompt,
  or double-click it to open the review screen in your browser.

Neither needs Python installed.

**From a checkout**, for hacking on it:

```bash
git clone https://github.com/sandinak/pdf-music-breakout
cd pdf-music-breakout
make dev
```

Check it landed:

```bash
pdf-music-breakout --version
```

## The Mac app

There's a native macOS app — a real `.app` that lives in `/Applications`, not
a browser window. Download the signed build from
[Releases](https://github.com/sandinak/pdf-music-breakout/releases/latest) —
one universal binary for Apple Silicon and Intel, macOS 14 or later — or build
it from a checkout:

```bash
make app-install        # into /Applications
make app-run            # or just build and launch it
```

Open a combined PDF by dropping it on the window, double-clicking it in the
Finder, or dropping it on the Dock icon. What you get is a tree: one row per
part it found — named, with the file it would write and the pages it covers —
and the rest of that part's pages folded inside it. So the top level reads as
the list of files you are about to get, and anything odd stands out.

Fixing what detection got wrong is drag and drop. Drag a page's picture onto
the part it really belongs to; drag a whole part onto another to merge the
two; drop either onto *Front matter* to take it out of the parts entirely.
A page that should have begun a part of its own has a tick for that, and
every part can be renamed in place. The file list updates as you go, and
Reset puts every page back where detection had it.

Export (⌘S) writes one PDF per part into a folder you choose.

When a thumbnail is too small to tell a second trumpet part from a first,
open the preview window (⌥⌘P, or double-click a page). It sits beside the
main window and shows whichever page is selected there, big enough to read:
it fits the width by default, and zooms with ⌘+ / ⌘− , ⌘0 for actual size,
or a pinch. The part boundary and its name can be edited from that window
too, so a misread gets fixed while you are looking at the evidence.

| | |
|---|---|
| ⌘O | open a combined PDF |
| ⌘S | export the parts, into a folder you pick |
| ⌥⌘P | show the preview window |
| ⌘+ / ⌘− | zoom the preview in and out |
| ⌘0 / ⌘9 / ⌘8 | actual size / fit the page / fit its width |
| ← / → | previous and next page, in the preview window |
| ⇧⌘W | close the document and start again |

It is written in Swift against Apple's own PDFKit, so it carries **no Python
and no third-party dependencies at all** — nothing to install first, and none
of the licence constraints described below.

Its detection is a port of the Python one, and `make app-verify` builds a
harness that checks the two agree; they currently produce identical results
on every real file tested.

## The Windows app

The same review screen as the Mac app's — the tree of parts, drag and drop,
the readable page — in a window rather than a browser tab. Open a PDF from
the File menu or drop one on the window; ⌃O, ⌃S to export, arrow keys to page
through, ⌃+/⌃−/⌃0 to zoom.

Inside, it is a window around the splitter you already have: the same Python
that the command line and the browser UI use, started on a loopback port with
the window pointed at it. Nothing about detecting or splitting is
reimplemented in JavaScript, which is the point — the heuristics exist twice
already (Python, and the Swift port the Mac app uses, checked against each
other by `make app-check`), and a third copy is how they start giving
different answers for the same PDF.

To run it from a checkout:

```bash
make desktop                 # against the working tree
make desktop PDF=book.pdf    # with a book already open
make desktop-dist            # package it for this platform
```

## The review screen

Detection is right most of the time, but when it's wrong it is wrong
*quietly* — one real file turned 58 pages into 58 "parts" without
complaining. So there's a screen to check it on:

```bash
./.venv/bin/python pdf_music_breakout.py --serve
```

Running the command with no arguments at all does the same thing, which is
what a double-clicked `.exe` on Windows does.

Or open a book straight into it:

```bash
pdf-music-breakout Abracadabra-ALL.pdf --serve
```

You get the same tree the Mac app shows: one row per part, named, with the
file it will write and the pages it covers, and the rest of that part's pages
folded inside it. Beside it sits the selected page, big enough to read —
arrow keys to page through, `+`/`−`/`0` to zoom, or fit the width or the
page.

Fixing what detection got wrong is the same gesture too: drag a page's
picture onto the part it really belongs to, drag a part onto another to merge
them, or drop either onto *Front matter* to leave it out. A page that should
have started a part of its own has a tick for that, and every part can be
renamed in place. The list of files updates as you go. Export as a `.zip`, or
type a folder path to write straight into your show directory.

It runs entirely on your machine — bound to localhost, nothing uploaded
anywhere, and nothing written to disk until you ask.

## Use from the command line

Look before you leap — this shows what it found without writing anything:

```bash
./.venv/bin/python pdf_music_breakout.py Abracadabra-ALL.pdf --list
```

Then split, into a folder named for the chart:

```bash
./.venv/bin/python pdf_music_breakout.py Abracadabra-ALL.pdf \
    -o "Shows/26-27 Dance Hysteria/Music/03-Abracadabra"
```

Because that folder starts with `03-`, the files come out as
`03-Abracadabra-Piano.pdf` and so on. Use `--prefix` to set it yourself or
`--prefix none` to drop it.

## How parts are detected

Three sources, most trusted first:

1. **`--map`** — page ranges you give it explicitly.
2. **Bookmarks** — the PDF outline, when it has one that names instruments.
3. **Page headers** — the part name printed at the top of each page.

Header detection joins each text *line* before matching, because a label like
`Clarinet in Bb 1` is usually split across several spans (the flat sign comes
from a notation font, sometimes as a private-use codepoint that isn't a
character at all). It then discards the song title, page numbers, bar numbers,
tempo marks, the arranger credit and licence boilerplate — the last of these
found automatically, as header text repeated across most of the document that
isn't an instrument name.

What survives is scored: a known instrument name is worth most, then sitting
in the outer page margin, then being on the topmost header row. Pages with no
label continue the part above them, which is exactly what continuation pages
look like in a real score.

Two cases that came out of testing against real files, both handled:

- **Running heads.** A book assembled by merging per-part exports often stamps
  `Song - Alto Sax - p.2` on every page, so each page looks like a new part.
  The song title and page marker are stripped to recover `Alto Sax`.
- **Junk metadata.** Conversion tools write titles like
  `Merged with PDFCreator Online` into the PDF. The printed page wins over the
  metadata, and known tool names are ignored outright.

If detection produces about as many parts as there are pages, it says so
rather than quietly writing a hundred one-page files.

If it gets something wrong, `--verbose` shows the reasoning page by page, and
`--map` overrides it entirely:

```bash
pdf_music_breakout.py book.pdf -o out \
    --map "2-7=Full Score" --map "8-14=Piano/Vocal"
```

Scanned PDFs have no text to read. Run OCR first, or use `--map`.

## Page size

By default (`--paper auto`) the target is whichever size most of the document
already uses. Pages that already fit are **copied through untouched**, so they
keep their original quality; only oversized pages are rotated and scaled.

In practice that means a conductor score engraved on tabloid gets turned onto
letter alongside the parts, while the parts themselves are byte-for-byte
identical to the source.

- `--paper keep` — leave every page exactly as it is.
- `--paper letter|a4|tabloid|…` or `--paper 11x17in` — pick the target.
- `--rotate cw|ccw|auto|none` — which way to turn an oversized landscape page.
- `--margin 12` — inset when fitting, in points. Defaults to 0.
- `--force-fit` — re-fit every page, not just the oversized ones.

## Naming

`Clarinet in Bb 1` becomes `Clarinet1`; `Alto Saxophone` becomes `Alto_Sax`;
`Full Score` becomes `Score`. Adjust any of it:

```bash
--rename "Drum Set=Kit"              # one-off
--aliases my-names.json              # {"printed label": "output name"}
--template "{prefix}{title}-{part}.pdf"
```

## Front matter

A cover or copyright page before the first part is skipped by default.
`--front-matter attach` prepends it to every part instead, which is what you
want when a licensed arrangement requires the notice to travel with the music.

## Other options

| | |
|---|---|
| `--only NAME` / `--exclude NAME` | write a subset (substring match, repeatable) |
| `-n`, `--dry-run` | report the split without writing |
| `--manifest FILE` | also write a JSON record of the split |
| `--overwrite` | replace existing files |
| `--header-band F` | fraction of page height searched for the label (default 0.15) |

Full list: `pdf_music_breakout.py --help`

## Development

`make` on its own lists every target. The ones you'll want:

| | |
|---|---|
| `make dev` | create the virtualenv and install in editable mode |
| `make test` | run the test suite |
| `make serve` | run the review UI from the working tree |
| `make split PDF=x.pdf` | split a file without installing (add `OUT=dir` to write) |
| `make app` | build the native Mac app |
| `make app-install` | build it and install into /Applications |
| `make app-dist` | build it signed with your Developer ID, and zip it |
| `make app-notarize` | that, then send it to Apple to be notarised |
| `make app-verify` | build the harness that compares the app with the CLI |
| `make app-check` | split a generated book with both, and diff the results |
| `make exe` | build a standalone executable (no Python needed to run it) |
| `make desktop` | run the desktop shell from the working tree (`PDF=` to open one) |
| `make desktop-dist` | package the desktop app for this platform |
| `make sample` | write a synthetic combined book to try things on |
| `make install` | put it on PATH with uv or pipx |
| `make brew-install` | tap this repo and install through Homebrew |
| `make release VERSION=x.y.z` | bump, tag, push, and repoint the formula |
| `make clean` | remove build artefacts |

The virtualenv rebuilds itself whenever `pyproject.toml` changes, so `make
test` is always enough on its own.

Every push runs the suite on Linux, macOS and Windows against Python 3.10 and
3.13, builds the Windows executable and splits a book with it, packages the
Windows app, and checks the Mac app and the CLI still agree — that last one is not ceremony, it caught the
app reading a page number as part of an instrument's name.

### Tests

64 of them. They build synthetic PDFs shaped like real engraver output and
check detection, naming, page fitting, the CLI, and the review UI (which runs
a real server on a loopback port and is driven the way the page drives it).

Several tests exist because a real file broke the tool in that exact way;
those are marked as regressions in their docstrings.

### Cutting a release

`make release VERSION=0.1.2` bumps `__version__`, runs the tests, tags and
pushes, waits for GitHub to build the tag tarball, then rewrites the
formula's URL and `sha256` and pushes that too. It refuses to start on a
dirty tree, and refuses entirely if you don't name a version.

It bumps the desktop shell's version to match, then builds the Mac app as a
universal binary, signs it with the Developer ID certificate in your
keychain, and attaches the `.zip` to the GitHub release. CI adds the Windows
executable and installer to the same release when the tag lands. If it can find notarisation credentials it notarises and staples the
app first, so the download opens without a Gatekeeper warning — otherwise it
still attaches the signed build and says so.

Credentials come from either a notarytool keychain profile called
`pdf-music-breakout`, or `APPLE_ID` / `APPLE_TEAM_ID` /
`APPLE_APP_SPECIFIC_PASSWORD` in the environment. Set the profile up once
with:

```bash
xcrun notarytool store-credentials pdf-music-breakout \
    --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
```

## Licence

AGPL-3.0-or-later.

For the Python CLI this is not a free choice: it reads and writes PDFs with
[PyMuPDF](https://pymupdf.readthedocs.io/), which is dual-licensed AGPL-3.0 or
paid-commercial by Artifex. Anything distributed that links it must be AGPL
too — which also rules out shipping it as a closed-source or paid app, since
the Mac App Store does not get along with AGPL terms.

**The Mac app is not affected.** It uses Apple's PDFKit and links nothing
third-party, so it carries no such constraint. That was a deliberate reason
to write it in Swift rather than wrap the Python: the app can be handed to
someone as a signed download — which is how it now ships — without dragging
the AGPL along, and an iPad version would be clear of the problem too.
