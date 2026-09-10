#!/usr/bin/env python3
"""
pdf-music-breakout -- split a combined music PDF into one printable PDF per part.

Reads a PDF that contains every instrument's part concatenated together (the
kind of "ALL" file an arranger or a service like Tresona hands you), works out
which pages belong to which part by reading the part name printed in each
page's header, and writes one PDF per instrument.

Detection is layered, most trusted first:

  1. --map / --rename  ... explicit page ranges you supply.
  2. PDF bookmarks     ... used when the file has a usable outline.
  3. Header text       ... the part name printed at the top of each page.

Header detection joins each text *line* (a part name like "Clarinet in Bb 1"
is often split across spans because the flat sign lives in a music font),
throws away the title, page numbers, credits and licence boilerplate, then
keeps whatever matches a known instrument name or sits alone in the outer
margin of the topmost header row.

Pages with no label continue the previous part, which is what continuation
pages in real scores look like.
"""

from __future__ import annotations

__version__ = "0.1.1"

import argparse
import json
import re
import sys
import unicodedata
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

try:
    import pymupdf
except ImportError:  # pymupdf < 1.24 only exposed the legacy name
    try:
        import fitz as pymupdf
    except ImportError:
        sys.exit(
            "pdf-music-breakout needs PyMuPDF.\n"
            "  python3 -m venv .venv && ./.venv/bin/pip install pymupdf"
        )


# --------------------------------------------------------------------------
# Paper sizes, in PDF points (72/inch)
# --------------------------------------------------------------------------

PAPERS = {
    "letter": (612.0, 792.0),
    "legal": (612.0, 1008.0),
    "tabloid": (792.0, 1224.0),
    "ledger": (1224.0, 792.0),
    "a3": (841.89, 1190.55),
    "a4": (595.28, 841.89),
    "a5": (419.53, 595.28),
}

# Fonts that carry notation glyphs rather than words. Text set in these is
# music, not a label, so it never contributes to a part name on its own.
MUSIC_FONT_RE = re.compile(
    r"(?i)(opus|maestro|petrucci|engraver|emmentaler|feta|bravura|petaluma"
    r"|leland|mscore|sonata|jazz|finale|november|gonville|ekmel|steinberg)"
)

# Header lines that are never a part name.
BOILERPLATE_RE = re.compile(
    r"(?i)^\s*("
    r"arr\b|arrangement|arranged|orchestrated|transcribed"
    r"|words?\s+and\s+music|music\s+by|lyrics?\s+by|composed"
    r"|copyright|all\s+rights|©|\(c\)\s|international\s+copyright"
    r"|this\s+arrangement|licen[cs]ed|licence|license|tres[oó]na"
    r"|for\s+the\s+\d{4}|duration|performance\s+time"
    r"|page\s+\d+|\d+\s*$"
    r")"
)

# Tempo / rehearsal text that often sits in the header band.
EXPRESSION_RE = re.compile(
    r"(?i)^\s*("
    r"(slow|fast|moderate|freely|rubato|swing|straight|ballad|groove)\b"
    r"|[a-z\s]*\bq\s*=\s*\d+"
    r"|(intro|verse|chorus|bridge|outro|vamp|tag|coda|dance\s+break|solo|tacet)\b"
    r")"
)

# Instrument vocabulary. A header line matching any of these is almost
# certainly the part name, so it outranks positional guesswork.
INSTRUMENT_WORDS = [
    # scores
    r"full\s+score", r"conductor'?s?\s+score", r"condensed\s+score", r"short\s+score",
    r"\bscore\b", r"\bconductor\b", r"lead\s+sheet", r"chord\s+chart", r"rhythm\s+chart",
    # voices
    r"soprano", r"\balto\b", r"\btenor\b", r"\bbaritone\b", r"\bbass\b",
    r"\bsatb\b", r"\bsab\b", r"\bssa\b", r"\bttbb\b", r"\bsa\b", r"\btb\b",
    r"\bvoice\b", r"\bvocals?\b", r"\bchoir\b", r"\bchorus\b", r"\bmelody\b",
    # keyboards
    r"\bpiano\b", r"keyboard", r"synth(esi[sz]er)?", r"\borgan\b", r"rhodes",
    r"celesta", r"harpsichord", r"accordion",
    # guitars / bass
    r"guitar", r"\bgtr\b", r"\bbanjo\b", r"ukulele", r"mandolin",
    # percussion
    r"drum\s*set", r"drum\s*kit", r"\bdrums?\b", r"percussion", r"\bperc\b",
    r"vibraphone", r"\bvibes\b", r"marimba", r"xylophone", r"glockenspiel",
    r"\bbells\b", r"\bmallets\b", r"timpani", r"\bcymbals?\b", r"\bsnare\b",
    r"congas?", r"bongos?", r"tambourine", r"aux(iliary)?\s+perc",
    # woodwinds
    r"\bflute\b", r"piccolo", r"\boboe\b", r"english\s+horn", r"clarinet",
    r"bassoon", r"contrabassoon", r"saxophone", r"\bsax\b", r"recorder",
    # brass
    r"trumpet", r"cornet", r"flugelhorn", r"french\s+horn", r"\bhorn\b",
    r"trombone", r"euphonium", r"\btuba\b", r"sousaphone", r"mellophone",
    # strings
    r"violin", r"viola", r"violoncello", r"\bcello\b", r"contrabass",
    r"double\s+bass", r"string\s+bass", r"upright\s+bass", r"\bharp\b",
    r"\bviolins?\s+[i1v]+\b", r"\bvln\b", r"\bvla\b", r"\bvc\b",
]
INSTRUMENT_RE = re.compile("|".join(INSTRUMENT_WORDS), re.IGNORECASE)

