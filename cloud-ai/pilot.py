"""Persistent API and queue for the Booth360 AI pilot."""

import os
import json
import re
import sqlite3
import time
import uuid
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path


THEMES = {
    'shanghai': {'id': 'shanghai', 'title': '上海滩', 'description': '酒红旗袍、雨夜外滩与折扇'},
    'elf': {'id': 'elf', 'title': '森林精灵', 'description': '精灵礼服、发光森林与掌心金光'},
    'disco': {'id': 'disco', 'title': '港风迪斯科', 'description': '复古金衣、霓虹舞厅与迪斯科收尾'},
}
ACTIVE = ('queued', 'processing', 'review')


class Problem(Exception):
    def __init__(self, status, detail):
        self.status, self.detail = status, detail


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    themes: tuple
    template_id: str
    template_fields: dict
    max_event_jobs: int
    max_active_jobs: int

    @classmethod
    def from_env(cls):
        themes = tuple(dict.fromkeys(os.getenv('BOOTH360_AI_THEMES', 'shanghai').split(',')))
        if not themes or any(theme not in THEMES for theme in themes):
            raise ValueError('Invalid BOOTH360_AI_THEMES')
        template = os.getenv('BOOTH360_WX_TEMPLATE_ID', '')
        fields = json.loads(os.getenv('BOOTH360_WX_TEMPLATE_FIELDS', '{}'))
        if template and (not isinstance(fields, dict) or not fields
                         or any(not isinstance(value, str) for value in fields.values())):
            raise ValueError('Configure the approved WeChat template fields')
        event_cap = int(os.getenv('BOOTH360_AI_EVENT_LIMIT', '20'))
        active_cap = int(os.getenv('BOOTH360_AI_QUEUE_LIMIT', '6'))
        if min(event_cap, active_cap) < 1:
            raise ValueError('Job limits must be positive')
        return cls(Path(os.getenv('BOOTH360_AI_DATA', './data')).resolve(), themes,
                   template, fields, event_cap, active_cap)


def identifier(value):
    try:
        canonical = str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise Problem(404, 'invalid_id') from None
    if canonical != value.lower():
        raise Problem(404, 'invalid_id')
    return canonical


def source_key(video_id, value):
    if not isinstance(value, str) or not re.fullmatch(
        rf'booth360/{re.escape(video_id)}/[A-Za-z0-9_.-]+\.mp4', value, re.IGNORECASE
    ):
        raise Problem(503, 'invalid_source')
    return value


def result_key(job):
    return f"booth360/ai/results/{job['video_id']}/{job['id']}.mp4"


