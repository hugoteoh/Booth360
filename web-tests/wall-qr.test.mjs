import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import {
  prepareBrowser, item, openWall, loadedQR, rememberPlayingVideo,
  assertVideoContinues, switchMode,
} from './wall-fixture.mjs';

let runtime;
before(async () => { runtime = await prepareBrowser(); });
after(async () => { await runtime?.close(); });

const modes = ['grid', 'featured', 'cinema'];
for (const mode of modes) {
  test(`${mode}: first QR 404 recovers automatically and loaded image stays stable`, { timeout: 20000 }, async t => {
    const { page, state, scriptErrors } = await openWall(t, runtime, {
      mode, rules: { '/qr-a.svg': { failures: 1 } },
    });
    await page.waitForSelector('.qr-content[data-qr-state="error"]');
    assert.equal(await page.locator('.qr-status').textContent(), '二维码重试中');
    await loadedQR(page);
    assert.equal(await page.locator('img[data-qr-image]').isVisible(), true);
    assert.deepEqual(state.qrRequests.map(request => request.status), [404, 200]);
    assert.equal(state.qrRequests[0].retry, null);
    assert.ok(state.qrRequests[1].retry, 'Public QR retry must bypass a cached 404');
    assert.ok(state.qrRequests[1].at - state.qrRequests[0].at >= 850, 'Initial retry must back off');
    const count = state.qrRequests.length;
    await page.waitForTimeout(1400); // spans the 1s patrol and several manifest polls
    assert.equal(state.qrRequests.length, count, 'Successfully decoded QR must not be requested again');
    assert.deepEqual(scriptErrors, []);
  });

  test(`${mode}: QR availability/URL and video signatures update without interrupting H.264`, { timeout: 20000 }, async t => {
    const { page, state, scriptErrors } = await openWall(t, runtime, { mode, items: [item('clip-a', '')] });
    assert.equal(await page.locator('img[data-qr-image]').count(), 0);
    assert.match(await page.locator('.qr-status').textContent(), /上传中/);
    let before = await rememberPlayingVideo(page);

    state.items = [item()];
    await loadedQR(page);
    assert.equal(await page.locator('.qr-content').getAttribute('data-qr-source'), '/qr-a.svg');
    await assertVideoContinues(page, before);

    before = await rememberPlayingVideo(page);
    state.items = [item('clip-a', '/qr-b.svg')];
    await page.waitForSelector('.qr-content[data-qr-source="/qr-b.svg"][data-qr-state="loaded"]');
    await loadedQR(page);
    assert.ok(state.qrRequests.some(request => request.path === '/qr-b.svg' && request.status === 200));
    await assertVideoContinues(page, before);

    before = await rememberPlayingVideo(page);
    const nextManifest = page.waitForResponse(response => new URL(response.url()).pathname === '/items');
    state.items = [item('clip-a', '/qr-b.svg', '/video.mp4?signature=rotated')];
    await (await nextManifest).finished();
    await assertVideoContinues(page, before);
    assert.equal(state.videoRequests.some(url => url.includes('signature=rotated')), false,
      'Signature-only changes must retain the existing media request');
    assert.deepEqual(scriptErrors, []);
  });
}

test('Several temporary failures recover with increasing retry delays', { timeout: 22000 }, async t => {
  const { page, state, scriptErrors } = await openWall(t, runtime, {
    rules: { '/qr-a.svg': { failures: 3 } },
  });
  await loadedQR(page, 'clip-a', 15000);
  assert.deepEqual(state.qrRequests.map(request => request.status), [404, 404, 404, 200]);
  const delays = state.qrRequests.slice(1).map((request, index) => request.at - state.qrRequests[index].at);
  assert.ok(delays[0] >= 850, `First backoff: ${delays[0]}ms`);
  assert.ok(delays[1] >= 1850, `Second backoff: ${delays[1]}ms`);
  assert.ok(delays[2] >= 3850, `Third backoff: ${delays[2]}ms`);
  assert.equal(new Set(state.qrRequests.slice(1).map(request => request.retry)).size, 3);
  assert.deepEqual(scriptErrors, []);
});

test('Complete/naturalWidth patrol recovers when the initial image error event is missed', { timeout: 15000 }, async t => {
  const { page, state, scriptErrors } = await openWall(t, runtime, {
    dropFirstImageError: true, rules: { '/qr-a.svg': { failures: 1 } },
  });
  await page.waitForFunction(() => window.__imageErrorDropped === true);
  await loadedQR(page);
  assert.deepEqual(state.qrRequests.map(request => request.status), [404, 200]);
  assert.deepEqual(scriptErrors, []);
});

