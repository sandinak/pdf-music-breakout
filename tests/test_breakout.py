"""Tests for pdf-music-breakout.

The integration tests build synthetic PDFs shaped like real engraver output;
the unit tests pin down the string handling that caused actual misreads on
real files.
"""

from __future__ import annotations

import json
import sys
import types

import pymupdf
import pytest

import pdf_music_breakout as pmb


# --------------------------------------------------------------------------
# Naming
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "label,expected",
    [
        ("Full Score", "Score"),
        ("Piano/Vocal", "Piano"),
        ("Synthesizer", "Synth"),
        ("Guitar", "Guitar"),
        ("Bass Guitar", "Bass_Guitar"),
        ("Clarinet in Bb 1", "Clarinet1"),
        ("Trumpet in Bb 2", "Trumpet2"),
        ("Alto Saxophone", "Alto_Sax"),
        ("Baritone Saxophone", "Bari_Sax"),
        ("Trombone 1", "Trombone1"),
        ("Drum Set", "Drums"),
        # The flat may be absent, leaving a bare note letter to strip.
        ("Trumpet in B 3", "Trumpet3"),
        # Roman numerals are part numbers too.
        ("Violin II", "ViolinII"),
    ],
)
def test_normalise_name(label, expected):
    assert pmb.normalise_name(label, pmb.DEFAULT_ALIASES) == expected


def test_normalise_name_honours_user_alias():
    aliases = dict(pmb.DEFAULT_ALIASES, **{"drum set": "Kit"})
    assert pmb.normalise_name("Drum Set", aliases) == "Kit"


def test_clean_strips_private_use_glyphs():
    """Notation fonts leak glyphs into text as private-use codepoints.

    A real file rendered its flat sign as U+F062, which blocked the
    transposition strip and produced "Trumpet_in_B1".
    """
    assert pmb._clean("Trumpet in B\uf062 1") == "Trumpet in B 1"
    assert pmb.normalise_name("Trumpet in B\uf062 1", pmb.DEFAULT_ALIASES) == "Trumpet1"


def test_windows_reserved_device_names_are_escaped():
    """Windows cannot write CON.pdf, however sensible the part name looked."""
    assert pmb.safe_filename("CON.pdf") == "_CON.pdf"
    assert pmb.safe_filename("aux.pdf") == "_aux.pdf"
    assert pmb.safe_filename("COM1.pdf") == "_COM1.pdf"
    # Only the whole name is reserved, not anything starting with it.
    assert pmb.safe_filename("Concerto-Piano.pdf") == "Concerto-Piano.pdf"
    assert pmb.safe_filename("Auxiliary_Perc.pdf") == "Auxiliary_Perc.pdf"


def test_no_arguments_opens_the_review_ui(monkeypatch):
    """A double-clicked .exe arrives with no arguments and must not die."""
    seen = {}

    def fake_serve(port, open_browser):
        seen["port"] = port
        return 0

    monkeypatch.setitem(sys.modules, "breakout_web",
                        types.SimpleNamespace(serve=fake_serve))
    assert pmb.main([]) == 0
    assert seen["port"] == 8756


def test_safe_filename_never_escapes_its_directory():
    """A part label carrying a slash must not create a subdirectory."""
    assert "/" not in pmb.safe_filename("Song - Piano/Vocal-Piano.pdf")
    # Separators are neutralised rather than dropped, so nothing escapes.
    assert "/" not in pmb.safe_filename("../../etc/passwd.pdf")
    assert pmb.safe_filename("sub/dir/Song-Piano.pdf") == "sub-dir-Song-Piano.pdf"


@pytest.mark.parametrize(
    "label,title,expected",
    [
        ("Heads Will Roll - Alto Sax - p.2", "Heads Will Roll", "Alto Sax"),
        ("Heads Will Roll - Score - p.24", "Heads Will Roll", "Score"),
        ("Song - Piano - page 3", "Song", "Piano"),
        ("Piano", "Song", "Piano"),          # already bare
        ("Trumpet 1", "Song", "Trumpet 1"),  # trailing number is not a page no.
    ],
)
def test_strip_running_head(label, title, expected):
    assert pmb.strip_running_head(label, title) == expected


