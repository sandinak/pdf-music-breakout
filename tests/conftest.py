"""Shared fixtures: synthetic music PDFs that mimic real engraver output."""

from __future__ import annotations

import sys
from pathlib import Path

import pymupdf
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

LETTER = (612.0, 792.0)
TABLOID_LANDSCAPE = (1224.0, 792.0)


def _page(doc, *, size=LETTER, part=None, title=None, running_head=None,
          page_no=None, credit=None, body="music", outer_right=False):
    """Add one page shaped like a real part page.

    `part` is the label printed in the outer top corner, `title` the centred
    song title, `running_head` a merged-PDF style "Song - Part - p.2" stamp.
    """
    width, height = size
    page = doc.new_page(width=width, height=height)
    if part:
        x = width - 120 if outer_right else 42
        page.insert_text((x, 50), part, fontsize=11)
    if title:
        page.insert_text((width / 2 - 60, 46), title, fontsize=22)
    if running_head:
        page.insert_text((width - 220, 56), running_head, fontsize=8)
    if page_no is not None:
        x = 42 if outer_right else width - 60
        page.insert_text((x, 50), str(page_no), fontsize=9)
    if credit:
        page.insert_text((width - 160, 95), credit, fontsize=8)
    if body:
        # Well below the header band, so it never becomes a candidate.
        page.insert_text((80, height / 2), body, fontsize=10)
    return page


@pytest.fixture
def make_pdf(tmp_path):
    """Build a PDF from a list of page specs and return its path."""
    def _make(specs, name="combined.pdf", metadata=None):
        doc = pymupdf.open()
        for spec in specs:
            _page(doc, **spec)
        if metadata:
            doc.set_metadata(metadata)
        path = tmp_path / name
        doc.save(path)
        doc.close()
        return path
    return _make


@pytest.fixture
def band_book(make_pdf):
    """A typical chart: cover, a 2-page score, and three single-page parts."""
    return make_pdf(
        [
            {"part": None, "title": None, "body": "Copyright notice"},
            {"part": "Full Score", "title": "Test Song", "credit": "arr. A. Person"},
            {"part": "Full Score", "page_no": 2, "outer_right": True},
            {"part": "Piano/Vocal", "title": "Test Song"},
            {"part": "Alto Saxophone", "title": "Test Song"},
            {"part": "Drum Set", "title": "Test Song"},
        ],
        name="Test Song-ALL.pdf",
    )
