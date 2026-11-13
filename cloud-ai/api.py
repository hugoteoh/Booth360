"""Booth360 mini-program API. Run with uvicorn api:production --factory."""

import base64
import binascii
import hashlib
import hmac
import json
import os
import time

from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, StrictBool

from integrations import CosStorage, WeChat
from pilot import Problem, Queue, Settings, THEMES, identifier, source_key


PREFIX = '/booth360/ai-api'


class SessionRequest(BaseModel):
    code: str = Field(min_length=1, max_length=256)


class JobRequest(BaseModel):
    themeId: str = Field(min_length=1, max_length=32)
    consent: StrictBool


class SubscriptionRequest(BaseModel):
    templateId: str = Field(min_length=1, max_length=128)


class Sessions:
    def __init__(self, secret):
        self.secret = secret.encode()
        if len(self.secret) < 32:
            raise ValueError('BOOTH360_AI_SESSION_SECRET must have at least 32 bytes')

    def issue(self, owner):
        payload = base64.urlsafe_b64encode(json.dumps([owner, int(time.time()) + 86400]).encode())
        signature = hmac.new(self.secret, payload, hashlib.sha256).hexdigest()
        return f'{payload.decode()}.{signature}'

    def owner(self, header):
        if not header or not header.startswith('Bearer ') or len(header) > 1024:
            raise Problem(401, 'login_required')
        try:
            payload, signature = header[7:].split('.', 1)
            expected = hmac.new(self.secret, payload.encode('ascii'), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(expected, signature):
                raise ValueError()
            owner, expires = json.loads(base64.urlsafe_b64decode(payload))
            if expires <= time.time():
                raise ValueError()
        except (ValueError, TypeError, binascii.Error):
            raise Problem(401, 'login_required') from None
        return owner


def source_metadata(storage, video_id):
    mapping = storage.read_json(f'booth360/ai/sources/{video_id}.json')
    if mapping is None:
        return None
    if not isinstance(mapping, dict) or mapping.get('schema') != 1:
        raise Problem(503, 'invalid_metadata')
    return identifier(mapping.get('eventId')), source_key(video_id, mapping.get('objectKey'))


def enabled_metadata(storage, video_id):
    source = source_metadata(storage, video_id)
    if not source:
        return None
    event = storage.read_json(f'booth360/ai/events/{source[0]}.json')
    if isinstance(event, dict) and event.get('schema') == 1 and event.get('enabled') is True:
        return source
    return None


def create_app(settings, storage, wechat, session_secret):
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    sessions = Sessions(session_secret)
    queue = Queue(settings)

    @app.middleware('http')
    async def no_cache(request: Request, call_next):
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        return response

    @app.exception_handler(Problem)
    async def handle_problem(_request, error):
        return JSONResponse({'detail': error.detail}, status_code=error.status)

    def state(enabled, job, owner):
        own = bool(job and job['owner'] == owner)
        available = bool(enabled and (not job or own))
        result = {'enabled': available, 'themes': [THEMES[k] for k in settings.themes] if available else [],
                  'job': None, 'subscribed': False}
        if own:
            result['job'] = {'id': job['id'], 'themeId': job['theme'], 'status': job['status']}
            if job['status'] == 'ready':
                result['job']['downloadUrl'] = storage.signed_url(job['result_key'])
            if job['status'] == 'failed':
                result['job']['message'] = '这条 AI 视频未生成成功，原版仍可保存。'
            result['subscribed'] = queue.subscribed(job['id'])
        if settings.template_id and own and job['status'] != 'failed':
            result['notificationTemplateId'] = settings.template_id
        return result

    @app.get(PREFIX + '/health')
    def health():
        return {'ok': True}

    @app.post(PREFIX + '/session')
    def login(body: SessionRequest):
        return {'token': sessions.issue(wechat.exchange(body.code))}

    @app.get(PREFIX + '/videos/{video_id}')
    def video(video_id: str, authorization: str | None = Header(default=None)):
        owner, video_id = sessions.owner(authorization), identifier(video_id)
        return state(enabled_metadata(storage, video_id), queue.find(video_id), owner)

    @app.get(PREFIX + '/videos/{video_id}/original')
    def original(video_id: str, authorization: str | None = Header(default=None)):
        sessions.owner(authorization)
        source = source_metadata(storage, identifier(video_id))
        if not source:
            raise Problem(404, 'original_not_found')
        return {'downloadUrl': storage.signed_url(source[1])}

    @app.post(PREFIX + '/videos/{video_id}/jobs')
    def generate(video_id: str, body: JobRequest, authorization: str | None = Header(default=None)):
        owner, video_id = sessions.owner(authorization), identifier(video_id)
        existing = queue.find(video_id)
        if existing and existing['owner'] != owner:
            raise Problem(409, 'already_claimed')
        source = enabled_metadata(storage, video_id)
        if existing:
            return state(source, existing, owner)
        if not source:
            raise Problem(403, 'event_disabled')
        if not body.consent or body.themeId not in settings.themes:
            raise Problem(422, 'invalid_theme_or_consent')
        job = queue.create(video_id, source[0], source[1], owner, body.themeId)
        return state(source, job, owner)

    @app.post(PREFIX + '/videos/{video_id}/subscription')
    def subscribe(video_id: str, body: SubscriptionRequest, authorization: str | None = Header(default=None)):
        owner, video_id = sessions.owner(authorization), identifier(video_id)
        job = queue.find(video_id)
        if not settings.template_id or body.templateId != settings.template_id:
            raise Problem(422, 'template_unavailable')
        if not job or job['owner'] != owner or job['status'] == 'failed':
            raise Problem(404, 'job_not_found')
        queue.subscribe(job['id'], settings.template_id)
        return {'ok': True}

    return app


def production():
    return create_app(Settings.from_env(), CosStorage(), WeChat(), os.environ['BOOTH360_AI_SESSION_SECRET'])