test('Layout changes and removed cards do not retry detached broken images', { timeout: 18000 }, async t => {
  const { page, state, scriptErrors } = await openWall(t, runtime, {
    rules: { '/qr-a.svg': { failures: Infinity }, '/qr-c.svg': { failures: Infinity } },
  });
  await page.waitForSelector('.qr-content[data-qr-state="error"]');
  await page.evaluate(() => { window.__detachedImage = document.querySelector('img[data-qr-image]'); });
  state.items = [item('clip-a', '/qr-b.svg')];
  await switchMode(page, 'featured');
  await loadedQR(page);
  const oldCount = state.qrRequests.filter(request => request.path === '/qr-a.svg').length;
  assert.equal(await page.evaluate(() => window.__detachedImage.isConnected), false);
  await page.waitForTimeout(1400);
  assert.equal(state.qrRequests.filter(request => request.path === '/qr-a.svg').length, oldCount);

  await switchMode(page, 'cinema');
  await loadedQR(page);
  state.items = [item('clip-a', '/qr-c.svg')];
  await page.waitForSelector('.qr-content[data-qr-source="/qr-c.svg"][data-qr-state="error"]');
  state.items = [];
  await page.waitForFunction(() => document.querySelectorAll('#stage video').length === 0);
  const removedCount = state.qrRequests.filter(request => request.path === '/qr-c.svg').length;
  await page.waitForTimeout(1400);
  assert.equal(state.qrRequests.filter(request => request.path === '/qr-c.svg').length, removedCount);
  assert.deepEqual(scriptErrors, []);
});

test('QR retries continue while manifest refresh requests fail', { timeout: 15000 }, async t => {
  const { page, state, scriptErrors } = await openWall(t, runtime, {
    rules: { '/qr-a.svg': { failures: 1 } },
  });
  await page.waitForSelector('.qr-content[data-qr-state="error"]');
  state.manifestFails = true;
  await loadedQR(page);
  assert.ok(state.failedManifestRequests > 0, 'Fixture must exercise the rejected fetch path');
  assert.deepEqual(state.qrRequests.map(request => request.status), [404, 200]);
  assert.deepEqual(scriptErrors, []);
});

test('LAN-style variant without a recovery link keeps the entry hidden and video playing', { timeout: 15000 }, async t => {
  const { page, scriptErrors } = await openWall(t, runtime);
  const before = await rememberPlayingVideo(page);
  await page.locator('#gear').click({ force: true });
  assert.equal(await page.locator('#recoveryEntry').isVisible(), false);
  assert.equal(await page.locator('#recoveryURL').inputValue(), '');
  await page.locator('#pclose').click();
  await assertVideoContinues(page, before);
  assert.deepEqual(scriptErrors, []);
});

test('Production cloud variant resolves the stable recovery page in each current activity folder', { timeout: 15000 }, async t => {
  for (const pagePath of ['/booth360/wall/activity-a/index.html?screen=1#wall', '/booth360/wall/activity-b/index.html']) {
    const { page, state, scriptErrors } = await openWall(t, runtime, { cloud: true, pagePath, mode: 'featured' });
    const before = await rememberPlayingVideo(page);
    const expected = new URL('./qr-recovery.html', page.url()).href;
    await page.locator('#gear').click({ force: true });
    const input = page.getByRole('textbox', { name: '当前活动二维码修复链接' });
    assert.equal(await input.inputValue(), expected);
    assert.equal(await input.evaluate(element => element.readOnly), true);
    assert.equal(await page.getByText('二维码修复入口', { exact: true }).isVisible(), true);
    const link = page.getByRole('link', { name: '打开修复大屏 ↗' });
    assert.equal(await link.getAttribute('href'), expected);
    assert.equal(await link.getAttribute('target'), '_blank');
    assert.ok((await link.getAttribute('rel')).split(/\s+/).includes('noopener'));
    assert.ok(state.manifestRequests > 0, 'Actual production cloud variant must fetch its local manifest');

    const popupPromise = page.context().waitForEvent('page');
    await link.click();
    const popup = await popupPromise;
    await popup.waitForLoadState('domcontentloaded');
    assert.equal(popup.url(), expected);
    assert.equal(await popup.title(), 'Fixture recovery page');
    assert.equal(await popup.evaluate(() => window.opener), null);
    await popup.close();
    await page.locator('#pclose').click();
    await assertVideoContinues(page, before);
    assert.deepEqual(scriptErrors, []);
  }
});