# --------------------------------------------------------------------------
# Page ranges
# --------------------------------------------------------------------------


def test_parse_ranges():
    assert pmb.parse_ranges("1-3,5,8-9", 10) == [0, 1, 2, 4, 7, 8]


@pytest.mark.parametrize("spec", ["0-3", "1-99", "50"])
def test_parse_ranges_rejects_out_of_bounds(spec):
    with pytest.raises(SystemExit):
        pmb.parse_ranges(spec, 10)


def test_part_ranges_render_as_human_ranges():
    part = pmb.Part("X", "X", [0, 1, 2, 5, 7, 8])
    assert part.ranges == "1-3, 6, 8-9"


# --------------------------------------------------------------------------
# Detection
# --------------------------------------------------------------------------


def _detect(path):
    doc = pymupdf.open(path)
    parts, front, title = pmb.parts_from_headers(
        doc, pmb.DEFAULT_ALIASES, 0.15, 0.4, False
    )
    doc.close()
    return parts, front, title


def test_detects_parts_and_front_matter(band_book):
    parts, front, title = _detect(band_book)
    assert [p.name for p in parts] == ["Score", "Piano", "Alto_Sax", "Drums"]
    assert front == [0], "the copyright page precedes the first part"
    assert title == "Test Song"


def test_continuation_pages_join_the_part_above(band_book):
    parts, _, _ = _detect(band_book)
    score = next(p for p in parts if p.name == "Score")
    assert score.pages == [1, 2], "page 3 has no title, so it continues the score"


def test_arranger_credit_never_becomes_the_title(make_pdf):
    """Regression: every output file was named after the arranger.

    The credit is printed on every page while the title appears only where a
    part begins, so picking the most repeated header line picked the credit --
    and it became the title in every filename.
    """
    specs = []
    for part, pages in (("Full Score", 3), ("Piano", 3), ("Alto Saxophone", 3)):
        for n in range(1, pages + 1):
            specs.append({"part": part, "credit": "Arr. A. Person",
                          "title": "Real Title" if n == 1 else None,
                          "page_no": n})
    parts, _, title = _detect(make_pdf(specs))
    assert title == "Real Title"
    assert [p.name for p in parts] == ["Score", "Piano", "Alto_Sax"]


def test_running_heads_and_junk_metadata_title(make_pdf):
    """Regression: a merged PDF stamped a unique running head on every page.

    Every page looked like a new part (58 pages -> 58 "parts"), and the
    metadata title "Merged with PDFCreator Online" leaked into filenames.
    """
    path = make_pdf(
        [
            {"part": "Score", "title": "My Song"},
            {"running_head": "My Song - Score - p.2"},
            {"running_head": "My Song - Score - p.3"},
            {"part": "Alto Sax", "title": "My Song"},
            {"running_head": "My Song - Alto Sax - p.2"},
        ],
        metadata={"title": "Merged with PDFCreator Online"},
    )
    parts, _, title = _detect(path)
    assert title == "My Song", "the printed page beats the metadata"
    assert [(p.name, len(p.pages)) for p in parts] == [("Score", 3), ("Alto_Sax", 2)]


def test_non_contiguous_pages_merge_into_one_part(make_pdf):
    path = make_pdf(
        [
            {"part": "Piano", "title": "Test Song"},
            {"part": "Guitar", "title": "Test Song"},
            {"part": "Piano", "title": "Test Song"},
        ]
    )
    parts, _, _ = _detect(path)
    piano = next(p for p in parts if p.name == "Piano")
    assert piano.pages == [0, 2]


