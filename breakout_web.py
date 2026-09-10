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
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import pymupdf

import pdf_music_breakout as pmb

MAX_UPLOAD = 200 * 1024 * 1024  # a very long score, with room to spare
THUMB_WIDTH = 240


@dataclass
class Session:
    """One uploaded document, held in memory for the life of the server."""

    doc: pymupdf.Document
    filename: str
    title: str
    labels: list[str | None]
    thumbs: dict[int, bytes] = field(default_factory=dict)

    def thumbnail(self, page_no: int) -> bytes:
        """Render a page thumbnail, caching it for repeat views."""
        if page_no not in self.thumbs:
            page = self.doc[page_no]
            scale = THUMB_WIDTH / page.rect.width
            pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False)
            self.thumbs[page_no] = pix.tobytes("png")
        return self.thumbs[page_no]


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


def build_plan(session: Session, labels: list[str | None], options: dict):
    """Group edited labels into the files that would be written."""
    aliases = pmb.load_aliases(None, options.get("renames") or [])
    parts, front = pmb.group_labels(labels, aliases, len(session.doc))

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


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
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
        sid = self.state.add(session)

        text_pages = sum(1 for page in doc if page.get_text("text").strip())
        # Judge the result by how many distinct parts it groups into, not how
        # many pages carry a label: a part name repeated in every running
        # header is normal and says nothing about whether detection worked.
        grouped, _ = pmb.group_labels(labels, pmb.DEFAULT_ALIASES, len(doc))
        self._json(200, {
            "sid": sid,
            "filename": filename,
            "title": title,
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
        })

    def _plan(self):
        body = json.loads(self._read_body() or b"{}")
        session = self._session(body.get("sid", ""))
        labels = [x or None for x in body.get("labels", [])]
        _, front, files, title = build_plan(session, labels, body)
        self._json(200, {
            "files": files,
            "front": [p + 1 for p in front],
            "title": title,
        })

    def _export(self):
        body = json.loads(self._read_body() or b"{}")
        session = self._session(body.get("sid", ""))
        labels = [x or None for x in body.get("labels", [])]
        parts, front, files, title = build_plan(session, labels, body)
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


def serve(port: int = 8756, open_browser: bool = True) -> int:
    """Run the review UI until interrupted."""
    port = _free_port(port)
    Handler.state = State()
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"pdf-music-breakout is running at {url}")
    print("Drop a combined PDF onto the page. Press Ctrl+C to stop.")
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
  main { max-width: 1120px; margin: 0 auto; padding: 24px 16px 80px; }

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

  .page {
    display: grid; grid-template-columns: 96px 1fr; gap: 14px;
    padding: 12px 0; border-top: 1px solid var(--line); align-items: start;
  }
  .page:first-of-type { border-top: 0; }
  .page img {
    width: 96px; border: 1px solid var(--line); border-radius: 4px;
    background: #fff; display: block;
  }
  .page .no { font-size: 12px; color: var(--muted); margin-bottom: 4px; }
  .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  .row input[type=text] { max-width: 300px; }
  .cont { color: var(--muted); font-size: 13px; font-style: italic; }
  .frontmatter { color: var(--muted); font-size: 13px; }
  .chk { display: flex; align-items: center; gap: 6px; font-size: 13px; }

  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  td { padding: 5px 0; border-top: 1px solid var(--line); vertical-align: top; }
  td:first-child { font-weight: 600; }
  td.n { text-align: right; color: var(--muted); white-space: nowrap; padding-left: 12px; }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }

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
  <span class="sub">Split a combined score into one printable PDF per part</span>
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

    <div class="card">
      <h3>Files to be written</h3>
      <table id="summary"></table>
    </div>

    <div class="card">
      <h3>Pages</h3>
      <p class="sub" style="margin-top:-4px">
        A ticked page starts a new part. Untick one that isn&rsquo;t really a
        new part, or tick one that was missed.
      </p>
      <div id="pages"></div>
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
let sid = null, pages = [], labels = [], planTimer = null;

function notice(msg, kind) {
  $('notice').innerHTML = msg ? `<div class="warn ${kind || ''}">${msg}</div>` : '';
}

/* ---------- upload ---------- */
const drop = $('drop');
drop.onclick = () => $('file').click();
$('file').onchange = (e) => { if (e.target.files[0]) upload(e.target.files[0]); };
['dragenter', 'dragover'].forEach(ev =>
  drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach(ev =>
  drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', e => {
  const f = e.dataTransfer.files[0];
  if (f) upload(f);
});

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
  labels = pages.map(p => p.label);
  $('title').value = data.title || '';
  $('app').classList.remove('hide');
  $('bar').classList.remove('hide');

  let msg = '';
  if (data.scanned)
    msg = 'These pages have little or no text, so this looks like a scan. ' +
          'Detection will be poor — tick the pages that start each part by hand.';
  else if (data.suspect)
    msg = 'Nearly every page looks like a new part, which usually means the ' +
          'header was misread. Check the ticks below before exporting.';
  notice(msg);

  renderPages();
  plan();
}

/* ---------- page list ---------- */
function renderPages() {
  const host = $('pages');
  host.textContent = '';
  let current = null;
  pages.forEach((p, i) => {
    if (labels[i]) current = labels[i];
    const row = document.createElement('div');
    row.className = 'page';

    const img = document.createElement('img');
    img.loading = 'lazy';
    img.src = `/api/thumb/${sid}/${i}`;
    img.alt = `page ${p.n}`;
    row.appendChild(img);

    const right = document.createElement('div');
    const size = p.width > p.height ? ' · landscape' : '';
    right.innerHTML = `<div class="no">Page ${p.n} — ${p.width}×${p.height} pt${size}</div>`;

    const ctl = document.createElement('div');
    ctl.className = 'row';

    const chk = document.createElement('label');
    chk.className = 'chk';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = !!labels[i];
    chk.appendChild(box);
    chk.appendChild(document.createTextNode('starts a part'));
    ctl.appendChild(chk);

    const name = document.createElement('input');
    name.type = 'text';
    name.value = labels[i] || '';
    name.placeholder = 'part name, e.g. Alto Saxophone';
    name.disabled = !labels[i];
    ctl.appendChild(name);

    const note = document.createElement('span');
    note.className = current ? 'cont' : 'frontmatter';
    note.textContent = labels[i] ? ''
      : (current ? '↳ continues ' + current : 'front matter (cover / copyright)');
    ctl.appendChild(note);

    box.onchange = () => {
      labels[i] = box.checked ? (name.value.trim() || guessName(i)) : null;
      renderPages(); plan();
    };
    name.oninput = () => { labels[i] = name.value.trim() || null; plan(); };
    name.onblur = () => renderPages();

    right.appendChild(ctl);
    row.appendChild(right);
    host.appendChild(row);
  });
}

function guessName(i) {
  return pages[i].label || 'Part ' + (i + 1);
}

/* ---------- plan ---------- */
function options() {
  return {
    sid, labels,
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
    const rows = data.files.map(f =>
      `<tr><td class="mono">${esc(f.file)}</td>` +
      `<td class="n">${f.count} pp &middot; pages ${ranges(f.pages)}</td></tr>`).join('');
    $('summary').innerHTML = rows ||
      '<tr><td class="cont">Nothing yet — tick a page to start a part.</td></tr>';
    $('status').textContent =
      `${data.files.length} part${data.files.length === 1 ? '' : 's'}` +
      (data.front.length ? ` · ${data.front.length} front-matter page(s)` : '');
  }, 180);
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

const esc = (s) => s.replace(/[&<>"]/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

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
