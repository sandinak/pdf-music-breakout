"""Tests for the review UI's HTTP layer.

These run a real server on a loopback port and talk to it the way the page
does, so the request shapes stay honest.
"""

from __future__ import annotations

import io
import json
import threading
import urllib.error
import urllib.request
import zipfile
from http.server import ThreadingHTTPServer

import pytest

import breakout_web


@pytest.fixture
def server():
    breakout_web.Handler.state = breakout_web.State()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), breakout_web.Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}"
    httpd.shutdown()
    httpd.server_close()


def _post(base, path, payload=None, raw=None, headers=None):
    body = raw if raw is not None else json.dumps(payload).encode()
    hdrs = headers or ({} if raw is not None else {"Content-Type": "application/json"})
    return urllib.request.urlopen(urllib.request.Request(base + path, body, hdrs))


def _upload(base, pdf_path):
    res = _post(base, "/api/analyze", raw=pdf_path.read_bytes(),
                headers={"X-Filename": pdf_path.name})
    return json.load(res)


@pytest.fixture
def loaded(server, band_book):
    return server, _upload(server, band_book)


# --------------------------------------------------------------------------


def test_a_file_can_be_opened_into_the_ui(band_book):
    """`--serve book.pdf` lands on the parts, with nothing to drop.

    This is how opening a PDF with the app has to work on a machine with no
    terminal to type a path into.
    """
    breakout_web.Handler.state = breakout_web.State()
    breakout_web.Handler.opened = breakout_web.analyse(
        breakout_web.Handler.state, band_book.read_bytes(), band_book.name)
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), breakout_web.Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        base = f"http://127.0.0.1:{httpd.server_address[1]}"
        opened = json.load(urllib.request.urlopen(base + "/api/opened"))
        assert opened["title"] == "Test Song"
        assert len(opened["pages"]) == 6
        assert opened["owners"][1] == "Full Score"
    finally:
        breakout_web.Handler.opened = None
        httpd.shutdown()
        httpd.server_close()


def test_page_is_served(server):
    html = urllib.request.urlopen(server + "/").read().decode()
    assert "<title>PDF Music Breakout</title>" in html


def test_analyze_reports_the_detected_parts(loaded):
    _, data = loaded
    assert data["title"] == "Test Song"
    assert len(data["pages"]) == 6
    starts = [(p["n"], p["label"]) for p in data["pages"] if p["label"]]
    assert starts == [
        (2, "Full Score"), (3, "Full Score"),
        (4, "Piano/Vocal"), (5, "Alto Saxophone"), (6, "Drum Set"),
    ]


def test_a_clean_file_is_not_flagged_as_suspect(loaded):
    """Regression: the flag counted labelled pages, not grouped parts.

    A part name repeated in every running header is normal, so counting
    pages raised a false alarm on a perfectly good document.
    """
    _, data = loaded
    assert data["suspect"] is False
    assert data["scanned"] is False


def test_thumbnails_render_as_png(loaded):
    base, data = loaded
    blob = urllib.request.urlopen(f"{base}/api/thumb/{data['sid']}/0").read()
    assert blob.startswith(b"\x89PNG\r\n")


def test_analyze_says_who_owns_every_page(loaded):
    """The tree needs an owner per page, not just where parts begin."""
    _, data = loaded
    assert data["owners"] == [
        None, "Full Score", "Full Score", "Piano/Vocal",
        "Alto Saxophone", "Drum Set",
    ]


def test_preview_renders_a_page_larger_than_its_thumbnail(loaded):
    base, data = loaded
    small = urllib.request.urlopen(f"{base}/api/thumb/{data['sid']}/1").read()
    big = urllib.request.urlopen(f"{base}/api/page/{data['sid']}/1?w=1400").read()
    assert big.startswith(b"\x89PNG\r\n")
    assert len(big) > len(small), "a preview that is no bigger cannot be read"


def test_ownership_can_move_one_page_between_parts(loaded):
    """What a drag does, and what per-page labels cannot say.

    Page 4 belongs to the piano and page 5 to the sax; moving page 4 into the
    sax part leaves the piano with nothing and the sax with two pages, which
    is not expressible as "this page starts a part".
    """
    base, data = loaded
    owners = list(data["owners"])
    owners[3] = "Alto Saxophone"
    plan = json.load(_post(base, "/api/plan", {
        "sid": data["sid"], "owners": owners, "title": "Test Song",
    }))
    by_name = {f["name"]: f for f in plan["files"]}
    assert "Piano" not in by_name, "its only page went to the saxophone"
    assert by_name["Alto_Sax"]["pages"] == [4, 5]


def test_a_page_can_be_dropped_into_the_front_matter(loaded):
    """Front matter is no longer only the pages before the first part."""
    base, data = loaded
    owners = list(data["owners"])
    owners[5] = None
    plan = json.load(_post(base, "/api/plan", {
        "sid": data["sid"], "owners": owners, "title": "Test Song",
    }))
    assert plan["front"] == [1, 6]
    assert "Drums" not in {f["name"] for f in plan["files"]}


