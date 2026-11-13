"""Process one Booth360 AI job at a time and deliver approved results."""

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

from qcloud_cos.cos_exception import CosClientError, CosServiceError

from integrations import CosStorage, WeChat
from pilot import Problem, Queue, Settings, THEMES, identifier, result_key


HERE = Path(__file__).resolve().parent


@contextmanager
def singleton(path):
    # The lock lives in its own database so API requests can still use the queue.
    lock = sqlite3.connect(path, timeout=0)
    try:
        lock.execute('BEGIN EXCLUSIVE')
        yield
    finally:
        lock.close()


class Runner:
    def __init__(self, queue, storage, wechat, invoke=None):
        self.queue, self.storage, self.wechat = queue, storage, wechat
        self.invoke = invoke or self.run_pipeline

    def work_dir(self, job):
        path = self.queue.settings.data_dir / 'work' / job['id']
        path.mkdir(parents=True, exist_ok=True)
        return path

    def run_pipeline(self, job, path, source):
        command = [sys.executable, '-m', 'worker', '--source', str(source),
                   '--theme', job['theme'], '--work-dir', str(path)]
        guide = os.getenv(f"BOOTH360_AI_{job['theme'].upper()}_GUIDE_KEY") or os.getenv('BOOTH360_AI_SHANGHAI_GUIDE_KEY')
        if guide:
            command.extend(('--guide-url', self.storage.signed_url(guide, 3600)))
        direction = os.getenv('BOOTH360_AI_GUIDE_DIRECTION', 'left')
        command.extend(('--guide-direction', direction))
        timing = path / 'timing.json'
        if timing.is_file():
            command.extend(('--timing', str(timing)))
        try:
            # Provider diagnostics stay with the private job, out of shared service logs.
            with (path / 'worker.log').open('ab') as log:
                completed = subprocess.run(command, cwd=HERE, stdout=log,
                                           stderr=log, timeout=2700, check=False)
        except subprocess.TimeoutExpired:
            return 75
        return completed.returncode

    def run_one(self):
        job = self.queue.claim()
        if not job:
            return False
        path = self.work_dir(job)
        source = path / 'source.mp4'
        attempts_file = path / 'worker-attempts.json'
        try:
            if not source.is_file():
                self.storage.download(job['source_key'], source)
            attempts = json.loads(attempts_file.read_text(encoding='utf-8')) if attempts_file.is_file() else 0
            code = self.invoke(job, path, source)
            if code == 75 and attempts < 3:
                pending = attempts_file.with_suffix('.part')
                pending.write_text(json.dumps(attempts + 1), encoding='utf-8')
                pending.replace(attempts_file)
                time.sleep(2)
                return True
            candidate, review = path / 'candidate.mp4', path / 'review.json'
            if code != 0 or not candidate.is_file() or not review.is_file():
                raw_ready = (path / 'generated.mp4').is_file()
                self.queue.transition(job['id'], 'processing', 'review' if raw_ready else 'failed',
                                      message='composition_failed' if raw_ready else 'pipeline_failed')
                print(f"Job {job['id']} failed (worker exit {code})", flush=True)
                return True
            key = result_key(job)
            self.storage.upload(key, candidate)
            self.queue.transition(job['id'], 'processing', 'review', key=key)
            print(f"Job {job['id']} ready for review", flush=True)
        except (OSError, ValueError, Problem, CosClientError, CosServiceError) as error:
            self.queue.transition(job['id'], 'processing', 'failed', message='pipeline_failed')
            print(f"Job {job['id']} failed ({type(error).__name__})", flush=True)
        return True

    def revise(self, job):
        path = self.work_dir(job)
        if job['status'] != 'review' or not (path / 'generated.mp4').is_file() or not (path / 'timing.json').is_file():
            raise ValueError('An awaiting-review job, saved generated video and timing.json are required')
        if self.invoke(job, path, path / 'source.mp4') != 0:
            raise ValueError('Recomposition failed; check the private worker.log')
        report = json.loads((path / 'review.json').read_text(encoding='utf-8'))
        if report.get('status') != 'review':
            raise ValueError('Missing updated review result')
        key = result_key(job)
        self.storage.upload(key, path / 'candidate.mp4')
        self.queue.transition(job['id'], 'review', 'review', key=key)

    def notify_one(self):
        row = self.queue.take_notification()
        if not row:
            return False
        values = {'theme': THEMES[row['theme']]['title'], 'status': 'AI 视频已生成',
                  'time': time.strftime('%Y-%m-%d %H:%M', time.gmtime(time.time() + 8 * 3600))}
        try:
            fields = {key: text.format(**values) for key, text in self.queue.settings.template_fields.items()}
            outcome = self.wechat.send(owner=row['owner'], video_id=row['video_id'],
                                       template_id=row['template_id'], fields=fields)
        except (KeyError, ValueError):
            outcome = 'rejected'
        if outcome == 'pending' and row['attempts'] >= 4:
            outcome = 'rejected'
        self.queue.finish_notification(row, outcome)
        print(f"Job {row['job_id']} subscription {outcome}", flush=True)
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('run', 'once', 'review', 'revise', 'approve', 'reject'))
    parser.add_argument('job_id', nargs='?')
    args = parser.parse_args()
    settings = Settings.from_env()
    queue = Queue(settings)
    if args.command == 'review':
        for job in queue.list('review'):
            artifact = 'candidate.mp4' if job['result_key'] else 'worker.log'
            print(job['id'], job['theme'], settings.data_dir / 'work' / job['id'] / artifact)
        return
    if args.command in ('revise', 'approve', 'reject'):
        if not args.job_id:
            parser.error('a job ID is required')
        job_id = identifier(args.job_id)
        with singleton(settings.data_dir / f'review-{job_id}.sqlite3'):
            job = queue.get(job_id)
            if args.command == 'revise':
                Runner(queue, CosStorage(), WeChat()).revise(job)
                return
            approved = args.command == 'approve'
            if approved and not job['result_key']:
                parser.error('recompose the existing generated video before approval')
            if not queue.transition(job['id'], 'review', 'ready' if approved else 'failed',
                                    key=job['result_key'] if approved else None):
                parser.error('job is not awaiting review')
        return
    runner = Runner(queue, CosStorage(), WeChat())
    with singleton(settings.data_dir / 'worker-lock.sqlite3'):
        queue.recover_notifications()
        if args.command == 'once':
            runner.notify_one()
            runner.run_one()
            runner.notify_one()
            return
        stop = threading.Event()

        def deliver_notifications():
            while not stop.is_set():
                if not runner.notify_one():
                    stop.wait(2)

        notifier = threading.Thread(target=deliver_notifications, name='wechat-notifier', daemon=True)
        notifier.start()
        try:
            while notifier.is_alive():
                if not runner.run_one():
                    stop.wait(2)
            raise RuntimeError('Notification worker stopped')
        finally:
            stop.set()
            notifier.join(timeout=12)


if __name__ == '__main__':
    main()
