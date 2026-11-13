"""Tencent COS storage and WeChat mini-program server calls."""

import json
import os
import threading
import time
from pathlib import Path

import requests

from pilot import Problem


class CosStorage:
    def __init__(self):
        from qcloud_cos import CosConfig, CosS3Client
        self.bucket = os.environ['BOOTH360_COS_BUCKET']
        self.client = CosS3Client(CosConfig(
            Region=os.environ['BOOTH360_COS_REGION'],
            SecretId=os.environ['BOOTH360_COS_SECRET_ID'],
            SecretKey=os.environ['BOOTH360_COS_SECRET_KEY'],
            Token=os.getenv('BOOTH360_COS_TOKEN') or None, Scheme='https', Timeout=30,
        ))

    def read_json(self, key):
        from qcloud_cos.cos_exception import CosClientError, CosServiceError
        try:
            with self.client.get_object(Bucket=self.bucket, Key=key)['Body'].get_raw_stream() as body:
                data = body.read(8193)
            if len(data) > 8192:
                raise Problem(503, 'invalid_metadata')
            return json.loads(data)
        except CosServiceError as exc:
            if exc.get_status_code() == 404:
                return None
            raise Problem(503, 'storage_unavailable') from None
        except (ValueError, OSError, CosClientError):
            raise Problem(503, 'storage_unavailable') from None

    def download(self, key, path):
        path = Path(path)
        pending = path.with_suffix('.part')
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=key)
            max_bytes = 150 * 1024 * 1024
            received = 0
            with response['Body'].get_raw_stream() as stream, pending.open('wb') as target:
                while chunk := stream.read(256 * 1024):
                    received += len(chunk)
                    if received > max_bytes:
                        raise Problem(413, 'source_too_large')
                    target.write(chunk)
            if not received:
                raise Problem(422, 'empty_source')
            pending.replace(path)
        finally:
            pending.unlink(missing_ok=True)

    def upload(self, key, path):
        with Path(path).open('rb') as data:
            self.client.put_object(Bucket=self.bucket, Key=key, Body=data, ACL='private', ContentType='video/mp4')
        self.client.head_object(Bucket=self.bucket, Key=key)

    def signed_url(self, key, seconds=1800):
        return self.client.get_presigned_url(Method='GET', Bucket=self.bucket, Key=key, Expired=seconds)


class WeChat:
    BASE = 'https://api.weixin.qq.com'

    def __init__(self):
        self.appid = os.getenv('BOOTH360_WX_APP_ID', '')
        self.secret = os.getenv('BOOTH360_WX_APP_SECRET', '')
        self.token = None
        self.refresh_at = 0
        self.lock = threading.Lock()

    def exchange(self, code):
        if not self.appid or not self.secret:
            raise Problem(503, 'wechat_not_configured')
        try:
            response = requests.get(f'{self.BASE}/sns/jscode2session', params={
                'appid': self.appid, 'secret': self.secret, 'js_code': code, 'grant_type': 'authorization_code',
            }, timeout=10, allow_redirects=False)
            data = response.json()
        except (ValueError, requests.RequestException):
            raise Problem(503, 'wechat_unavailable') from None
        openid = data.get('openid') if isinstance(data, dict) else None
        if response.status_code != 200 or not isinstance(openid, str) or not 8 <= len(openid) <= 128:
            raise Problem(401, 'wechat_login_failed')
        return openid

    def access_token(self, force=False):
        if not self.appid or not self.secret:
            raise ValueError('WeChat login unavailable')
        with self.lock:
            if not force and self.refresh_at > time.monotonic():
                return self.token
            response = requests.post(f'{self.BASE}/cgi-bin/stable_token', json={
                'grant_type': 'client_credential', 'appid': self.appid, 'secret': self.secret, 'force_refresh': False,
            }, timeout=10, allow_redirects=False)
            data = response.json()
            if response.status_code != 200 or not data.get('access_token'):
                raise ValueError('WeChat token unavailable')
            self.token = data['access_token']
            self.refresh_at = time.monotonic() + max(int(data['expires_in']) - 120, 0)
            return self.token

    def send(self, *, owner, video_id, template_id, fields):
        payload = {
            'touser': owner, 'template_id': template_id, 'page': f'pages/booth/index?sid={video_id}',
            'data': {name: {'value': value} for name, value in fields.items()},
            'miniprogram_state': os.getenv('BOOTH360_WX_PROGRAM_STATE', 'formal'), 'lang': 'zh_CN',
        }
        for force in (False, True):
            try:
                token = self.access_token(force=force)
            except (ValueError, KeyError, requests.RequestException):
                return 'pending'
            try:
                response = requests.post(f'{self.BASE}/cgi-bin/message/subscribe/send',
                                         params={'access_token': token}, json=payload,
                                         timeout=10, allow_redirects=False)
                data = response.json()
                code = data.get('errcode') if isinstance(data, dict) else None
            except (ValueError, requests.RequestException):
                return 'unknown'
            if code not in (40001, 40014, 42001):
                break
        if code is None:
            return 'unknown'
        if code == 0:
            return 'sent'
        if code in (-1, 40001, 40014, 42001, 45009):
            return 'pending'
        return 'rejected'