# Raw label -> output name. Matched case-insensitively on the whole label.
DEFAULT_ALIASES = {
    "full score": "Score",
    "conductor score": "Score",
    "conductors score": "Score",
    "conductor's score": "Score",
    "condensed score": "Score",
    "piano/vocal": "Piano",
    "piano / vocal": "Piano",
    "vocal/piano": "Piano",
    "piano-vocal": "Piano",
    "piano vocal": "Piano",
    "rehearsal piano": "Piano",
    "synthesizer": "Synth",
    "synthesiser": "Synth",
    "drum set": "Drums",
    "drumset": "Drums",
    "drum kit": "Drums",
    "soprano saxophone": "Soprano_Sax",
    "alto saxophone": "Alto_Sax",
    "tenor saxophone": "Tenor_Sax",
    "baritone saxophone": "Bari_Sax",
    "baritone sax": "Bari_Sax",
    "bari sax": "Bari_Sax",
    "bass trombone": "Bass_Trombone",
    "string bass": "Upright_Bass",
    "double bass": "Upright_Bass",
}

# Applied after aliases, to whatever is left.
WORD_ABBREV = [
    (re.compile(r"(?i)\bsaxophone\b"), "Sax"),
    (re.compile(r"(?i)\bsynthesi[sz]er\b"), "Synth"),
    (re.compile(r"(?i)\bpercussion\b"), "Perc"),
]

# "Clarinet in Bb 1" -> "Clarinet 1". The flat/sharp may be a real glyph, a
# plain letter, or missing entirely, depending on how the engraver embedded it.
TRANSPOSITION_RE = re.compile(r"(?i)\s+in\s+[A-G][b#♭♯]?(?=\s|$)")

# Trailing page marker on a running head: "... - p.2", "... page 3".
PAGE_SUFFIX_RE = re.compile(r"(?i)\s*[-–—,]?\s*(?:p\.?|pg\.?|page)\s*\d+\s*$")

# Separator used by running heads: "Song - Part - p.2".
RUNNING_HEAD_SPLIT = re.compile(r"\s+[-–—]\s+")

# Titles injected by conversion tools, which say nothing about the music.
JUNK_TITLE_RE = re.compile(
    r"(?i)^\s*(untitled|unnamed|document\s*\d*|new\s+document|merged\b|combined\b"
    r"|microsoft\s+word|word\s+document|print(out)?|output|scan(ned)?|image"
    r"|pdfcreator|ghostscript|acrobat|quartz|converted"
    r"|.*\.(pdf|docx?|pages|sib|mus|musx|mscz|xml|ps)\s*)$"
)


# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------


@dataclass
class Part:
    """One instrument's part: a display name plus the pages that make it up."""

    name: str  # normalised, filename-safe, e.g. "Clarinet1"
    label: str  # as printed in the PDF, e.g. "Clarinet in Bb 1"
    pages: list[int] = field(default_factory=list)  # 0-based page indices

    @property
    def ranges(self) -> str:
        """Page numbers as a human range string, e.g. "8-14" (1-based)."""
        out, start, prev = [], None, None
        for p in self.pages:
            if start is None:
                start = prev = p
            elif p == prev + 1:
                prev = p
            else:
                out.append((start, prev))
                start = prev = p
        if start is not None:
            out.append((start, prev))
        return ", ".join(
            f"{a + 1}" if a == b else f"{a + 1}-{b + 1}" for a, b in out
        )


# --------------------------------------------------------------------------
# Header extraction
# --------------------------------------------------------------------------