def test_lyrics_and_tempo_marks_are_not_mistaken_for_parts(make_pdf):
    path = make_pdf(
        [
            {"part": "Piano", "title": "Test Song", "credit": "Haunting Groove"},
            {"part": None, "title": None, "credit": "DANCE BREAK"},
        ]
    )
    parts, _, _ = _detect(path)
    assert [p.name for p in parts] == ["Piano"]
    assert parts[0].pages == [0, 1]


def test_pdf_with_no_text_is_reported_not_guessed(make_pdf):
    path = make_pdf([{"part": None, "title": None, "body": None}] * 3)
    with pytest.raises(SystemExit, match="(?i)scan|--map"):
        pmb.main([str(path), "--list"])


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


def test_writes_one_pdf_per_part(band_book, tmp_path):
    out = tmp_path / "03-Test Song"
    assert pmb.main([str(band_book), "-o", str(out)]) == 0
    written = sorted(p.name for p in out.glob("*.pdf"))
    assert written == [
        "03-Test Song-Alto_Sax.pdf",
        "03-Test Song-Drums.pdf",
        "03-Test Song-Piano.pdf",
        "03-Test Song-Score.pdf",
    ], "the 03- prefix comes from the output folder name"
    doc = pymupdf.open(out / "03-Test Song-Score.pdf")
    assert len(doc) == 2
    doc.close()


def test_front_matter_attach_prepends_the_notice(band_book, tmp_path):
    out = tmp_path / "out"
    pmb.main([str(band_book), "-o", str(out), "--front-matter", "attach"])
    doc = pymupdf.open(out / "Test Song-Piano.pdf")
    assert len(doc) == 2, "copyright page + the part's own page"
    assert "Copyright notice" in doc[0].get_text()
    doc.close()


def test_oversized_score_is_rotated_onto_the_target_paper(make_pdf, tmp_path):
    path = make_pdf(
        [
            {"part": "Full Score", "title": "Test Song", "size": pmb_tabloid()},
            {"part": "Piano", "title": "Test Song"},
        ]
    )
    out = tmp_path / "out"
    pmb.main([str(path), "-o", str(out), "--paper", "letter"])
    score = pymupdf.open(out / "Test Song-Score.pdf")
    assert (score[0].rect.width, score[0].rect.height) == (612.0, 792.0)
    # Rotated a quarter turn, so its text now runs down the page.
    dirs = {
        line["dir"]
        for block in score[0].get_text("dict")["blocks"] if block["type"] == 0
        for line in block["lines"]
    }
    assert (0.0, 1.0) in dirs
    score.close()


def test_pages_that_already_fit_are_copied_untouched(band_book, tmp_path):
    """Quality guard: a fitting page must not be re-rendered or rescaled."""
    out = tmp_path / "out"
    pmb.main([str(band_book), "-o", str(out)])
    src, dst = pymupdf.open(band_book), pymupdf.open(out / "Test Song-Piano.pdf")
    a = src[3].get_text("dict")["blocks"][0]["lines"][0]["spans"][0]
    b = dst[0].get_text("dict")["blocks"][0]["lines"][0]["spans"][0]
    assert a["bbox"] == b["bbox"] and a["size"] == b["size"]
    src.close(), dst.close()


def test_paper_keep_leaves_an_oversized_page_alone(make_pdf, tmp_path):
    path = make_pdf(
        [{"part": "Full Score", "title": "Test Song", "size": pmb_tabloid()}] * 2
    )
    out = tmp_path / "out"
    pmb.main([str(path), "-o", str(out), "--paper", "keep"])
    doc = pymupdf.open(out / "Test Song-Score.pdf")
    assert (doc[0].rect.width, doc[0].rect.height) == pmb_tabloid()
    doc.close()


def test_explicit_map_overrides_detection(band_book, tmp_path):
    out = tmp_path / "out"
    pmb.main([str(band_book), "-o", str(out), "--map", "2-4=Rhythm Chart"])
    files = sorted(p.name for p in out.glob("*.pdf"))
    assert files == ["Test Song-Rhythm_Chart.pdf"]
    doc = pymupdf.open(out / "Test Song-Rhythm_Chart.pdf")
    assert len(doc) == 3
    doc.close()