test('Copy reports success only when the clipboard promise resolves, retaining video playback', { timeout: 15000 }, async t => {
  const { page, scriptErrors } = await openWall(t, runtime, {
    cloud: true, pagePath: '/booth360/wall/copy-event/index.html', clipboard: 'deferred',
  });
  const before = await rememberPlayingVideo(page);
  await page.locator('#gear').click({ force: true });
  await page.getByRole('button', { name: '复制链接', exact: true }).click();
  assert.equal(await page.getByRole('status').textContent(), '正在复制…');
  assert.equal(await page.locator('#copyRecovery').isDisabled(), true);
  const expected = new URL('./qr-recovery.html', page.url()).href;
  assert.deepEqual(await page.evaluate(() => window.__copiedRecoveryURLs), [expected]);
  await page.evaluate(() => window.__finishRecoveryCopy());
  await page.waitForFunction(() => document.getElementById('recoveryStatus').textContent === '链接已复制');
  assert.equal(await page.locator('#copyRecovery').isEnabled(), true);
  await page.locator('#pclose').click();
  await assertVideoContinues(page, before);
  assert.deepEqual(scriptErrors, []);
});

for (const clipboard of ['rejected', 'missing']) {
  test(`Clipboard ${clipboard}: selects the complete URL and gives honest manual-copy instructions`, { timeout: 15000 }, async t => {
    const { page, scriptErrors } = await openWall(t, runtime, {
      cloud: true, pagePath: '/booth360/wall/manual-copy/index.html', clipboard,
    });
    await page.locator('#gear').click({ force: true });
    await page.getByRole('button', { name: '复制链接', exact: true }).click();
    const status = await page.getByRole('status').textContent();
    assert.match(status, /未能自动复制.*链接已选中.*Ctrl\+C.*长按复制/);
    assert.doesNotMatch(status, /已复制/);
    const selection = await page.locator('#recoveryURL').evaluate(element => ({
      focused: document.activeElement === element, start: element.selectionStart,
      end: element.selectionEnd, value: element.value,
    }));
    assert.equal(selection.focused, true);
    assert.equal(selection.start, 0);
    assert.equal(selection.end, selection.value.length);
    assert.equal(selection.value, new URL('./qr-recovery.html', page.url()).href);
    assert.equal(await page.locator('#copyRecovery').isEnabled(), true);
    assert.deepEqual(scriptErrors, []);
  });
}

test('At 720p the settings panel scrolls to recovery controls and Close without restarting H.264', { timeout: 15000 }, async t => {
  const { page, scriptErrors } = await openWall(t, runtime, {
    cloud: true, pagePath: '/booth360/wall/small-screen/index.html', mode: 'featured', clipboard: 'resolved',
  });
  const before = await rememberPlayingVideo(page);
  await page.locator('#gear').click({ force: true });
  const panel = await page.locator('.pbox').evaluate(element => {
    const rect = element.getBoundingClientRect();
    return { top: rect.top, bottom: rect.bottom, height: rect.height,
      clientHeight: element.clientHeight, scrollHeight: element.scrollHeight, overflowY: getComputedStyle(element).overflowY };
  });
  assert.ok(panel.top >= 16 && panel.bottom <= 704, `Panel must fit inside 720p with 16px margins: ${JSON.stringify(panel)}`);
  assert.ok(panel.height <= 688);
  assert.equal(panel.overflowY, 'auto');
  assert.ok(panel.scrollHeight > panel.clientHeight, 'The extended panel must exercise scrolling at 720p');
  const copy = page.getByRole('button', { name: '复制链接', exact: true });
  await copy.scrollIntoViewIfNeeded();
  await copy.click();
  assert.equal(await page.getByRole('status').textContent(), '链接已复制');
  const close = page.getByRole('button', { name: '关闭', exact: true });
  await close.scrollIntoViewIfNeeded();
  const closeBounds = await close.boundingBox();
  assert.ok(closeBounds.y >= panel.top && closeBounds.y + closeBounds.height <= panel.bottom);
  await close.click();
  assert.equal(await page.locator('#panel').isVisible(), false);
  await assertVideoContinues(page, before);
  assert.deepEqual(scriptErrors, []);
});

async function assertPausedThumbnailAt(page, selector, fraction) {
  await page.waitForFunction(({ selector, fraction }) => {
    const video = document.querySelector(selector);
    return video && video.readyState >= 2 && !video.seeking && video.paused && video.videoWidth > 0 &&
      Number.isFinite(video.duration) && video.duration > 0 &&
      Math.abs(video.currentTime / video.duration - fraction) < 0.007;
  }, { selector, fraction });
  const frame = await page.locator(selector).evaluate(video => ({
    time: video.currentTime, duration: video.duration, paused: video.paused,
    seeking: video.seeking, error: video.error?.code || null,
  }));
  assert.equal(frame.error, null);
  assert.equal(frame.paused, true);
  assert.equal(frame.seeking, false);
  assert.ok(Math.abs(frame.time / frame.duration - fraction) < 0.007,
    `Decoded static frame must be near ${fraction * 100}%: ${JSON.stringify(frame)}`);
}