def _clean(text: str) -> str:
    """Normalise unicode and whitespace in a candidate label.

    Notation fonts map their glyphs into the Unicode private use area, so a
    label can arrive as "Trumpet in B\\uf062 1" where that codepoint is a flat
    sign. Those glyphs mean nothing as text, so they go.
    """
    text = unicodedata.normalize("NFKC", text)
    text = re.sub("[\\uE000-\\uF8FF]", "", text)
    text = text.replace("\u2019", "'").replace("\u2013", "-").replace("\u2014", "-")
    # Readers disagree about spacing around a slash -- "Piano/ Vocal" against
    # "Piano/Vocal". It means nothing in a part name, so settle it here and
    # let one alias cover both.
    text = re.sub(r"\s*/\s*", "/", text)
    return re.sub(r"\s+", " ", text).strip()


@dataclass
class HeaderLine:
    text: str
    x0: float
    x1: float
    y0: float
    page_width: float

    @property
    def is_outer(self) -> bool:
        """True when the line hugs the left or right page margin.

        Part names on continuation pages sit in the outer corner, opposite the
        page number, so this is a strong positional signal.
        """
        return (
            self.x0 <= self.page_width * 0.10
            or self.x1 >= self.page_width * 0.90
        )


def header_lines(page, band: float) -> list[HeaderLine]:
    """Return the text lines in the top `band` fraction of a page.

    Spans are joined per line: a label like "Clarinet in Bb 1" is split into
    three spans because the flat sign comes from a notation font, and only the
    joined line reads as an instrument name.
    """
    height, width = page.rect.height, page.rect.width
    limit = height * band
    lines: list[HeaderLine] = []

    for block in page.get_text("dict")["blocks"]:
        if block["type"] != 0:  # image block
            continue
        for line in block["lines"]:
            x0, y0, x1, y1 = line["bbox"]
            if y1 > limit:
                continue
            # A line made only of notation glyphs is music, not a label.
            if all(MUSIC_FONT_RE.search(s["font"]) for s in line["spans"]):
                continue
            text = _clean("".join(s["text"] for s in line["spans"]))
            if text:
                lines.append(HeaderLine(text, x0, x1, y0, width))
    return lines


def is_instrument_name(text: str) -> str:
    """True when a string is nothing but an instrument name.

    Used to keep a part name from being mistaken for the song title. A part
    that dominates the page count -- a 24-page score in a 58-page book -- would
    otherwise out-vote the real title and have its own pages discarded.
    Deliberately narrow: "Piano" is an instrument, "Piano Man" is a song.
    """
    residue = INSTRUMENT_RE.sub(" ", text)
    residue = TRANSPOSITION_RE.sub(" ", residue)
    residue = re.sub(r"(?i)\b(in|and|the|part|no|[a-g][b#]?|[0-9ivx]+)\b", " ", residue)
    return not re.sub(r"[^A-Za-z]", "", residue)


def _metadata_title(doc) -> str:
    """The document's own title, if it says anything useful."""
    meta = _clean(doc.metadata.get("title") or "")
    if not meta or len(meta) >= 80 or JUNK_TITLE_RE.match(meta):
        return ""
    if doc.metadata.get("creator") == "pdf-music-breakout":
        # One of our own part files, titled "Song - Part". Drop the part so a
        # second pass over it doesn't stack the name up again.
        subject = _clean(doc.metadata.get("subject") or "")
        if subject and meta.casefold().endswith(f" - {subject}".casefold()):
            meta = meta[: -(len(subject) + 3)].strip()
    return meta


def find_title(doc, pages_lines: list[list[HeaderLine]]) -> str:
    """Best guess at the song title, so it can be excluded from labels.

    The printed page beats the metadata: conversion tools cheerfully stamp
    things like "Merged with PDFCreator Online" into the title field.
    """
    n = len(pages_lines)
    counts: Counter[str] = Counter()
    for lines in pages_lines:
        seen: set[str] = set()
        for text in {ln.text for ln in lines}:
            if not (2 <= len(text) <= 70) or text.isdigit():
                continue
            # The part name is not the title, however often it appears.
            if not is_instrument_name(text):
                seen.add(text)
            # A running head reads "Song - Part - p.2", so its leading
            # segment is the title even though the whole line is unique.
            segments = RUNNING_HEAD_SPLIT.split(text)
            if len(segments) >= 2 and 2 <= len(segments[0]) <= 60:
                lead = segments[0].strip()
                if not is_instrument_name(lead):
                    seen.add(lead)
        counts.update(seen)

    if counts:
        text, hits = counts.most_common(1)[0]
        if hits >= max(2, n * 0.3):
            return text
    return _metadata_title(doc)


