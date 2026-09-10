// A window around the review UI, and the Python that serves it.
//
// The splitting, the detection and the review screen are all the ones the CLI
// and the browser already use: this process starts that server on a loopback
// port and points a window at it. Nothing is reimplemented here, which is the
// point -- a third copy of the detection heuristics is how they start
// disagreeing about the same PDF.

const { app, BrowserWindow, Menu, dialog, shell } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const SHOT = (process.argv.find(a => a.startsWith('--screenshot=')) || '').split('=')[1];

let server = null;      // the Python process
let base = null;        // where it is listening
let win = null;

/** The bundled interpreter-free build, or the working tree in development. */
function sidecar() {
  const packed = path.join(process.resourcesPath || '', 'sidecar',
                           process.platform === 'win32' ? 'pdf-music-breakout.exe'
                                                        : 'pdf-music-breakout');
  if (fs.existsSync(packed)) return { command: packed, args: [] };

  const repo = path.join(__dirname, '..');
  const venv = path.join(repo, '.venv', 'bin', 'python');
  const python = fs.existsSync(venv) ? venv : (process.platform === 'win32' ? 'python' : 'python3');
  return { command: python, args: [path.join(repo, 'pdf_music_breakout.py')] };
}

/**
 * Start the server and wait for it to say where it is.
 *
 * It picks its own free port, so the line it prints is the only reliable
 * answer -- guessing a port and racing it is how this goes wrong on a machine
 * that already has something on 8756.
 */
function startServer() {
  return new Promise((resolve, reject) => {
    const { command, args } = sidecar();
    server = spawn(command, [...args, '--serve', '--no-browser'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
      // Belt and braces: the server flushes the line we are waiting for, but
      // a buffered pipe would hide it and look exactly like a hang.
      env: { ...process.env, PYTHONUNBUFFERED: '1', ELECTRON_RUN_AS_NODE: undefined },
    });

    let out = '';
    const settle = (chunk) => {
      out += chunk.toString();
      const m = /(http:\/\/127\.0\.0\.1:\d+\/)/.exec(out);
      if (m) resolve(m[1]);
    };
    server.stdout.on('data', settle);
    server.stderr.on('data', settle);
    server.on('error', reject);
    server.on('exit', (code) => {
      server = null;
      if (!base) reject(new Error(`the splitter exited (${code})\n${out.slice(-400)}`));
    });
    setTimeout(() => reject(new Error('the splitter did not start in time')), 20000);
  });
}

/** Ask the server to read a file, then let the page pick it up. */
async function openFile(file) {
  const res = await fetch(base + 'api/open', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: file }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'could not read that file');
  win.webContents.reload();
}

async function chooseFile() {
  const { canceled, filePaths } = await dialog.showOpenDialog(win, {
    title: 'Choose the combined PDF to split',
    filters: [{ name: 'PDF', extensions: ['pdf'] }],
    properties: ['openFile'],
  });
  if (canceled || !filePaths[0]) return;
  try {
    await openFile(filePaths[0]);
  } catch (err) {
    dialog.showErrorBox('Could not open that PDF', err.message);
  }
}

/** Drive the page's own controls, rather than growing a second set. */
const click = (id) => win.webContents.executeJavaScript(
  `document.getElementById(${JSON.stringify(id)}).click()`, true);
const zoom = (js) => win.webContents.executeJavaScript(js, true);

function buildMenu() {
  const mac = process.platform === 'darwin';
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    ...(mac ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        { label: 'Open…', accelerator: 'CmdOrCtrl+O', click: chooseFile },
        { type: 'separator' },
        { label: 'Export Parts…', accelerator: 'CmdOrCtrl+S', click: () => click('zip') },
        { label: 'Save to Folder', click: () => click('save') },
        { type: 'separator' },
        mac ? { role: 'close' } : { role: 'quit' },
      ],
    },
    {
      label: 'View',
      submenu: [
        { label: 'Previous Page', accelerator: 'Left', click: () => zoom('step(-1)') },
        { label: 'Next Page', accelerator: 'Right', click: () => zoom('step(1)') },
        { type: 'separator' },
        { label: 'Zoom In', accelerator: 'CmdOrCtrl+Plus', click: () => zoom('zoomBy(1.25)') },
        { label: 'Zoom Out', accelerator: 'CmdOrCtrl+-', click: () => zoom('zoomBy(0.8)') },
        { label: 'Actual Size', accelerator: 'CmdOrCtrl+0',
          click: () => zoom('zoomMode="factor"; zoomFactor=1; showPreview()') },
        { label: 'Fit Page', accelerator: 'CmdOrCtrl+9',
          click: () => zoom('zoomMode="fit"; showPreview()') },
        { label: 'Fit Width', accelerator: 'CmdOrCtrl+8',
          click: () => zoom('zoomMode="width"; showPreview()') },
        { type: 'separator' },
        { role: 'reload' }, { role: 'toggleDevTools' },
      ],
    },
    { role: 'windowMenu' },
    {
      role: 'help',
      submenu: [{
        label: 'Project page',
        click: () => shell.openExternal('https://github.com/sandinak/pdf-music-breakout'),
      }],
    },
  ]));
}

app.whenReady().then(async () => {
  try {
    base = await startServer();
  } catch (err) {
    // A modal dialog in a headless run is a hang with no explanation.
    if (SHOT) console.error('could not start: ' + (err.message || err));
    else dialog.showErrorBox('PDF Music Breakout could not start', String(err.message || err));
    app.exit(1);
    return;
  }

  win = new BrowserWindow({
    width: 1500,
    height: 1000,
    minWidth: 900,
    minHeight: 640,
    show: !SHOT,          // a screenshot run never puts a window on screen
    backgroundColor: '#17181a',
    title: 'PDF Music Breakout',
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  });
  buildMenu();

  // Opened from the Finder, Explorer, or the command line.
  const file = process.argv.slice(1).find(a => /\.pdf$/i.test(a) && fs.existsSync(a));
  await win.loadURL(base);
  if (file) await openFile(file);

  if (SHOT) {
    // Give the page time to fetch its plan and render the first page.
    await new Promise(r => setTimeout(r, 3500));
    const image = await win.webContents.capturePage();
    fs.mkdirSync(path.dirname(SHOT), { recursive: true });
    fs.writeFileSync(SHOT, image.toPNG());
    console.log('wrote ' + SHOT);
    app.quit();
  }
});

app.on('open-file', (event, file) => {   // macOS: dropped on the Dock icon
  event.preventDefault();
  if (base && win) openFile(file).catch(() => {});
});

// The server is ours; it should not outlive the window.
const stop = () => { if (server) { server.kill(); server = null; } };
app.on('window-all-closed', () => { stop(); app.quit(); });
app.on('will-quit', stop);
process.on('exit', stop);
