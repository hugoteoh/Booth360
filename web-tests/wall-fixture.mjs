import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { chromium } from 'playwright';
import template from './wall-template.cjs';

const chromeCandidates = [
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  '/opt/google/chrome/chrome', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable',
];
const ffmpegDefault = 'D:\\AR镜面签\\app\\resources\\bin\\ffmpeg.exe';
const qrImage = `<svg xmlns="http://www.w3.org/2000/svg" width="96" height="96" viewBox="0 0 96 96">
  <rect width="96" height="96" fill="white"/>
  <path fill="black" d="M8 8h28v28H8zM60 8h28v28H60zM8 60h28v28H8zM44 44h12v12H44zM60 60h28v12H60zM44 76h12v12H44zM76 76h12v12H76z"/>
</svg>`;
const fixtureJS = `const REFRESH_MS = 180;
const GEAR_HREF = '';
const GALLERY_HREF = '';
async function fetchItems() {
  const response = await fetch('/items', { cache: 'no-store' });
  if (!response.ok) throw new Error('Fixture manifest unavailable');
  return response.json();
}`;

async function safeRemoveFixtureDirectory(tempDirectory) {
  const root = path.resolve(tmpdir());
  const target = path.resolve(tempDirectory);
  const relative = path.relative(root, target);
  assert.ok(relative && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative),
    'Refuse to remove a fixture directory outside the OS temporary directory');
  assert.ok(path.basename(target).startsWith('booth360-wall-test-'),
    'Refuse to remove a directory without the fixture prefix');
  await rm(target, { recursive: true, force: true });
}

export async function prepareBrowser() {
  const tempDirectory = await mkdtemp(path.join(tmpdir(), 'booth360-wall-test-'));
  try {
    const videoPath = path.join(tempDirectory, 'fixture-h264.mp4');
    const ffmpeg = process.env.FFMPEG_PATH || (existsSync(ffmpegDefault) ? ffmpegDefault : 'ffmpeg');
    const result = spawnSync(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=180x320:rate=24',
      '-t', '10', '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30',
      '-pix_fmt', 'yuv420p', '-movflags', '+faststart', videoPath,
    ], { encoding: 'utf8', windowsHide: true, timeout: 30000 });
    assert.equal(result.status, 0, `Cannot generate H.264 fixture; set FFMPEG_PATH. ${result.error || result.stderr}`);
    const video = await readFile(videoPath);
    const executablePath = process.env.BOOTH360_CHROME_PATH || process.env.CHROME_PATH ||
      chromeCandidates.find(candidate => existsSync(candidate));
    const browser = await chromium.launch({
      headless: true, executablePath,
      args: ['--autoplay-policy=no-user-gesture-required'],
    });
    console.log(`# Browser: ${await browser.version()}; Playwright 1.65.0; local H.264 ${video.length} bytes`);
    return {
      browser, video,
      async close() {
        try { await browser.close(); }
        finally { await safeRemoveFixtureDirectory(tempDirectory); }
      },
    };
  } catch (error) {
    await safeRemoveFixtureDirectory(tempDirectory);
    throw error;
  }
}

export function item(id = 'clip-a', qrURL = '/qr-a.svg', videoURL = '/video.mp4?signature=first') {
  return { id, qrURL, videoURL, state: qrURL ? '已上传' : '上传中' };
}

