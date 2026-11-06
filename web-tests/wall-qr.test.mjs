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
