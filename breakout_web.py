"""A local review-and-correct UI for pdf-music-breakout.

Detection gets the part boundaries right most of the time, but not always,
and a wrong answer is silent -- a merged book once turned 58 pages into 58
"parts" without complaint. This serves a small page-by-page review screen so
you can see what was detected, fix the few it got wrong, and export.

Runs entirely on the machine you start it on: bound to the loopback
interface, no data leaves the process, and nothing is written until you ask
for it. Uses only the standard library beyond what the splitter already
needs.
"""

from __future__ import annotations

import io
import json
import secrets
import socket
import threading
import webbrowser
import zipfile
from collections import OrderedDict
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pymupdf

import pdf_music_breakout as pmb

MAX_UPLOAD = 200 * 1024 * 1024  # a very long score, with room to spare
THUMB_WIDTH = 240
# Zoom snaps to these widths in pixels. Rendering a fresh bitmap for every
# pixel of a drag would keep the server busy for no visible gain.
PREVIEW_WIDTHS = (700, 1000, 1400, 2000, 2800, 3600)
PREVIEW_CACHE = 8  # rendered pages held per session


@dataclass
class Session:
    """One uploaded document, held in memory for the life of the server."""

    doc: pymupdf.Document
    filename: str
    title: str
    labels: list[str | None]
    thumbs: dict[int, bytes] = field(default_factory=dict)
    previews: OrderedDict = field(default_factory=OrderedDict)

    def thumbnail(self, page_no: int) -> bytes:
        """Render a page thumbnail, caching it for repeat views."""
        if page_no not in self.thumbs:
            page = self.doc[page_no]
            scale = THUMB_WIDTH / page.rect.width
            pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False)
            self.thumbs[page_no] = pix.tobytes("png")
        return self.thumbs[page_no]

    def preview(self, page_no: int, width: int) -> bytes:
        """Render a page big enough to read, at one of a few fixed widths.

        A handful of renders are kept: paging back and forth between two parts
        to compare them is the whole point, and re-rasterising a score page
        each time is slow enough to feel.
        """
        width = next((w for w in PREVIEW_WIDTHS if w >= width), PREVIEW_WIDTHS[-1])
        key = (page_no, width)
        if key in self.previews:
            self.previews.move_to_end(key)
            return self.previews[key]

        page = self.doc[page_no]
        scale = width / page.rect.width
        pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False)
        self.previews[key] = pix.tobytes("png")
        while len(self.previews) > PREVIEW_CACHE:
            self.previews.popitem(last=False)
        return self.previews[key]


