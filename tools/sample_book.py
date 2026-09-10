#!/usr/bin/env python3
"""Write a synthetic combined book, for trying the tool without real music.

Real sheet music is licensed content and cannot live in this repository, so
tests and demos build their own: a cover, a landscape score, and a handful of
parts with the part name printed in the top corner the way an engraver puts
it.

    python tools/sample_book.py Abracadabra-ALL.pdf
"""

from __future__ import annotations

import random
import sys
from pathlib import Path

import pymupdf

LETTER = (612.0, 792.0)
TABLOID_LANDSCAPE = (1224.0, 792.0)
TITLE = "Abracadabra"
# Part name, page count, page size -- lengths like a real chart, so the
# "this looks like a misread" warning behaves the way it would in earnest.
PARTS = [
    ("Score", 4, TABLOID_LANDSCAPE),
    ("Piano", 4, LETTER), ("Synth", 2, LETTER), ("Guitar", 2, LETTER),
    ("Bass Guitar", 2, LETTER), ("Drums", 3, LETTER),
    ("Trumpet 1", 2, LETTER), ("Trumpet 2", 2, LETTER),
    ("Alto Sax 1", 2, LETTER), ("Tenor Sax", 2, LETTER),
    ("Trombone", 2, LETTER), ("Clarinet 1", 2, LETTER),
]


def staves(page, width: float, height: float, rng: random.Random) -> None:
    """Something that reads as music at thumbnail size."""
    y = 130.0
    while y < height - 90:
        for line in range(5):
            page.draw_line((50, y + line * 6), (width - 50, y + line * 6), width=0.5)
        for x in range(70, int(width) - 70, 34):
            page.draw_circle((x, y + rng.choice([0, 6, 12, 18, 24])), 2.6, fill=(0, 0, 0))
        page.insert_text((52, y + 40), rng.choice(["mf", "cresc.", "pp", "a tempo"]),
                         fontsize=5.5)
        y += 62


def add_page(doc, rng, *, part: str | None, title: str | None,
             number: int | None, size=LETTER):
    width, height = size
    page = doc.new_page(width=width, height=height)
    if title:
        page.insert_text((width / 2 - 90, 60), title, fontsize=22)
    if part:
        page.insert_text((42, 60), part, fontsize=11)
    if number is not None:
        page.insert_text((width - 60, 60), str(number), fontsize=9)
    page.insert_text((width - 200, 96), "Arr. A. Person  ·  Example Music Co.", fontsize=7)
    staves(page, width, height, rng)


def build(path: Path, seed: int = 7) -> Path:
    rng = random.Random(seed)
    doc = pymupdf.open()
    add_page(doc, rng, part=None, title=TITLE, number=None)      # cover
    for part, pages, size in PARTS:
        for number in range(1, pages + 1):
            add_page(doc, rng, part=part, title=TITLE if number == 1 else None,
                     number=number, size=size)
    doc.save(path)
    doc.close()
    return path


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "sample-ALL.pdf")
    build(out)
    print(f"wrote {out}")