def test_plan_names_the_files_that_would_be_written(loaded):
    base, data = loaded
    plan = json.load(_post(base, "/api/plan", {
        "sid": data["sid"],
        "labels": [p["label"] for p in data["pages"]],
        "title": "Test Song",
        "prefix": "03-",
    }))
    assert plan["front"] == [1], "the cover page precedes the first part"
    assert [f["file"] for f in plan["files"]] == [
        "03-Test Song-Score.pdf",
        "03-Test Song-Piano.pdf",
        "03-Test Song-Alto_Sax.pdf",
        "03-Test Song-Drums.pdf",
    ]


def test_unticking_a_page_merges_it_into_the_part_above(loaded):
    base, data = loaded
    labels = [p["label"] for p in data["pages"]]
    labels[4] = None  # page 5 is no longer its own part
    plan = json.load(_post(base, "/api/plan", {
        "sid": data["sid"], "labels": labels, "title": "Test Song",
    }))
    names = {f["file"]: f["count"] for f in plan["files"]}
    assert "Test Song-Alto_Sax.pdf" not in names
    assert names["Test Song-Piano.pdf"] == 2


def test_renaming_a_part_renames_its_file(loaded):
    base, data = loaded
    labels = [p["label"] for p in data["pages"]]
    labels[5] = "Percussion 2"
    plan = json.load(_post(base, "/api/plan", {
        "sid": data["sid"], "labels": labels, "title": "Test Song",
    }))
    assert "Test Song-Perc2.pdf" in {f["file"] for f in plan["files"]}


def test_export_returns_a_zip_of_every_part(loaded):
    base, data = loaded
    res = _post(base, "/api/export", {
        "sid": data["sid"],
        "labels": [p["label"] for p in data["pages"]],
        "title": "Test Song",
    })
    assert res.headers["Content-Type"] == "application/zip"
    zf = zipfile.ZipFile(io.BytesIO(res.read()))
    assert sorted(zf.namelist()) == [
        "Test Song-Alto_Sax.pdf", "Test Song-Drums.pdf",
        "Test Song-Piano.pdf", "Test Song-Score.pdf",
    ]
    assert zf.read("Test Song-Score.pdf").startswith(b"%PDF")


def test_export_can_write_into_a_folder(loaded, tmp_path):
    base, data = loaded
    dest = tmp_path / "show" / "03-Test Song"
    out = json.load(_post(base, "/api/export", {
        "sid": data["sid"],
        "labels": [p["label"] for p in data["pages"]],
        "title": "Test Song", "dest": str(dest), "overwrite": True,
    }))
    assert len(out["saved"]) == 4
    assert sorted(p.name for p in dest.glob("*.pdf")) == [
        "Test Song-Alto_Sax.pdf", "Test Song-Drums.pdf",
        "Test Song-Piano.pdf", "Test Song-Score.pdf",
    ]


def test_export_refuses_a_relative_folder(loaded):
    base, data = loaded
    with pytest.raises(urllib.error.HTTPError) as exc:
        _post(base, "/api/export", {
            "sid": data["sid"],
            "labels": [p["label"] for p in data["pages"]],
            "dest": "some/relative/path",
        })
    assert "full path" in json.load(exc.value)["error"]


def test_front_matter_can_be_attached_to_every_part(loaded, tmp_path):
    base, data = loaded
    dest = tmp_path / "out"
    _post(base, "/api/export", {
        "sid": data["sid"],
        "labels": [p["label"] for p in data["pages"]],
        "title": "Test Song", "frontMatter": "attach",
        "dest": str(dest), "overwrite": True,
    })
    import pymupdf
    doc = pymupdf.open(dest / "Test Song-Piano.pdf")
    assert len(doc) == 2
    doc.close()


@pytest.mark.parametrize("blob,expected", [
    (b"this is not a pdf", "doesn't look like a PDF"),
    (b"", "no file received"),
])
def test_bad_uploads_are_explained(server, blob, expected):
    with pytest.raises(urllib.error.HTTPError) as exc:
        _post(server, "/api/analyze", raw=blob, headers={"X-Filename": "x.pdf"})
    assert expected in json.load(exc.value)["error"]


def test_an_unknown_session_is_reported(server):
    with pytest.raises(urllib.error.HTTPError) as exc:
        _post(server, "/api/plan", {"sid": "nope", "labels": []})
    assert "no longer loaded" in json.load(exc.value)["error"]


def test_a_scan_is_flagged(server, make_pdf):
    path = make_pdf([{"part": None, "title": None, "body": None}] * 3)
    data = _upload(server, path)
    assert data["scanned"] is True