class State:
    """Server-wide session store, guarded for the threading server."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._sessions: dict[str, Session] = {}

    def add(self, session: Session) -> str:
        sid = secrets.token_urlsafe(12)
        with self._lock:
            # Only the current document matters; drop anything older so a
            # long session doesn't accumulate whole PDFs in memory.
            for old in self._sessions.values():
                old.doc.close()
            self._sessions.clear()
            self._sessions[sid] = session
        return sid

    def get(self, sid: str) -> Session | None:
        with self._lock:
            return self._sessions.get(sid)


# --------------------------------------------------------------------------
# Planning and export, both driven by the labels the UI sends back
# --------------------------------------------------------------------------


def build_plan(session: Session, owners: list[str | None], options: dict):
    """Group the edited page ownership into the files that would be written."""
    aliases = pmb.load_aliases(None, options.get("renames") or [])
    parts, front = pmb.group_owners(owners, aliases, len(session.doc))

    title = (options.get("title") or "").strip() or session.title
    prefix = options.get("prefix") or ""
    template = options.get("template") or "{prefix}{title}-{part}.pdf"
    attach = options.get("frontMatter") == "attach"

    files = []
    for part in parts:
        try:
            name = template.format(prefix=prefix, title=title, part=part.name)
        except (KeyError, IndexError):
            name = f"{prefix}{title}-{part.name}.pdf"
        files.append({
            "name": part.name,
            "label": part.label,
            "file": pmb.safe_filename(name),
            "pages": [p + 1 for p in part.pages],
            "count": len(part.pages) + (len(front) if attach else 0),
        })
    return parts, front, files, title


def render_parts(session: Session, parts, front, files, options):
    """Produce the finished PDFs as (filename, bytes) pairs."""
    paper = pmb.resolve_paper(options.get("paper") or "auto", session.doc)
    margin = float(options.get("margin") or 0)
    rotate = options.get("rotate") or "cw"
    attach = front if options.get("frontMatter") == "attach" else []
    title = options.get("_title") or session.title

    built = []
    for part, meta in zip(parts, files):
        out = pymupdf.open()
        for pno in attach + part.pages:
            pmb.add_page(out, session.doc, pno, paper, margin, rotate, False)
        out.set_metadata({
            "title": f"{title} - {part.label}" if title else part.label,
            "author": session.doc.metadata.get("author", "") or "",
            "subject": part.label,
            "creator": "pdf-music-breakout",
            "producer": "pdf-music-breakout",
        })
        buf = out.tobytes(garbage=4, deflate=True, clean=True)
        out.close()
        built.append((meta["file"], buf))
    return built


def analyse(state: "State", data: bytes, filename: str) -> dict:
    """Read a PDF into a session, and describe what detection made of it."""
    try:
        doc = pymupdf.open(stream=data, filetype="pdf")
    except Exception:
        raise ValueError("that doesn't look like a PDF")
    if doc.needs_pass:
        raise ValueError("this PDF is password-protected; decrypt it first")
    if len(doc) == 0:
        raise ValueError("this PDF has no pages")

    labels, title = pmb.detect_page_labels(doc, 0.15, 0.4)
    if not title:
        title = pmb.default_title(doc, Path(filename))

    session = Session(doc=doc, filename=filename, title=title, labels=labels)
    sid = state.add(session)

    text_pages = sum(1 for page in doc if page.get_text("text").strip())
    # Judge the result by how many distinct parts it groups into, not how many
    # pages carry a label: a part name repeated in every running header is
    # normal and says nothing about whether detection worked.
    grouped, _ = pmb.group_labels(labels, pmb.DEFAULT_ALIASES, len(doc))
    return {
        "sid": sid,
        "filename": filename,
        "title": title,
        "owners": pmb.own_pages(labels, len(doc)),
        "pages": [
            {
                "n": i + 1,
                "label": labels[i],
                "width": round(doc[i].rect.width),
                "height": round(doc[i].rect.height),
            }
            for i in range(len(doc))
        ],
        "scanned": text_pages < len(doc) / 2,
        "suspect": len(grouped) > max(6, len(doc) * 0.6),
    }


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    #: Set when a PDF was named on the command line, so the page can pick it
    #: up instead of waiting to be dropped on.
    opened: dict | None = None

    server_version = "pdf-music-breakout"
    state: State

    def log_message(self, fmt, *args):  # quieter console
        pass

    # -- helpers ----------------------------------------------------------

    def _send(self, code: int, body: bytes, ctype: str, extra: dict | None = None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # This only ever talks to its own page on loopback.
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, payload: dict):
        self._send(code, json.dumps(payload).encode(), "application/json")

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_UPLOAD:
            raise ValueError(f"file is larger than {MAX_UPLOAD // (1024 * 1024)} MB")
        return self.rfile.read(length)

    def _session(self, sid: str) -> Session:
        session = self.state.get(sid)
        if session is None:
            raise KeyError("that document is no longer loaded -- drop it in again")
        return session

    # -- routes -----------------------------------------------------------

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            self._send(200, PAGE_HTML.encode(), "text/html; charset=utf-8")
            return
        if path == "/api/opened":
            self._json(200, self.opened or {})
            return
        if path.startswith("/api/page/"):
            try:
                _, _, _, sid, page_no = path.split("/", 4)
                width = int((parse_qs(urlparse(self.path).query).get("w") or ["1000"])[0])
                session = self._session(sid)
                self._send(200, session.preview(int(page_no), width), "image/png")
            except (KeyError, ValueError, IndexError) as exc:
                self._json(404, {"error": str(exc)})
            return
        if path.startswith("/api/thumb/"):
            try:
                _, _, _, sid, page_no = path.split("/", 4)
                session = self._session(sid)
                self._send(200, session.thumbnail(int(page_no)), "image/png")
            except (KeyError, ValueError, IndexError) as exc:
                self._json(404, {"error": str(exc)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            if path == "/api/analyze":
                self._analyze()
            elif path == "/api/open":
                self._open()
            elif path == "/api/plan":
                self._plan()
            elif path == "/api/export":
                self._export()
            else:
                self._json(404, {"error": "not found"})
        except Exception as exc:  # surface the reason in the UI
            self._json(400, {"error": str(exc)})

    def _analyze(self):
        data = self._read_body()
        filename = self.headers.get("X-Filename") or "combined.pdf"
        if not data:
            raise ValueError("no file received")
        self._json(200, analyse(self.state, data, filename))

    def _open(self):
        """Read a PDF the desktop shell picked, by path rather than upload.

        The shell has the file already; sending its bytes back to a server on
        this same machine would only be slower. Reading it is no more than the
        export side already does when it writes into a folder you name, and
        the server listens on the loopback interface only.
        """
        body = json.loads(self._read_body() or b"{}")
        source = Path(body.get("path", "")).expanduser()
        if not source.is_file():
            raise ValueError(f"no such file: {source}")
        opened = analyse(self.state, source.read_bytes(), source.name)
        type(self).opened = opened
        self._json(200, opened)

    @staticmethod
    def _owners(session: Session, body: dict) -> list[str | None]:
        """Read page ownership from the request, however it was sent.

        The tree sends who owns every page, which is the only way to say that
        page 7 belongs to the piano while page 6 belongs to the guitar. The
        older shape sends a label only where a part begins.
        """
        n = len(session.doc)
        if body.get("owners") is not None:
            return [x or None for x in body["owners"]][:n]
        return pmb.own_pages([x or None for x in body.get("labels", [])], n)

    def _plan(self):
        body = json.loads(self._read_body() or b"{}")
        session = self._session(body.get("sid", ""))
        _, front, files, title = build_plan(session, self._owners(session, body), body)
        self._json(200, {
            "files": files,
            "front": [p + 1 for p in front],
            "title": title,
        })

    def _export(self):
        body = json.loads(self._read_body() or b"{}")
        session = self._session(body.get("sid", ""))
        parts, front, files, title = build_plan(session, self._owners(session, body), body)
        if not parts:
            raise ValueError("no parts to write -- mark at least one page as a part")

        body["_title"] = title
        built = render_parts(session, parts, front, files, body)

        dest = (body.get("dest") or "").strip()
        if dest:
            folder = Path(dest).expanduser()
            if not folder.is_absolute():
                raise ValueError("give the folder as a full path")
            folder.mkdir(parents=True, exist_ok=True)
            written = []
            for name, blob in built:
                target = folder / name
                if target.exists() and not body.get("overwrite"):
                    written.append({"file": str(target), "skipped": True})
                    continue
                target.write_bytes(blob)
                written.append({"file": str(target), "skipped": False})
            self._json(200, {"saved": written, "folder": str(folder)})
            return

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for name, blob in built:
                zf.writestr(name, blob)
        stem = pmb.safe_filename(f"{title or 'parts'}.zip")
        self._send(200, buf.getvalue(), "application/zip",
                   {"Content-Disposition": f'attachment; filename="{stem}"'})


def _free_port(preferred: int) -> int:
    with socket.socket() as sock:
        try:
            sock.bind(("127.0.0.1", preferred))
            return preferred
        except OSError:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]


def serve(port: int = 8756, open_browser: bool = True,
          source: Path | None = None) -> int:
    """Run the review UI until interrupted.

    A PDF named on the command line is read before the browser opens, so
    `pdf-music-breakout book.pdf --serve` lands straight on the parts -- which
    is what opening a file with the app should do on a machine with no
    terminal to type a path into.
    """
    port = _free_port(port)
    Handler.state = State()
    Handler.opened = None
    if source is not None:
        Handler.opened = analyse(Handler.state, Path(source).read_bytes(),
                                 Path(source).name)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    # Flushed, because something is usually reading this: a wrapper that
    # starts the server and waits to be told where it is sees nothing at all
    # while Python holds a block-buffered pipe.
    print(f"pdf-music-breakout is running at {url}", flush=True)
    print("Drop a combined PDF onto the page. Press Ctrl+C to stop.", flush=True)
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        httpd.server_close()
    return 0


# --------------------------------------------------------------------------
# The page
# --------------------------------------------------------------------------

PAGE_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PDF Music Breakout</title>
<style>
  :root {
    --bg: #f6f6f4; --panel: #fff; --ink: #1a1a19; --muted: #6b6b66;
    --line: #dfdfd9; --accent: #2f6f4f; --accent-ink: #fff;
    --warn-bg: #fdf3e3; --warn-line: #e0bb77; --warn-ink: #6b4a12;
    --radius: 10px;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #17181a; --panel: #1f2124; --ink: #e9e9e6; --muted: #9a9a94;
      --line: #34363a; --accent: #57a97d; --accent-ink: #10221a;
      --warn-bg: #33280f; --warn-line: #7a6122; --warn-ink: #f0d9a8;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--ink);
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  header {
    padding: 18px 24px; border-bottom: 1px solid var(--line);
    background: var(--panel); position: sticky; top: 0; z-index: 5;
    display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap;
  }
  h1 { font-size: 17px; margin: 0; letter-spacing: -0.01em; }
  .sub { color: var(--muted); font-size: 13px; }
  main { max-width: 1500px; margin: 0 auto; padding: 20px 16px 80px; }

  #drop {
    border: 2px dashed var(--line); border-radius: var(--radius);
    padding: 56px 24px; text-align: center; background: var(--panel);
    cursor: pointer; transition: border-color .15s, background .15s;
  }
  #drop.over { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 8%, var(--panel)); }
  #drop h2 { margin: 0 0 6px; font-size: 16px; }
  #drop p { margin: 0; color: var(--muted); font-size: 13px; }

  .card {
    background: var(--panel); border: 1px solid var(--line);
    border-radius: var(--radius); padding: 16px; margin-bottom: 16px;
  }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 12px; }
  label.field { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--muted); }
  input, select, button { font: inherit; }
  input[type=text], select {
    padding: 7px 9px; border: 1px solid var(--line); border-radius: 7px;
    background: var(--bg); color: var(--ink); width: 100%;
  }
  button {
    padding: 9px 16px; border-radius: 8px; border: 1px solid var(--line);
    background: var(--panel); color: var(--ink); cursor: pointer;
  }
  button.primary { background: var(--accent); color: var(--accent-ink); border-color: transparent; font-weight: 600; }
  button.small { padding: 3px 9px; font-size: 12px; }
  button:disabled { opacity: .5; cursor: default; }

  .warn {
    background: var(--warn-bg); border: 1px solid var(--warn-line);
    color: var(--warn-ink); padding: 10px 12px; border-radius: 8px;
    font-size: 13px; margin-bottom: 14px;
  }
  .err { background: #fde8e6; border-color: #e0a49c; color: #7a2418; }
  @media (prefers-color-scheme: dark) { .err { background: #3a1c18; border-color: #7d3a2e; color: #f3c3ba; } }

  h3 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em;
       color: var(--muted); margin: 0 0 10px; font-weight: 600; }

  /* ---- the two columns: the tree, and the page it is pointing at ---- */
  .columns { display: grid; grid-template-columns: minmax(420px, 1fr) minmax(360px, 1fr); gap: 16px; align-items: start; }
  @media (max-width: 980px) { .columns { grid-template-columns: 1fr; } }
  .right { position: sticky; top: 76px; }

  /* ---- tree ---- */
  .node {
    display: flex; gap: 10px; align-items: flex-start;
    padding: 7px 8px; border-radius: 8px; border: 1px solid transparent;
    cursor: default;
  }
  .node + .node { margin-top: 2px; }
  .node.sel { background: color-mix(in srgb, var(--accent) 12%, var(--panel)); }
  .node.over { border-color: var(--accent); background: color-mix(in srgb, var(--accent) 18%, var(--panel)); }
  .node.child { margin-left: 30px; }
  .node img {
    border: 1px solid var(--line); border-radius: 3px; background: #fff;
    display: block; cursor: grab; flex: none;
  }
  .node.sel img { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
  .node img.big { width: 62px; }
  .node img.small { width: 42px; }
  .twist {
    flex: none; width: 18px; height: 18px; padding: 0; border: 0; background: none;
    color: var(--muted); cursor: pointer; font-size: 11px; line-height: 18px;
  }
  .body { min-width: 0; flex: 1; }
  .name { font-weight: 600; }
  .name input { max-width: 280px; }
  .meta { font-size: 12px; color: var(--muted); }
  .file { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px;
          color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chk { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }

  /* ---- preview ---- */
  #previewBar { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; flex-wrap: wrap; }
  #previewBar .spacer { flex: 1; }
  #zoom { width: auto; }
  #previewPane {
    height: min(72vh, 900px); overflow: auto; background: var(--bg);
    border: 1px solid var(--line); border-radius: 8px; padding: 10px;
    display: flex; justify-content: center; align-items: flex-start;
  }
  #previewImg { display: block; background: #fff; box-shadow: 0 1px 6px rgba(0,0,0,.18); }
  #previewNone { color: var(--muted); font-size: 13px; padding: 40px 0; }

  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  td { padding: 5px 0; border-top: 1px solid var(--line); vertical-align: top; }
  td:first-child { font-weight: 600; }
  td.n { text-align: right; color: var(--muted); white-space: nowrap; padding-left: 12px; }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
  .cont { color: var(--muted); font-style: italic; }

  #bar {
    position: fixed; left: 0; right: 0; bottom: 0; background: var(--panel);
    border-top: 1px solid var(--line); padding: 12px 24px;
    display: flex; gap: 12px; align-items: center; justify-content: flex-end;
  }
  #bar .spacer { flex: 1; color: var(--muted); font-size: 13px; }
  .hide { display: none !important; }
</style>
</head>
<body>
<header>
  <h1>PDF Music Breakout</h1>
  <span class="sub" id="opened">Split a combined score into one printable PDF per part</span>
  <button id="another" class="small hide">Open another PDF</button>
</header>

<main>
  <div id="drop">
    <h2>Drop a combined PDF here</h2>
    <p>or click to choose one &mdash; nothing leaves this machine</p>
    <input type="file" id="file" accept="application/pdf,.pdf" hidden>
  </div>

  <div id="notice"></div>

  <div id="app" class="hide">
    <div class="card">
      <h3>Naming &amp; paper</h3>
      <div class="grid">
        <label class="field">Song title
          <input type="text" id="title"></label>
        <label class="field">Filename prefix
          <input type="text" id="prefix" placeholder="e.g. 03-"></label>
        <label class="field">Paper
          <select id="paper">
            <option value="auto">Auto &mdash; match the document</option>
            <option value="keep">Keep every page as-is</option>
            <option value="letter">Letter</option>
            <option value="a4">A4</option>
            <option value="tabloid">Tabloid</option>
          </select></label>
        <label class="field">Cover / copyright page
          <select id="frontMatter">
            <option value="skip">Leave out</option>
            <option value="attach">Add to every part</option>
          </select></label>
      </div>
    </div>

    <div class="columns">
      <div class="card">
        <h3>Parts</h3>
        <p class="sub" style="margin-top:-6px">
          Each part is a row, with its remaining pages inside it. Drag a
          page&rsquo;s picture onto another part to move it there.
          <button id="expandAll" class="small">Expand all</button>
          <button id="collapseAll" class="small">Collapse all</button>
        </p>
        <div id="tree"></div>
      </div>

      <div class="right">
        <div class="card">
          <div id="previewBar">
            <button id="prev" class="small" title="Previous page">&larr;</button>
            <button id="next" class="small" title="Next page">&rarr;</button>
            <strong id="previewTitle">Page</strong>
            <span class="spacer"></span>
            <button id="zoomOut" class="small" title="Zoom out">&minus;</button>
            <select id="zoom">
              <option value="width">Fit width</option>
              <option value="fit">Fit page</option>
              <option value="1">100%</option>
              <option value="1.5">150%</option>
              <option value="2">200%</option>
              <option value="3">300%</option>
            </select>
            <button id="zoomIn" class="small" title="Zoom in">+</button>
          </div>
          <div class="meta" id="previewNote"></div>
          <div id="previewPane">
            <img id="previewImg" alt="" class="hide">
            <div id="previewNone">Select a part or a page to see it here.</div>
          </div>
        </div>

        <div class="card">
          <h3>Files to be written</h3>
          <table id="summary"></table>
        </div>
      </div>
    </div>
  </div>
</main>

<div id="bar" class="hide">
  <span class="spacer" id="status"></span>
  <input type="text" id="dest" placeholder="Optional: full path of a folder to save into" style="max-width:380px">
  <button id="save">Save to folder</button>
  <button id="zip" class="primary">Download .zip</button>
</div>

<script>
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// owners[i] is the part page i belongs to, or null for front matter. That is
// the whole editable state: a drag rewrites entries in it, and everything
// else -- the tree, the file list -- is what the server makes of it.
let sid = null, pages = [], owners = [], detected = [];
let groups = [], expanded = new Set(), planTimer = null;
let sel = null;                       // "g:<key>" or "p:<index>"
let zoomMode = 'width', zoomFactor = 1;

function notice(msg, kind) {
  $('notice').innerHTML = msg ? `<div class="warn ${kind || ''}">${msg}</div>` : '';
}

/* ---------- upload ---------- */
const drop = $('drop');
drop.onclick = () => $('file').click();
$('another').onclick = () => $('file').click();
// A new file can still be dropped anywhere once the tree has taken over.
['dragenter', 'dragover'].forEach(ev =>
  document.addEventListener(ev, e => { if (e.dataTransfer.types.includes('Files')) e.preventDefault(); }));
document.addEventListener('drop', e => {
  const f = e.dataTransfer.files[0];
  if (!f) return;
  if (f.type === 'application/pdf' || /\.pdf$/i.test(f.name)) {
    e.preventDefault();
    upload(f);
  }
});
$('file').onchange = (e) => { if (e.target.files[0]) upload(e.target.files[0]); };
['dragenter', 'dragover'].forEach(ev =>
  drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach(ev =>
  drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.remove('over'); }));

async function upload(file) {
  notice('Reading ' + file.name + '…');
  try {
    const res = await fetch('/api/analyze', {
      method: 'POST',
      headers: { 'X-Filename': file.name },
      body: await file.arrayBuffer(),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'could not read that file');
    load(data);
  } catch (err) {
    notice(err.message, 'err');
  }
}

function load(data) {
  sid = data.sid;
  pages = data.pages;
  owners = data.owners.slice();
  detected = pages.map(p => p.label);
  expanded = new Set();
  sel = null;
  $('title').value = data.title || '';
  $('app').classList.remove('hide');
  $('bar').classList.remove('hide');
  $('drop').classList.add('hide');
  $('another').classList.remove('hide');
  $('opened').textContent = data.filename + ' · ' + pages.length + ' pages';

  let msg = '';
  if (data.scanned)
    msg = 'These pages have little or no text, so this looks like a scan. ' +
          'Detection will be poor — drag the pages into the right parts by hand.';
  else if (data.suspect)
    msg = 'Nearly every page looks like a new part, which usually means the ' +
          'header was misread. Check the parts below before exporting.';
  notice(msg);
  plan();
}

// A file named on the command line is already read by the time the page
// loads; there is nothing to drop.
fetch('/api/opened').then(r => r.json()).then(d => { if (d && d.sid) load(d); })
  .catch(() => {});

/* ---------- the tree ---------- */
function groupOf(i) { return groups.find(g => g.pages.includes(i)); }
function selPage() {
  if (!sel) return null;
  if (sel.startsWith('p:')) return +sel.slice(2);
  const g = groups.find(x => x.key === sel.slice(2));
  return g ? g.pages[0] : null;
}

function select(node) { sel = node; renderTree(); showPreview(); }

function thumb(i, cls) {
  const img = document.createElement('img');
  img.className = cls;
  img.loading = 'lazy';
  img.src = `/api/thumb/${sid}/${i}`;
  img.alt = 'page ' + (i + 1);
  img.draggable = true;
  img.title = 'Drag onto another part to move this page there';
  return img;
}

// Both row kinds accept a drop; a page row stands in for the part it is in.
function acceptDrops(el, payload, targetKey) {
  el.addEventListener('dragover', e => { e.preventDefault(); el.classList.add('over'); });
  el.addEventListener('dragleave', () => el.classList.remove('over'));
  el.addEventListener('drop', e => {
    e.preventDefault();
    el.classList.remove('over');
    dropped(e.dataTransfer.getData('text/plain'), targetKey);
  });
  if (payload) {
    el.querySelector('img').addEventListener('dragstart', e => {
      e.dataTransfer.setData('text/plain', payload);
      e.dataTransfer.effectAllowed = 'move';
    });
  }
}

function dropped(payload, targetKey) {
  if (!payload || payload === targetKey) return;
  let moved = [];
  if (payload.startsWith('p:')) moved = [+payload.slice(2)];
  else {
    const g = groups.find(x => x.key === payload.slice(2));
    moved = g ? g.pages.slice() : [];
  }
  if (!moved.length) return;
  const target = groups.find(x => x.key === targetKey.slice(2));
  if (targetKey.startsWith('p:') || !target) {
    const g = groupOf(+targetKey.slice(2));
    if (!g || moved.includes(+targetKey.slice(2))) return;
    return assign(moved, g);
  }
  assign(moved, target);
}

function assign(idxs, group) {
  const label = group.front ? null : group.label;
  idxs.forEach(i => { owners[i] = label; });
  expanded.add(group.key);
  sel = 'p:' + Math.min.apply(null, idxs);
  plan();
}

// Break a part in two, from this page on. Its own header often names the part
// it is already in, and a name that regroups the same way would look like
// nothing happened -- so that case gets a plain, obviously-editable name.
function splitAt(i) {
  const old = owners[i];
  const same = (a, b) => (a || '').trim().toLowerCase() === (b || '').trim().toLowerCase();
  let name = detected[i] || '';
  if (!name || same(name, old)) {
    name = 'Part ' + (i + 1);
    let n = 2;
    while (groups.some(g => same(g.label, name))) name = 'Part ' + (i + 1) + ' ' + n++;
  }
  for (let j = i; j < owners.length && owners[j] === old; j++) owners[j] = name;
  sel = 'p:' + i;
  plan();
}

function rename(group, value) {
  const name = value.trim();
  if (!name || name === group.label) return;
  owners = owners.map(o => (o === group.label ? name : o));
  plan();
}

function groupRow(g) {
  const row = document.createElement('div');
  row.className = 'node' + (sel === 'g:' + g.key ? ' sel' : '');
  row.onclick = () => select('g:' + g.key);

  const twist = document.createElement('button');
  twist.className = 'twist';
  if (g.pages.length > 1) {
    twist.textContent = expanded.has(g.key) ? '▼' : '▶';
    twist.title = expanded.has(g.key) ? 'Hide these pages' : 'Show the rest of this part';
    twist.onclick = (e) => {
      e.stopPropagation();
      expanded.has(g.key) ? expanded.delete(g.key) : expanded.add(g.key);
      renderTree();
    };
  }
  row.appendChild(twist);
  row.appendChild(thumb(g.pages[0], 'big'));

  const body = document.createElement('div');
  body.className = 'body';
  const name = document.createElement('div');
  name.className = 'name';
  if (g.front) {
    name.textContent = 'Front matter (cover / copyright)';
  } else {
    const input = document.createElement('input');
    input.type = 'text';
    input.value = g.label;
    input.onclick = (e) => e.stopPropagation();
    input.onchange = () => rename(g, input.value);
    input.onblur = () => rename(g, input.value);
    name.appendChild(input);
  }
  body.appendChild(name);

  const meta = document.createElement('div');
  meta.className = 'meta';
  meta.textContent = `${g.pages.length} page${g.pages.length === 1 ? '' : 's'} · ${ranges(g.pages.map(i => i + 1))}`;
  body.appendChild(meta);

  const file = document.createElement('div');
  file.className = 'file';
  file.textContent = g.front
    ? ($('frontMatter').value === 'attach' ? 'added to the front of every part'
                                           : 'left out of the exported parts')
    : g.file;
  body.appendChild(file);
  row.appendChild(body);

  acceptDrops(row, 'g:' + g.key, 'g:' + g.key);
  return row;
}

function pageRow(i, g) {
  const p = pages[i];
  const row = document.createElement('div');
  row.className = 'node child' + (sel === 'p:' + i ? ' sel' : '');
  row.onclick = () => select('p:' + i);
  row.appendChild(thumb(i, 'small'));

  const body = document.createElement('div');
  body.className = 'body';
  const meta = document.createElement('div');
  meta.className = 'meta';
  meta.textContent = `Page ${p.n} — ${p.width}×${p.height} pt` +
                     (p.width > p.height ? ' · landscape' : '');
  body.appendChild(meta);

  const label = document.createElement('label');
  label.className = 'chk';
  label.onclick = (e) => e.stopPropagation();
  const box = document.createElement('input');
  box.type = 'checkbox';
  box.onchange = () => splitAt(i);
  label.appendChild(box);
  label.appendChild(document.createTextNode('starts a part of its own'));
  body.appendChild(label);
  row.appendChild(body);

  acceptDrops(row, 'p:' + i, 'p:' + i);
  return row;
}

function renderTree() {
  // A moved page can land at the head of its new part, where the tree draws
  // it as the part's own row rather than a child.
  if (sel && sel.startsWith('p:')) {
    const g = groupOf(+sel.slice(2));
    if (g && g.pages[0] === +sel.slice(2)) sel = 'g:' + g.key;
  }
  const host = $('tree');
  host.textContent = '';
  groups.forEach(g => {
    host.appendChild(groupRow(g));
    if (expanded.has(g.key))
      g.pages.slice(1).forEach(i => host.appendChild(pageRow(i, g)));
  });
}

$('expandAll').onclick = () => { groups.forEach(g => expanded.add(g.key)); renderTree(); };
$('collapseAll').onclick = () => { expanded.clear(); renderTree(); };

/* ---------- preview ---------- */
function showPreview() {
  const i = selPage();
  const img = $('previewImg'), none = $('previewNone');
  if (i === null || !pages[i]) {
    img.classList.add('hide'); none.classList.remove('hide');
    $('previewTitle').textContent = 'Page';
    $('previewNote').textContent = '';
    return;
  }
  none.classList.add('hide'); img.classList.remove('hide');

  const p = pages[i], pane = $('previewPane');
  const paneW = Math.max(200, pane.clientWidth - 24);
  const paneH = Math.max(320, pane.clientHeight - 24);
  let cssW;
  if (zoomMode === 'width') cssW = paneW;
  else if (zoomMode === 'fit') cssW = Math.min(paneW, paneH * (p.width / p.height));
  else cssW = p.width * zoomFactor;

  img.style.width = Math.round(cssW) + 'px';
  // Ask for the pixels the screen will actually use, so a zoomed page is
  // sharp rather than a stretched thumbnail.
  const want = Math.round(cssW * Math.min(2, window.devicePixelRatio || 1));
  const src = `/api/page/${sid}/${i}?w=${want}`;
  if (img.getAttribute('src') !== src) img.src = src;

  $('previewTitle').textContent = `Page ${p.n} of ${pages.length}`;
  const g = groupOf(i);
  $('previewNote').textContent = !g ? ''
    : g.front ? 'front matter (cover / copyright)'
    : (g.pages[0] === i ? 'starts ' + g.label : 'continues ' + g.label);
  $('zoom').value = zoomMode === 'width' || zoomMode === 'fit' ? zoomMode : String(zoomFactor);
  $('prev').disabled = i <= 0;
  $('next').disabled = i >= pages.length - 1;
}

function step(delta) {
  const i = selPage();
  const next = (i === null ? 0 : i + delta);
  if (next < 0 || next >= pages.length) return;
  const g = groupOf(next);
  if (g && g.pages[0] !== next) expanded.add(g.key);
  sel = g && g.pages[0] === next ? 'g:' + g.key : 'p:' + next;
  renderTree(); showPreview();
}

function zoomBy(f) {
  const i = selPage();
  if (i === null) return;
  const p = pages[i], pane = $('previewPane');
  const current = zoomMode === 'width' ? (pane.clientWidth - 24) / p.width
                : zoomMode === 'fit' ? Math.min((pane.clientWidth - 24) / p.width,
                                                (pane.clientHeight - 24) / p.height)
                : zoomFactor;
  zoomFactor = Math.min(8, Math.max(0.1, current * f));
  zoomMode = 'factor';
  showPreview();
}

$('prev').onclick = () => step(-1);
$('next').onclick = () => step(1);
$('zoomIn').onclick = () => zoomBy(1.25);
$('zoomOut').onclick = () => zoomBy(0.8);
$('zoom').onchange = () => {
  const v = $('zoom').value;
  if (v === 'width' || v === 'fit') zoomMode = v;
  else { zoomMode = 'factor'; zoomFactor = +v; }
  showPreview();
};
addEventListener('resize', () => { if (zoomMode !== 'factor') showPreview(); });
addEventListener('keydown', e => {
  const typing = /^(INPUT|SELECT|TEXTAREA)$/.test((e.target.tagName || ''));
  if (typing || e.metaKey || e.ctrlKey) return;
  if (e.key === 'ArrowLeft') { step(-1); e.preventDefault(); }
  else if (e.key === 'ArrowRight') { step(1); e.preventDefault(); }
  else if (e.key === '+' || e.key === '=') zoomBy(1.25);
  else if (e.key === '-') zoomBy(0.8);
  else if (e.key === '0') { zoomMode = 'factor'; zoomFactor = 1; showPreview(); }
});

/* ---------- plan ---------- */
function options() {
  return {
    sid, owners,
    title: $('title').value,
    prefix: $('prefix').value,
    paper: $('paper').value,
    frontMatter: $('frontMatter').value,
  };
}

function plan() {
  clearTimeout(planTimer);
  planTimer = setTimeout(async () => {
    const res = await fetch('/api/plan', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(options()),
    });
    const data = await res.json();
    if (!res.ok) { notice(data.error, 'err'); return; }

    // The server owns the grouping -- normalising "Clarinet in Bb 1" into one
    // part with "Clarinet 1" is its job, and doing it twice is how two
    // implementations start disagreeing.
    groups = data.files.map(f => ({
      key: f.name, label: f.label, file: f.file, front: false,
      pages: f.pages.map(n => n - 1),
    }));
    if (data.front.length)
      groups.push({ key: '__front__', label: 'Front matter', file: null,
                    front: true, pages: data.front.map(n => n - 1) });
    groups.sort((a, b) => a.pages[0] - b.pages[0]);
    if (sel === null && groups.length) sel = 'g:' + groups[0].key;

    renderTree();
    showPreview();
    const rows = data.files.map(f =>
      `<tr><td class="mono">${esc(f.file)}</td>` +
      `<td class="n">${f.count} pp &middot; pages ${ranges(f.pages)}</td></tr>`).join('');
    $('summary').innerHTML = rows ||
      '<tr><td class="cont">Nothing yet — drag a page into a part.</td></tr>';
    $('status').textContent =
      `${data.files.length} part${data.files.length === 1 ? '' : 's'}` +
      (data.front.length ? ` · ${data.front.length} front-matter page(s)` : '');
  }, 120);
}

function ranges(list) {
  const out = []; let a = null, b = null;
  for (const n of list) {
    if (a === null) { a = b = n; }
    else if (n === b + 1) { b = n; }
    else { out.push(a === b ? a : a + '-' + b); a = b = n; }
  }
  if (a !== null) out.push(a === b ? a : a + '-' + b);
  return out.join(', ');
}

['title', 'prefix', 'paper', 'frontMatter'].forEach(id => {
  $(id).addEventListener('input', plan);
  $(id).addEventListener('change', plan);
});

/* ---------- export ---------- */
$('zip').onclick = async () => {
  const res = await fetch('/api/export', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(options()),
  });
  if (!res.ok) { notice((await res.json()).error, 'err'); return; }
  const blob = await res.blob();
  const cd = res.headers.get('Content-Disposition') || '';
  const m = /filename="(.+)"/.exec(cd);
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = m ? m[1] : 'parts.zip';
  a.click();
  URL.revokeObjectURL(a.href);
  notice('Downloaded ' + a.download);
};

$('save').onclick = async () => {
  const dest = $('dest').value.trim();
  if (!dest) { notice('Type the full path of a folder to save into, or use Download .zip.', 'err'); return; }
  const res = await fetch('/api/export', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...options(), dest, overwrite: true }),
  });
  const data = await res.json();
  if (!res.ok) { notice(data.error, 'err'); return; }
  notice(`Wrote ${data.saved.length} file(s) to ${esc(data.folder)}`);
};
</script>
</body>
</html>
"""