def strip_running_head(label: str, title: str) -> str:
    """Reduce a running head to the part name it contains.

    "Heads Will Roll - Alto Sax - p.2" -> "Alto Sax"
    """
    text = PAGE_SUFFIX_RE.sub("", label).strip(" -–—:")
    if title:
        prefix = re.match(
            rf"^{re.escape(title)}\s*[-–—:]\s*(.+)$", text, re.IGNORECASE
        )
        if prefix:
            text = prefix.group(1)
    return text.strip(" -–—:")


def find_boilerplate(pages_lines: list[list[HeaderLine]], threshold: float) -> set[str]:
    """Header strings repeated on most pages that are not instrument names.

    Catches the arranger credit, the dedication line and licence notices
    without needing a pattern for each one.
    """
    n = len(pages_lines)
    counts = Counter(
        line.text for lines in pages_lines for line in {ln.text: ln for ln in lines}.values()
    )
    return {
        text
        for text, hits in counts.items()
        if hits >= max(3, n * threshold) and not is_instrument_name(text)
    }


def score_candidate(line: HeaderLine, top_y: float, is_instrument: bool) -> int:
    """Rank a header line's plausibility as the page's part name."""
    score = 0
    if is_instrument:
        score += 100
    if line.is_outer:
        score += 30
    if line.y0 <= top_y + 4.0:  # on the topmost header row
        score += 20
    return score


def detect_label(lines: list[HeaderLine], title: str, boilerplate: set[str]) -> str | None:
    """Pick the part name printed on one page, or None if there isn't one."""
    candidates = []
    for line in lines:
        text = line.text
        if not text or len(text) > 48:
            continue
        if not any(ch.isalpha() for ch in text):
            continue  # page numbers, bar numbers, stray punctuation
        if title and text.casefold() == title.casefold():
            continue
        if text in boilerplate:
            continue
        if BOILERPLATE_RE.match(text) or EXPRESSION_RE.match(text):
            continue
        candidates.append(line)

    if not candidates:
        return None

    top_y = min(line.y0 for line in candidates)
    ranked = [
        (score_candidate(c, top_y, bool(INSTRUMENT_RE.search(c.text))), -c.y0, c)
        for c in candidates
    ]
    ranked.sort(key=lambda t: (t[0], t[1]), reverse=True)
    best_score, _, best = ranked[0]
    return best.text if best_score >= 50 else None


# --------------------------------------------------------------------------
# Naming
# --------------------------------------------------------------------------