class Queue:
    def __init__(self, settings):
        self.settings = settings
        settings.data_dir.mkdir(parents=True, exist_ok=True)
        self.path = settings.data_dir / 'jobs.sqlite3'
        with closing(self.connect()) as db, db:
            db.execute('PRAGMA journal_mode=WAL')
            db.executescript("""
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, video_id TEXT UNIQUE NOT NULL, event_id TEXT NOT NULL,
                    source_key TEXT NOT NULL, owner TEXT NOT NULL, theme TEXT NOT NULL,
                    status TEXT NOT NULL, message TEXT, result_key TEXT, created INTEGER NOT NULL,
                    updated INTEGER NOT NULL, CHECK(status IN ('queued','processing','review','ready','failed'))
                );
                CREATE TABLE IF NOT EXISTS subscriptions (
                    job_id TEXT NOT NULL, template_id TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
                    next_at INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(job_id, template_id), FOREIGN KEY(job_id) REFERENCES jobs(id)
                );
                CREATE INDEX IF NOT EXISTS job_events ON jobs(event_id);
            """)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        return db

    def find(self, video_id):
        with closing(self.connect()) as db:
            return db.execute('SELECT * FROM jobs WHERE video_id=?', (video_id,)).fetchone()

    def get(self, job_id):
        with closing(self.connect()) as db:
            row = db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
        if not row:
            raise Problem(404, 'job_not_found')
        return row

    def list(self, status):
        with closing(self.connect()) as db:
            return db.execute('SELECT * FROM jobs WHERE status=? ORDER BY created DESC LIMIT 100', (status,)).fetchall()

    def create(self, video_id, event_id, key, owner, theme):
        with closing(self.connect()) as db, db:
            db.execute('BEGIN IMMEDIATE')
            existing = db.execute('SELECT * FROM jobs WHERE video_id=?', (video_id,)).fetchone()
            if existing:
                if existing['owner'] != owner:
                    raise Problem(409, 'already_claimed')
                return existing
            event_count = db.execute('SELECT COUNT(*) FROM jobs WHERE event_id=?', (event_id,)).fetchone()[0]
            active = db.execute("SELECT COUNT(*) FROM jobs WHERE status IN ('queued','processing','review')").fetchone()[0]
            if event_count >= self.settings.max_event_jobs or active >= self.settings.max_active_jobs:
                raise Problem(429, 'queue_full')
            job_id, now = str(uuid.uuid4()), int(time.time())
            db.execute('''INSERT INTO jobs (id, video_id, event_id, source_key, owner, theme, status, created, updated)
                          VALUES (?, ?, ?, ?, ?, ?, 'queued', ?, ?)''',
                       (job_id, video_id, event_id, key, owner, theme, now, now))
            return db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()

    def claim(self):
        with closing(self.connect()) as db, db:
            db.execute('BEGIN IMMEDIATE')
            job = db.execute("""SELECT * FROM jobs WHERE status IN ('processing','queued')
                             ORDER BY CASE status WHEN 'processing' THEN 0 ELSE 1 END, created, rowid LIMIT 1""").fetchone()
            if job and job['status'] == 'queued':
                db.execute("UPDATE jobs SET status='processing', updated=? WHERE id=?",
                           (int(time.time()), job['id']))
            return job

    def transition(self, job_id, before, after, *, message=None, key=None):
        with closing(self.connect()) as db, db:
            result = db.execute('UPDATE jobs SET status=?, message=?, result_key=?, updated=? WHERE id=? AND status=?',
                                (after, message, key, int(time.time()), job_id, before))
            return result.rowcount == 1

    def subscribed(self, job_id):
        with closing(self.connect()) as db:
            row = db.execute('SELECT state FROM subscriptions WHERE job_id=? AND template_id=?',
                             (job_id, self.settings.template_id)).fetchone()
        return bool(row and row['state'] != 'rejected')

    def subscribe(self, job_id, template_id):
        with closing(self.connect()) as db, db:
            db.execute("""INSERT INTO subscriptions(job_id,template_id) VALUES(?,?)
                       ON CONFLICT(job_id,template_id) DO UPDATE SET state='pending', attempts=0, next_at=0
                       WHERE subscriptions.state='rejected'""", (job_id, template_id))

    def take_notification(self):
        with closing(self.connect()) as db, db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute("""SELECT s.*, j.owner, j.video_id, j.theme FROM subscriptions s
                              JOIN jobs j ON j.id=s.job_id WHERE j.status='ready'
                              AND s.state='pending' AND s.next_at<=? ORDER BY s.next_at LIMIT 1""",
                             (int(time.time()),)).fetchone()
            if row:
                db.execute("""UPDATE subscriptions SET state='sending', attempts=attempts+1
                           WHERE job_id=? AND template_id=?""", (row['job_id'], row['template_id']))
            return row

    def finish_notification(self, row, outcome):
        with closing(self.connect()) as db, db:
            db.execute('''UPDATE subscriptions SET state=?, next_at=? WHERE job_id=? AND template_id=?
                       AND state='sending' ''',
                       (outcome, int(time.time()) + 60, row['job_id'], row['template_id']))

    def recover_notifications(self):
        # A process may have died after WeChat accepted the request. Do not send it twice.
        with closing(self.connect()) as db, db:
            db.execute("UPDATE subscriptions SET state='unknown' WHERE state='sending'")
