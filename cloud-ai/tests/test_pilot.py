"""End-to-end pilot contract with a local store and deterministic provider doubles."""

import concurrent.futures
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

import requests
import uvicorn

from api import PREFIX, create_app
from pilot import Queue, Settings
from run_queue import Runner


class Storage:
    def __init__(self):
        self.records, self.objects = {}, {}

    def read_json(self, key):
        return self.records.get(key)

    def download(self, key, path):
        path.write_bytes(self.objects[key])

    def upload(self, key, path):
        self.objects[key] = path.read_bytes()

    def signed_url(self, key):
        return 'https://test-cos.invalid/' + key + '?fresh=1'


class WeChat:
    def __init__(self):
        self.sent = []

    def exchange(self, code):
        return 'test-openid-' + code

    def send(self, **fields):
        self.sent.append(fields)
        return 'sent'


class PilotTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.settings = Settings(Path(directory.name), ('shanghai', 'elf', 'disco'),
                                 'approved-template', {'thing1': '{theme}', 'thing2': '{status}'}, 5, 3)
        self.storage, self.wechat = Storage(), WeChat()
        self.queue = Queue(self.settings)
        app = create_app(self.settings, self.storage, self.wechat, 'test-secret-only' * 3)
        config = uvicorn.Config(app, host='127.0.0.1', port=0, log_level='error')
        self.server = uvicorn.Server(config)
        thread = threading.Thread(target=self.server.run, daemon=True)
        thread.start()
        self.addCleanup(self.stop, thread)
        for _ in range(400):
            if self.server.started:
                break
            time.sleep(.01)
        self.assertTrue(self.server.started)
        self.api = f'http://127.0.0.1:{self.server.servers[0].sockets[0].getsockname()[1]}{PREFIX}'
        self.owner = self.login('owner')
        self.event, self.video = str(uuid.uuid4()), str(uuid.uuid4())
        self.path = f'/videos/{self.video}'
        self.source = f'booth360/{self.video}/event-clip.mp4'
        self.storage.records[f'booth360/ai/sources/{self.video}.json'] = {
            'schema': 1, 'eventId': self.event, 'objectKey': self.source,
        }
        self.storage.objects[self.source] = b'original'

    def stop(self, thread):
        self.server.should_exit = True
        thread.join(3)

    def login(self, code):
        response = requests.post(self.api + '/session', json={'code': code}, timeout=5)
        response.raise_for_status()
        return {'Authorization': 'Bearer ' + response.json()['token']}

    def gate(self, enabled):
        self.storage.records[f'booth360/ai/events/{self.event}.json'] = {'schema': 1, 'enabled': enabled}

    def get(self, suffix='', headers=None):
        return requests.get(self.api + self.path + suffix, headers=self.owner if headers is None else headers, timeout=5)

    def post(self, suffix, body, headers=None):
        return requests.post(self.api + self.path + suffix, json=body,
                             headers=self.owner if headers is None else headers, timeout=10)

    def test_one_video_full_flow_and_reentry(self):
        self.assertEqual(self.get('/original').status_code, 404)
        self.assertFalse(self.get().json()['enabled'])
        self.assertEqual(self.post('/jobs', {'themeId': 'shanghai', 'consent': True}).status_code, 403)
        self.gate(True)
        self.assertEqual([item['id'] for item in self.get().json()['themes']], ['shanghai', 'elf', 'disco'])
        self.assertEqual(self.post('/jobs', {'themeId': 'shanghai', 'consent': False}).status_code, 422)
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            requests_in = [pool.submit(self.post, '/jobs', {'themeId': theme, 'consent': True})
                           for theme in ['shanghai'] * 6]
            created = [future.result().json()['job'] for future in requests_in]
        self.assertEqual(len({job['id'] for job in created}), 1)
        job = created[0]
        original = self.get('/original').json()['downloadUrl']
        self.assertIn(self.source, original)
        self.assertEqual(job['status'], 'queued')
        self.assertEqual(self.post('/jobs', {'themeId': 'elf', 'consent': True}).json()['job']['themeId'], 'shanghai')
        stranger = self.login('stranger')
        self.assertIsNone(self.get(headers=stranger).json()['job'])
        self.assertEqual(self.get('/original', headers=stranger).status_code, 404)
        self.assertEqual(self.post('/jobs', {'themeId': 'elf', 'consent': True}, stranger).status_code, 409)
        self.assertEqual(self.get(headers={}).status_code, 401)
        self.assertEqual(self.post('/subscription', {'templateId': 'different'}).status_code, 422)
        self.assertEqual(self.post('/subscription', {'templateId': 'approved-template'}).json(), {'ok': True})
        self.assertTrue(self.get().json()['subscribed'])

        def finish(_job, work, source):
            self.assertEqual(self.get().json()['job']['status'], 'processing')
            self.assertEqual(source.read_bytes(), b'original')
            (work / 'candidate.mp4').write_bytes(b'AI output')
            (work / 'review.json').write_text('{}')
            return 0

        runner = Runner(self.queue, self.storage, self.wechat, finish)
        self.assertTrue(runner.run_one())
        state = self.get().json()['job']
        self.assertEqual(state['status'], 'review')
        self.assertNotIn('downloadUrl', state)
        self.assertFalse(runner.notify_one())
        reviewed = self.queue.get(job['id'])
        self.assertTrue(self.queue.transition(job['id'], 'review', 'ready', key=reviewed['result_key']))
        self.assertTrue(runner.notify_one())
        self.assertEqual(self.wechat.sent[0]['video_id'], self.video)
        self.assertEqual(self.wechat.sent[0]['owner'], 'test-openid-owner')
        self.assertFalse(runner.notify_one())
        self.gate(False)
        reopened = self.get(headers=self.login('owner')).json()
        self.assertFalse(reopened['enabled'])
        self.assertEqual(reopened['job']['status'], 'ready')
        self.assertIn(reviewed['result_key'], reopened['job']['downloadUrl'])
        self.assertEqual(self.storage.objects[reviewed['result_key']], b'AI output')
        self.assertEqual(self.get('/original').json()['downloadUrl'], original)

    def test_legacy_video_and_failed_job(self):
        self.gate(True)
        metadata = self.storage.records.pop(f'booth360/ai/sources/{self.video}.json')
        self.assertFalse(self.get().json()['enabled'])
        self.storage.records[f'booth360/ai/sources/{self.video}.json'] = metadata
        self.post('/jobs', {'themeId': 'shanghai', 'consent': True}).raise_for_status()
        runner = Runner(self.queue, self.storage, self.wechat, lambda *_args: 1)
        runner.run_one()
        self.assertEqual(self.get().json()['job']['status'], 'failed')
        self.assertEqual(self.post('/jobs', {'themeId': 'elf', 'consent': True}).json()['job']['status'], 'failed')
        self.assertEqual(self.wechat.sent, [])


if __name__ == '__main__':
    unittest.main()