def normalise_name(label: str, aliases: dict[str, str]) -> str:
    """Turn a printed label into a tidy, filename-safe part name.

    "Clarinet in Bb 1" -> "Clarinet1",  "Alto Saxophone" -> "Alto_Sax".
    """
    text = _clean(label)
    direct = aliases.get(text.casefold())
    if direct:
        return direct

    text = TRANSPOSITION_RE.sub("", text)
    if (again := aliases.get(text.casefold())) is not None:
        return again

    for pattern, replacement in WORD_ABBREV:
        text = pattern.sub(replacement, text)

    text = re.sub(r"[\\/]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    # Attach a trailing part number directly: "Clarinet 1" -> "Clarinet1".
    text = re.sub(r"\s+([0-9IVX]+)$", r"\1", text)
    text = text.replace(" ", "_")
    text = re.sub(r"[^A-Za-z0-9_.+#-]", "", text)
    return text or "Part"


def load_aliases(path: Path | None, renames: list[str]) -> dict[str, str]:
    aliases = {k.casefold(): v for k, v in DEFAULT_ALIASES.items()}
    if path:
        data = json.loads(path.read_text(encoding="utf-8"))
        aliases.update({str(k).casefold(): str(v) for k, v in data.items()})
    for entry in renames:
        if "=" not in entry:
            raise SystemExit(f"--rename needs OLD=NEW, got: {entry!r}")
        old, new = entry.split("=", 1)
        aliases[_clean(old).casefold()] = _clean(new)
    return aliases


# --------------------------------------------------------------------------
# Page range parsing (--map)
# --------------------------------------------------------------------------


def parse_ranges(spec: str, n_pages: int) -> list[int]:
    """Parse "1-6,9,12-14" into 0-based page indices."""
    pages: list[int] = []
    for chunk in spec.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "-" in chunk[1:]:
            lo_s, hi_s = chunk.split("-", 1)
            lo, hi = int(lo_s), int(hi_s)
        else:
            lo = hi = int(chunk)
        if not (1 <= lo <= hi <= n_pages):
            raise SystemExit(f"page range {chunk!r} is outside 1-{n_pages}")
        pages.extend(range(lo - 1, hi))
    return pages


def parse_map(entries: list[str], n_pages: int, aliases: dict[str, str]) -> list[Part]:
    parts: list[Part] = []
    for entry in entries:
        if "=" not in entry:
            raise SystemExit(f"--map needs RANGES=NAME, got: {entry!r}")
        ranges, label = entry.split("=", 1)
        label = _clean(label)
        parts.append(
            Part(normalise_name(label, aliases), label, parse_ranges(ranges, n_pages))
        )
    return parts


# --------------------------------------------------------------------------
# Splitting
# --------------------------------------------------------------------------


def parts_from_bookmarks(doc, aliases: dict[str, str]) -> list[Part]:
    """Build parts from the PDF outline, when it has one worth using."""
    toc = doc.get_toc()
    if not toc:
        return []
    # Only top-level entries, and only if they look like instrument names.
    tops = [(lvl, _clean(t), pg) for lvl, t, pg in toc if lvl == 1 and pg > 0]
    if len(tops) < 2:
        return []
    if sum(1 for _, title, _ in tops if INSTRUMENT_RE.search(title)) < len(tops) * 0.6:
        return []

    parts = []
    for i, (_, title, page) in enumerate(tops):
        start = page - 1
        end = tops[i + 1][2] - 1 if i + 1 < len(tops) else len(doc)
        parts.append(
            Part(normalise_name(title, aliases), title, list(range(start, end)))
        )
    return parts


def detect_page_labels(doc, band: float, boiler_threshold: float,
                       verbose: bool = False) -> tuple[list[str | None], str]:
    """Read the part name printed on each page.

    Returns one entry per page -- the label where a part begins, None where
    the page carries no name of its own -- plus the song title. This is the
    shared detection pass: the CLI groups the result into files, and the
    review UI shows it as editable page boundaries.
    """
    pages_lines = [header_lines(page, band) for page in doc]
    title = find_title(doc, pages_lines)
    boilerplate = find_boilerplate(pages_lines, boiler_threshold)

    if verbose:
        print(f"  title guess:  {title!r}", file=sys.stderr)
        for text in sorted(boilerplate):
            print(f"  boilerplate:  {text[:70]!r}", file=sys.stderr)

    labels: list[str | None] = []
    for i, lines in enumerate(pages_lines):
        raw = detect_label(lines, title, boilerplate)
        label = strip_running_head(raw, title) if raw else None
        labels.append(label or None)
        if verbose:
            shown = label if label else "-- (continuation or front matter)"
            extra = f"   <- {raw!r}" if raw and raw != label else ""
            print(f"  page {i + 1:>3}:  {shown}{extra}", file=sys.stderr)
    return labels, title


def group_labels(labels: list[str | None], aliases: dict[str, str],
                 n_pages: int) -> tuple[list[Part], list[int]]:
    """Turn per-page labels into parts, plus any leading front matter.

    An unlabelled page continues the part above it. Parts are grouped by
    normalised name, so one interrupted and resumed later lands in a single
    file rather than two.
    """
    first = next((i for i, lab in enumerate(labels) if lab), None)
    if first is None:
        return [], list(range(n_pages))
    front = list(range(first))

    parts: list[Part] = []
    index: dict[str, Part] = {}
    current = None
    for i in range(first, n_pages):
        if labels[i]:
            current = labels[i]
        if not current:
            continue
        name = normalise_name(current, aliases)
        part = index.get(name)
        if part is None:
            part = Part(name, current, [])
            index[name] = part
            parts.append(part)
        part.pages.append(i)
    return parts, front


def parts_from_headers(doc, aliases: dict[str, str], band: float,
                       boiler_threshold: float,
                       verbose: bool) -> tuple[list[Part], list[int], str]:
    """Detect parts by reading each page's printed header."""
    labels, title = detect_page_labels(doc, band, boiler_threshold, verbose)
    parts, front = group_labels(labels, aliases, len(doc))
    return parts, front, title


def resolve_paper(spec: str, doc) -> tuple[float, float] | None:
    """Work out the target page size. None means "leave pages alone"."""
    spec = spec.strip().lower()
    if spec == "keep":
        return None
    if spec == "auto":
        # The size most pages already use: parts stay untouched and only an
        # oversized conductor score gets fitted.
        sizes = Counter(
            (round(p.rect.width, 1), round(p.rect.height, 1)) for p in doc
        )
        return sizes.most_common(1)[0][0]
    if spec in PAPERS:
        return PAPERS[spec]
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)\s*(pt|in|mm)?", spec)
    if not m:
        raise SystemExit(
            f"unknown --paper {spec!r}; use keep, auto, "
            + ", ".join(sorted(PAPERS))
            + ", or WxH[pt|in|mm]"
        )
    w, h, unit = float(m.group(1)), float(m.group(2)), m.group(3) or "pt"
    factor = {"pt": 1.0, "in": 72.0, "mm": 72.0 / 25.4}[unit]
    return w * factor, h * factor


