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

### A double-clickable app

For the people who will never open a terminal, build a launcher that opens
the review screen:

```bash
make app                        # into ~/Applications
make app APP_DEST=/Applications # or system-wide
```

Installed via Homebrew there's no checkout to run `make` in, so the same
builder ships alongside it:

```bash
$(brew --prefix)/share/pdf-music-breakout/make-app.sh
```

The app is a thin wrapper around `pdf-music-breakout --serve`, so install the
command first. It finds the command even though the Finder launches apps with
a bare PATH.

## The review screen

Detection is right most of the time, but when it's wrong it is wrong
*quietly* — one real file turned 58 pages into 58 "parts" without
complaining. So there's a screen to check it on:

```bash
./.venv/bin/python pdf_music_breakout.py --serve
```

That opens a page in your browser. Drop a combined PDF on it and you get a
thumbnail of every page, showing where each part was detected to begin. A
ticked page starts a part; untick one that isn't really a new part, tick one
that was missed, and rename anything that came out wrong. The list of files
updates as you go. Export as a `.zip`, or type a folder path to write
straight into your show directory.

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
| `make app` | build the macOS launcher |
| `make install` | put it on PATH with uv or pipx |
| `make brew-install` | tap this repo and install through Homebrew |
| `make release VERSION=x.y.z` | bump, tag, push, and repoint the formula |
| `make clean` | remove build artefacts |

The virtualenv rebuilds itself whenever `pyproject.toml` changes, so `make
test` is always enough on its own.

### Tests

61 of them. They build synthetic PDFs shaped like real engraver output and
check detection, naming, page fitting, the CLI, and the review UI (which runs
a real server on a loopback port and is driven the way the page drives it).

Several tests exist because a real file broke the tool in that exact way;
those are marked as regressions in their docstrings.

### Cutting a release

`make release VERSION=0.1.2` bumps `__version__`, runs the tests, tags and
pushes, waits for GitHub to build the tag tarball, then rewrites the
formula's URL and `sha256` and pushes that too. It refuses to start on a
dirty tree, and refuses entirely if you don't name a version.

## Licence

AGPL-3.0-or-later.

This is not a free choice: the tool reads and writes PDFs with
[PyMuPDF](https://pymupdf.readthedocs.io/), which is dual-licensed AGPL-3.0 or
paid-commercial by Artifex. Anything distributed that links it must be AGPL
too.

That matters if you ever want to ship this as a closed-source or paid app —
the Mac App Store in particular does not get along with AGPL terms. Two ways
out, should it come to that:

- Swap the PDF layer for a permissive stack: `pypdf` (BSD) for writing pages
  plus `pdfminer.six` (MIT) for positioned text extraction.
- On Apple platforms, use PDFKit, which does all of this natively with no
  third-party licence at all.

Neither affects using or sharing the tool as it stands.