def test_only_and_exclude_filter_parts(band_book, tmp_path):
    out = tmp_path / "a"
    pmb.main([str(band_book), "-o", str(out), "--only", "Piano"])
    assert [p.name for p in out.glob("*.pdf")] == ["Test Song-Piano.pdf"]

    out2 = tmp_path / "b"
    pmb.main([str(band_book), "-o", str(out2), "--exclude", "Score"])
    assert "Test Song-Score.pdf" not in {p.name for p in out2.glob("*.pdf")}


def test_existing_files_are_not_clobbered_without_overwrite(band_book, tmp_path):
    out = tmp_path / "out"
    pmb.main([str(band_book), "-o", str(out)])
    target = out / "Test Song-Piano.pdf"
    target.write_bytes(b"%PDF-1.4 sentinel")
    pmb.main([str(band_book), "-o", str(out)])
    assert target.read_bytes() == b"%PDF-1.4 sentinel"
    pmb.main([str(band_book), "-o", str(out), "--overwrite"])
    assert target.read_bytes() != b"%PDF-1.4 sentinel"


def test_dry_run_writes_nothing(band_book, tmp_path):
    out = tmp_path / "out"
    pmb.main([str(band_book), "-o", str(out), "--dry-run"])
    assert not out.exists()


def test_manifest_records_the_split(band_book, tmp_path):
    out = tmp_path / "out"
    manifest = tmp_path / "manifest.json"
    pmb.main([str(band_book), "-o", str(out), "--manifest", str(manifest)])
    data = json.loads(manifest.read_text(encoding="utf-8"))
    assert data["title"] == "Test Song"
    assert {p["part"] for p in data["parts"]} == {"Score", "Piano", "Alto_Sax", "Drums"}
    assert next(p for p in data["parts"] if p["part"] == "Score")["pages"] == [2, 3]


def test_round_trip_does_not_stack_the_title(band_book, tmp_path):
    """Splitting an already-split part must not yield "Song - Piano-Piano"."""
    out = tmp_path / "out"
    pmb.main([str(band_book), "-o", str(out)])
    again = tmp_path / "again"
    pmb.main([str(out / "Test Song-Piano.pdf"), "-o", str(again)])
    assert [p.name for p in again.glob("*.pdf")] == ["Test Song-Piano.pdf"]


def test_part_per_page_result_warns(make_pdf, tmp_path, capsys):
    """A misread that yields a part for every page should say so."""
    path = make_pdf([{"part": name, "title": "Test Song"} for name in
                     ("Piano", "Guitar", "Violin", "Cello", "Flute", "Oboe", "Tuba")])
    pmb.main([str(path), "--list"])
    assert "looks like a misread" in capsys.readouterr().err


# --------------------------------------------------------------------------
# Paper parsing
# --------------------------------------------------------------------------


def pmb_tabloid():
    return (1224.0, 792.0)


def test_resolve_paper_auto_picks_the_commonest_size(make_pdf):
    path = make_pdf(
        [{"part": "Full Score", "title": "Test Song", "size": pmb_tabloid()}]
        + [{"part": "Piano", "title": "Test Song"}] * 3
    )
    doc = pymupdf.open(path)
    assert pmb.resolve_paper("auto", doc) == (612.0, 792.0)
    assert pmb.resolve_paper("keep", doc) is None
    assert pmb.resolve_paper("a4", doc) == pmb.PAPERS["a4"]
    assert pmb.resolve_paper("8.5x11in", doc) == (612.0, 792.0)
    doc.close()


def test_resolve_paper_rejects_nonsense(make_pdf):
    doc = pymupdf.open(make_pdf([{"part": "Piano", "title": "Test Song"}]))
    with pytest.raises(SystemExit, match="unknown --paper"):
        pmb.resolve_paper("banana", doc)
    doc.close()