def add_page(out, doc, pno: int, paper, margin: float, rotate: str,
             force_fit: bool) -> bool:
    """Append source page `pno` to `out`. Returns True if it was transformed.

    A page that already fits the target paper is copied through untouched, so
    it keeps its original quality, links and structure. Only an oversized page
    is rotated and scaled to fit.
    """
    src = doc[pno]
    sw, sh = src.rect.width, src.rect.height

    if paper is None:
        out.insert_pdf(doc, from_page=pno, to_page=pno)
        return False

    pw, ph = paper
    fits = sw <= pw + 1.0 and sh <= ph + 1.0
    if fits and not force_fit:
        out.insert_pdf(doc, from_page=pno, to_page=pno)
        return False

    avail_w, avail_h = pw - 2 * margin, ph - 2 * margin
    if avail_w <= 0 or avail_h <= 0:
        raise SystemExit("--margin leaves no room on the page")

    if rotate == "none":
        turn = 0
    elif rotate == "cw":
        turn = 90
    elif rotate == "ccw":
        turn = 270
    else:  # auto: rotate only when it lets the page print larger
        upright = min(avail_w / sw, avail_h / sh)
        turned = min(avail_w / sh, avail_h / sw)
        turn = 90 if turned > upright * 1.01 else 0

    ew, eh = (sh, sw) if turn in (90, 270) else (sw, sh)
    scale = min(avail_w / ew, avail_h / eh)
    w, h = ew * scale, eh * scale
    x, y = (pw - w) / 2, (ph - h) / 2

    page = out.new_page(width=pw, height=ph)
    # PyMuPDF measures `rotate` counter-clockwise, so 90 clockwise is -90.
    page.show_pdf_page(
        pymupdf.Rect(x, y, x + w, y + h), doc, pno, rotate=-turn if turn else 0
    )
    return True


def write_part(doc, part: Part, front: list[int], path: Path, *, paper, margin,
               rotate, force_fit, title: str) -> int:
    out = pymupdf.open()
    transformed = 0
    for pno in front + part.pages:
        if add_page(out, doc, pno, paper, margin, rotate, force_fit):
            transformed += 1
    out.set_metadata(
        {
            "title": f"{title} - {part.label}" if title else part.label,
            "author": doc.metadata.get("author", "") or "",
            "subject": part.label,
            "creator": "pdf-music-breakout",
            "producer": "pdf-music-breakout",
        }
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path, garbage=4, deflate=True, clean=True)
    out.close()
    return transformed


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def default_title(doc, source: Path) -> str:
    if meta := _metadata_title(doc):
        return meta
    stem = source.stem
    # "Abracadabra-ALL" -> "Abracadabra"
    return re.sub(r"(?i)[-_ ]+(all|full|complete|combined|book)$", "", stem).strip()


def safe_filename(name: str) -> str:
    """Keep a formatted filename to a single, writable path component.

    A title carrying a slash (a part label like "Piano/Vocal" can end up as one)
    would otherwise write into a subdirectory that doesn't exist.
    """
    name = name.replace("/", "-").replace("\\", "-")
    name = re.sub(r'[<>:"|?*\x00-\x1f]', "", name)
    name = re.sub(r"\s*-\s*-\s*", " - ", name).strip(" .")
    return Path(name).name or "part.pdf"


def auto_prefix(out_dir: Path) -> str:
    """Reuse a leading chart number from the output folder, e.g. "03-Song/"."""
    m = re.match(r"(\d{1,3})[-_ ]", out_dir.name)
    return f"{m.group(1)}-" if m else ""


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pdf-music-breakout",
        description="Split a combined music PDF into one printable PDF per instrument part.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  # See what it found, without writing anything
  pdf_music_breakout.py Abracadabra-ALL.pdf --list

  # Split into a folder, numbering files "03-Abracadabra-<Part>.pdf"
  pdf_music_breakout.py Abracadabra-ALL.pdf -o "Music/03-Abracadabra"

  # Keep the conductor score at its original tabloid size
  pdf_music_breakout.py score.pdf -o out --paper keep

  # Override detection for a scanned or oddly-labelled file
  pdf_music_breakout.py book.pdf -o out --map "2-7=Full Score" --map "8-14=Piano/Vocal"