test('Featured cloud wall defaults its decoded static card to 37% while the hero keeps playing', { timeout: 15000 }, async t => {
  const { page, scriptErrors } = await openWall(t, runtime, {
    cloud: true, pagePath: '/booth360/wall/thumbnail-event/index.html', mode: 'featured',
    items: [item('hero'), item('static-card')],
  });
  const before = await rememberPlayingVideo(page);
  await assertPausedThumbnailAt(page, '.feat-strip video', 0.37);
  await page.locator('#gear').click({ force: true });
  assert.equal(await page.locator('#thumbRange').inputValue(), '37');
  assert.equal(await page.locator('#thumbPct').textContent(), '37%');
  await page.locator('#pclose').click();
  await assertVideoContinues(page, before);
  assert.deepEqual(scriptErrors, []);
});

test('Smooth grid wall defaults its non-playing fifth card to a decoded 37% frame', { timeout: 15000 }, async t => {
  const { page, scriptErrors } = await openWall(t, runtime, {
    smooth: true, items: Array.from({ length: 5 }, (_, index) => item(`clip-${index}`)),
  });
  const before = await rememberPlayingVideo(page);
  await assertPausedThumbnailAt(page, '#stage .wcell:last-child video', 0.37);
  await assertVideoContinues(page, before);
  assert.deepEqual(scriptErrors, []);
});

test('Wall keeps explicitly saved custom, previous midpoint and first-frame choices', { timeout: 15000 }, async t => {
  for (const fraction of [0.63, 0.5, 0]) {
    const { page, scriptErrors } = await openWall(t, runtime, {
      mode: 'featured', thumbChoice: fraction, items: [item('hero'), item('static-card')],
    });
    await assertPausedThumbnailAt(page, '.feat-strip video', fraction);
    await page.locator('#gear').click({ force: true });
    assert.equal(await page.locator('#thumbRange').inputValue(), String(fraction * 100));
    assert.equal(await page.evaluate(() => localStorage.getItem('booth360.wall.thumb')), String(fraction));
    assert.deepEqual(scriptErrors, []);
  }
});

for (const cloud of [false, true]) {
  test(`${cloud ? 'Cloud' : 'LAN'} gallery decodes the 37% preview${cloud ? ' without IntersectionObserver' : ' with lazy loading'}`, { timeout: 15000 }, async t => {
    const { page, scriptErrors } = await openWall(t, runtime, {
      cloud, gallery: true, pagePath: cloud ? '/booth360/wall/gallery-event/gallery.html' : '/gallery',
      withoutIntersectionObserver: cloud,
    });
    await assertPausedThumbnailAt(page, '#grid video', 0.37);
    assert.equal((await page.locator('#grid video').getAttribute('src')).includes('#t='), false,
      'A fixed first-frame fragment must not override the metadata-based preview');
    assert.deepEqual(scriptErrors, []);
  });
}

test('Gallery refresh preserves a manually playing and scrubbed video in both production variants', { timeout: 15000 }, async t => {
  for (const cloud of [false, true]) {
    const { page, state, scriptErrors } = await openWall(t, runtime, {
      cloud, gallery: true, pagePath: cloud ? '/booth360/wall/play-event/gallery.html' : '/gallery',
    });
    await assertPausedThumbnailAt(page, '#grid video', 0.37);
    await page.locator('#grid video').evaluate(async video => {
      video.currentTime = 6;
      await video.play();
      window.__galleryVideo = video;
    });
    const before = await page.evaluate(() => ({ time: window.__galleryVideo.currentTime,
      src: window.__galleryVideo.getAttribute('src') }));
    state.items = [item('clip-a', '/qr-a.svg', '/video.mp4?signature=renewed')];
    await page.evaluate(() => load());
    await page.waitForFunction(time => window.__galleryVideo.currentTime > time + 0.35, before.time);
    const after = await page.locator('#grid video').evaluate(video => ({
      sameNode: video === window.__galleryVideo, src: video.getAttribute('src'),
      paused: video.paused, error: video.error?.code || null,
    }));
    assert.equal(after.sameNode, true);
    assert.equal(after.src, before.src);
    assert.equal(after.paused, false);
    assert.equal(after.error, null);
    assert.deepEqual(scriptErrors, []);
  }
});