export async function openWall(t, runtime, {
  mode = 'grid', items = [item()], rules = {}, dropFirstImageError = false,
  cloud = false, pagePath = '/', clipboard,
} = {}) {
  const state = {
    items, manifestFails: false, manifestRequests: 0, failedManifestRequests: 0,
    qrRequests: [], videoRequests: [], rules: new Map(Object.entries(rules)),
  };
  const html = template.renderWallHTML(cloud ? template.cloudVariantJS() : fixtureJS);
  const wallPath = new URL(pagePath, 'http://127.0.0.1').pathname;
  const recoveryPath = new URL('./qr-recovery.html', `http://127.0.0.1${wallPath}`).pathname;
  const folder = wallPath.split('/').filter(Boolean).at(-2);
  const server = createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    response.setHeader('Cache-Control', 'no-store');
    if (url.pathname === wallPath) {
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      response.end(html);
    } else if (url.pathname === '/items' || (cloud && url.pathname.endsWith('/wall.json'))) {
      state.manifestRequests++;
      if (state.manifestFails) {
        state.failedManifestRequests++;
        response.writeHead(503).end('Temporarily unavailable');
      } else {
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify(cloud ? { items: state.items.map(entry => ({
          id: entry.id, url: entry.videoURL, qr: entry.qrURL,
        })) } : state.items));
      }
    } else if (cloud && url.pathname.endsWith('/current.json')) {
      response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ event: folder }));
    } else if (cloud && url.pathname === recoveryPath) {
      response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
        .end('<!doctype html><title>Fixture recovery page</title><p>Local recovery destination</p>');
    } else if (url.pathname.startsWith('/qr-')) {
      const rule = state.rules.get(url.pathname) || {};
      const failures = rule.failures || 0;
      const failed = failures > 0 || (rule.failUntil || 0) > Date.now();
      if (failures > 0 && failures !== Infinity) rule.failures--;
      state.qrRequests.push({
        path: url.pathname, retry: url.searchParams.get('__booth360_qr_retry'),
        at: Date.now(), status: failed ? 404 : 200,
      });
      response.writeHead(failed ? 404 : 200, { 'Content-Type': failed ? 'text/plain' : 'image/svg+xml' });
      response.end(failed ? 'QR not ready yet' : qrImage);
    } else if (url.pathname === '/video.mp4') {
      state.videoRequests.push(url.href);
      const total = runtime.video.length;
      const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range || '');
      if (range) {
        const start = Number(range[1]);
        const end = Math.min(Number(range[2] || total - 1), total - 1);
        if (start > end) { response.writeHead(416, { 'Content-Range': `bytes */${total}` }).end(); return; }
        response.writeHead(206, { 'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes',
          'Content-Length': end - start + 1, 'Content-Range': `bytes ${start}-${end}/${total}` });
        response.end(runtime.video.subarray(start, end + 1));
      } else {
        response.writeHead(200, { 'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes', 'Content-Length': total });
        response.end(runtime.video);
      }
    } else {
      response.writeHead(404).end();
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const origin = `http://127.0.0.1:${server.address().port}`;
  const context = await runtime.browser.newContext({ viewport: { width: 1280, height: 720 } });
  t.after(async () => {
    await context.close();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  });
  const page = await context.newPage();
  const scriptErrors = [];
  page.on('pageerror', error => scriptErrors.push(error.message));
  await context.route('**/*', route => {
    if (new URL(route.request().url()).origin === origin) return route.continue();
    return route.abort('blockedbyclient');
  });
  await page.addInitScript(({ mode, dropFirstImageError, clipboard }) => {
    localStorage.setItem('booth360.wall.mode', mode);
    if (clipboard) {
      window.__copiedRecoveryURLs = [];
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: clipboard === 'missing' ? undefined : {
        writeText(value) {
          window.__copiedRecoveryURLs.push(value);
          if (clipboard === 'rejected') return Promise.reject(new DOMException('Clipboard denied', 'NotAllowedError'));
          if (clipboard === 'deferred') return new Promise(resolve => { window.__finishRecoveryCopy = resolve; });
          return Promise.resolve();
        },
      } });
    }
    if (dropFirstImageError) document.addEventListener('error', event => {
      if (!window.__imageErrorDropped && event.target instanceof HTMLImageElement &&
          event.target.hasAttribute('data-qr-image')) {
        window.__imageErrorDropped = true;
        event.stopImmediatePropagation();
      }
    }, true);
  }, { mode, dropFirstImageError, clipboard });
  await page.goto(new URL(pagePath, origin).href, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector(`#stage.m-${mode} video`);
  return { page, state, scriptErrors };
}

export async function loadedQR(page, id = 'clip-a', timeout = 10000) {
  await page.waitForFunction(id => {
    const container = [...document.querySelectorAll('.qr-content')].find(node => node.dataset.qrId === id);
    const image = container?.querySelector('img[data-qr-image]');
    return container?.dataset.qrState === 'loaded' && image?.complete && image.naturalWidth > 0;
  }, id, { timeout });
}

export async function rememberPlayingVideo(page) {
  await page.waitForFunction(() => {
    const video = document.querySelector('#stage video[autoplay]');
    return video && video.readyState >= 2 && !video.paused && !video.error && video.currentTime > 0.2;
  });
  return page.evaluate(() => {
    window.__originalVideo = document.querySelector('#stage video[autoplay]');
    window.__videoReloads = 0;
    window.__originalVideo.addEventListener('loadstart', () => window.__videoReloads++);
    return { time: window.__originalVideo.currentTime, src: window.__originalVideo.getAttribute('src') };
  });
}

export async function assertVideoContinues(page, before) {
  await page.waitForFunction(time => window.__originalVideo?.currentTime > time + 0.35, before.time);
  const result = await page.evaluate(() => ({
    sameNode: window.__originalVideo === document.querySelector('#stage video[autoplay]'),
    time: window.__originalVideo.currentTime, src: window.__originalVideo.getAttribute('src'),
    reloads: window.__videoReloads, mediaError: window.__originalVideo.error?.code || null,
  }));
  assert.equal(result.sameNode, true, 'QR/manifest update must retain the video DOM node');
  assert.equal(result.src, before.src, 'QR/signature update must not replace the playing video source');
  assert.equal(result.reloads, 0, 'Playing video must not load again');
  assert.equal(result.mediaError, null);
  assert.ok(result.time > before.time + 0.35, 'Real H.264 playback must continue forward');
}

export async function switchMode(page, mode) {
  const labels = { grid: '网格', featured: '最新主打', cinema: '全屏轮播' };
  await page.locator('#gear').click({ force: true });
  await page.locator('#popts button').filter({ hasText: labels[mode] }).click();
  await page.locator('#pclose').click();
  await page.waitForSelector(`#stage.m-${mode} video`);
}