""",
    )
    p.add_argument("--version", action="version",
                   version=f"pdf-music-breakout {__version__}")
    p.add_argument("source", type=Path, nargs="?",
                   help="the combined PDF to split (omit when using --serve)")
    p.add_argument("--serve", action="store_true",
                   help="open the review UI in a browser instead: drop a PDF, check the "
                        "detected parts, correct any it got wrong, then export")
    p.add_argument("--port", type=int, default=8756,
                   help="port for --serve (default: %(default)s)")
    p.add_argument("--no-browser", action="store_true",
                   help="with --serve, don't open a browser automatically")
    p.add_argument("-o", "--out-dir", type=Path,
                   help="directory for the part PDFs (default: alongside the source)")

    naming = p.add_argument_group("naming")
    naming.add_argument("--title", help="song title used in filenames (default: from the PDF)")
    naming.add_argument("--prefix", default="auto",
                        help="filename prefix, e.g. '03-'; 'auto' takes it from the "
                             "output folder name, 'none' disables it")
    naming.add_argument("--template", default="{prefix}{title}-{part}.pdf",
                        help="filename template (default: %(default)s)")
    naming.add_argument("--rename", action="append", default=[], metavar="OLD=NEW",
                        help="rename a detected part, e.g. --rename 'Drum Set=Kit'")
    naming.add_argument("--aliases", type=Path, metavar="FILE",
                        help="JSON file of {printed label: output name} overrides")

    detect = p.add_argument_group("detection")
    detect.add_argument("--map", action="append", default=[], metavar="RANGES=NAME",
                        help="set a part explicitly, e.g. --map '8-14=Piano/Vocal'; "
                             "repeatable, and skips automatic detection")
    detect.add_argument("--no-bookmarks", action="store_true",
                        help="ignore the PDF outline even if it looks usable")
    detect.add_argument("--header-band", type=float, default=0.15, metavar="F",
                        help="fraction of page height searched for the part name "
                             "(default: %(default)s)")
    detect.add_argument("--boilerplate-threshold", type=float, default=0.4, metavar="F",
                        help="header text on at least this fraction of pages is treated "
                             "as boilerplate (default: %(default)s)")

    page = p.add_argument_group("page setup")
    page.add_argument("--paper", default="auto",
                      help="target paper: auto (the document's most common size), keep, "
                           + ", ".join(sorted(PAPERS)) + ", or WxH[pt|in|mm] "
                           "(default: %(default)s)")
    page.add_argument("--margin", type=float, default=0.0, metavar="PT",
                      help="margin in points when fitting an oversized page (default: 0)")
    page.add_argument("--rotate", choices=("auto", "cw", "ccw", "none"), default="cw",
                      help="how to turn an oversized landscape page onto portrait paper "
                           "(default: %(default)s)")
    page.add_argument("--force-fit", action="store_true",
                      help="re-fit every page, not just the oversized ones")
    page.add_argument("--front-matter", choices=("skip", "attach"), default="skip",
                      help="what to do with cover/copyright pages that precede the first "
                           "part (default: %(default)s)")

    out = p.add_argument_group("output")
    out.add_argument("--only", action="append", default=[], metavar="NAME",
                     help="only write these parts (substring match, repeatable)")
    out.add_argument("--exclude", action="append", default=[], metavar="NAME",
                     help="skip these parts (substring match, repeatable)")
    out.add_argument("--list", action="store_true", help="show detected parts and exit")
    out.add_argument("-n", "--dry-run", action="store_true",
                     help="report what would be written without writing it")
    out.add_argument("--manifest", type=Path, metavar="FILE",
                     help="also write a JSON manifest of the split")
    out.add_argument("--overwrite", action="store_true", help="replace existing files")
    out.add_argument("-v", "--verbose", action="store_true",
                     help="show per-page detection details")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.serve:
        import breakout_web
        return breakout_web.serve(port=args.port, open_browser=not args.no_browser)

    if args.source is None:
        raise SystemExit("give a PDF to split, or use --serve for the review UI")
    if not args.source.is_file():
        raise SystemExit(f"no such file: {args.source}")

    doc = pymupdf.open(args.source)
    if doc.needs_pass:
        raise SystemExit(f"{args.source} is password-protected; decrypt it first")
    if len(doc) == 0:
        raise SystemExit(f"{args.source} has no pages")

    aliases = load_aliases(args.aliases, args.rename)
    out_dir = args.out_dir or args.source.parent

    # --- work out the parts -------------------------------------------------
    front: list[int] = []
    detected_title = ""
    if args.map:
        parts = parse_map(args.map, len(doc), aliases)
        source_of_truth = "--map"
    else:
        parts = [] if args.no_bookmarks else parts_from_bookmarks(doc, aliases)
        source_of_truth = "bookmarks"
        if not parts:
            if args.verbose:
                print("detecting parts from page headers:", file=sys.stderr)
            parts, front, detected_title = parts_from_headers(
                doc, aliases, args.header_band, args.boilerplate_threshold, args.verbose
            )
            source_of_truth = "page headers"

    title = args.title or detected_title or default_title(doc, args.source)

    if not parts:
        text_pages = sum(1 for page in doc if page.get_text("text").strip())
        hint = (
            "\nThe pages have little or no text, so this is probably a scan. "
            "Run it through OCR, or set the parts by hand with --map."
            if text_pages < len(doc) / 2
            else "\nTry --verbose to see what was read, or set parts with --map."
        )
        raise SystemExit(f"could not identify any parts in {args.source}.{hint}")

    # Which pages the detector accounted for, judged before --only/--exclude:
    # a page dropped by a filter was still recognised, and warning about it
    # would be noise.
    covered = {p for part in parts for p in part.pages} | set(front)

    if args.only:
        wanted = [s.casefold() for s in args.only]
        parts = [p for p in parts
                 if any(w in p.name.casefold() or w in p.label.casefold() for w in wanted)]
    if args.exclude:
        unwanted = [s.casefold() for s in args.exclude]
        parts = [p for p in parts
                 if not any(w in p.name.casefold() or w in p.label.casefold()
                            for w in unwanted)]
    if not parts:
        raise SystemExit("every part was filtered out by --only/--exclude")

    # --- report -------------------------------------------------------------
    attach = front if args.front_matter == "attach" else []
    prefix = ""
    if args.prefix == "auto":
        prefix = auto_prefix(out_dir)
    elif args.prefix != "none":
        prefix = args.prefix

    print(f"{args.source.name}: {len(doc)} pages, {len(parts)} parts (via {source_of_truth})")
    if front:
        verb = "prepended to each part" if attach else "skipped (use --front-matter attach)"
        print(f"front matter: page{'s' if len(front) > 1 else ''} "
              f"{', '.join(str(i + 1) for i in front)} -- {verb}")

    if (missing := sorted(set(range(len(doc))) - covered)):
        print(f"warning: {len(missing)} page(s) not assigned to any part: "
              f"{', '.join(str(i + 1) for i in missing)}", file=sys.stderr)

    # A real chart has far fewer parts than pages. A part-per-page result
    # means the header held something unique to each page and detection has
    # gone wrong, so say so rather than writing 58 one-page files.
    if source_of_truth == "page headers" and len(parts) > max(6, len(doc) * 0.6):
        print(f"warning: detected {len(parts)} parts across {len(doc)} pages, which "
              f"looks like a misread. Check --verbose, then set the parts with --map.",
              file=sys.stderr)

    names = [
        safe_filename(args.template.format(prefix=prefix, title=title, part=p.name))
        for p in parts
    ]
    width = max(len(n) for n in names)
    for part, name in zip(parts, names):
        print(f"  {name:<{width}}  {len(part.pages) + len(attach):>2} pp   "
              f"pages {part.ranges}   [{part.label}]")

    if args.list:
        return 0

    # --- write --------------------------------------------------------------
    paper = resolve_paper(args.paper, doc)
    if paper:
        print(f"paper: {paper[0]:.0f}x{paper[1]:.0f} pt"
              f" (oversized pages rotated {args.rotate} and scaled to fit)")

    if args.dry_run:
        print(f"\ndry run -- nothing written to {out_dir}")
        return 0

    written = []
    for part, name in zip(parts, names):
        path = out_dir / name
        if path.exists() and not args.overwrite:
            print(f"  skipping {name} (already exists; use --overwrite)", file=sys.stderr)
            continue
        n = write_part(doc, part, attach, path, paper=paper, margin=args.margin,
                       rotate=args.rotate, force_fit=args.force_fit, title=title)
        note = f", {n} page(s) refitted" if n else ""
        print(f"  wrote {path} ({len(part.pages) + len(attach)} pp{note})")
        written.append({
            "file": str(path),
            "part": part.name,
            "label": part.label,
            "pages": [p + 1 for p in part.pages],
            "front_matter": [p + 1 for p in attach],
        })

    if args.manifest:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_text(
            json.dumps(
                {"source": str(args.source), "title": title,
                 "detection": source_of_truth, "parts": written},
                indent=2,
            ) + "\n",
            encoding="utf-8",
        )
        print(f"  wrote {args.manifest}")

    doc.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
