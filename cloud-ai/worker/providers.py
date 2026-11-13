"""Cloud generation adapters. The journal protects against repeated paid submits."""

from base64 import b64encode
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


ARK = "https://ark.cn-beijing.volces.com/api/v3/images/generations"
KLING = "https://tokenhub.tencentmaas.com/v1/wand/kling"
TASK_ID = re.compile(r"[A-Za-z0-9_-]{4,150}\Z")


class WorkerError(Exception):
    """A diagnostic safe to include in the private job status."""

    def __init__(self, code, *, retryable=False):
        super().__init__(code)
        self.retryable = retryable


class RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def now():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent, suffix=".json.part")
    temp = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


class Journal:
    def __init__(self, path, inputs):
        self.path = path
        self.state = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"inputs": inputs}
        if self.state["inputs"] != inputs:
            raise WorkerError("job_inputs_changed")
        self.save()

    def save(self):
        write_json(self.path, self.state)

    def update(self, stage, **values):
        row = self.state.setdefault(stage, {})
        row.update(values)
        self.save()
        return row


@contextmanager
def exclusive_job(path):
    """Use an OS lock so a killed worker leaves the same job resumable."""
    with path.open("a+b") as stream:
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise WorkerError("worker_job_already_running", retryable=True) from None
        yield


def api_key(primary, *aliases):
    for name in (primary, *aliases):
        key = os.environ.get(name, "").strip()
        if key and all(33 <= ord(char) <= 126 for char in key):
            return key
    raise WorkerError(f"missing_{primary.lower()}")


def checked_url(url):
    if not isinstance(url, str):
        raise WorkerError("invalid_media_url")
    try:
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
                or parsed.port not in (None, 443)):
            raise WorkerError("invalid_media_url")
    except ValueError:
        raise WorkerError("invalid_media_url") from None
    return url


def api_request(url, key, *, body=None, timeout=60):
    payload = json.dumps(body, ensure_ascii=False, allow_nan=False).encode("utf-8") if body is not None else None
    request = Request(url, data=payload, headers={
        "Authorization": f"Bearer {key}", "Accept": "application/json", "Content-Type": "application/json",
    })
    try:
        with build_opener(RejectRedirect).open(request, timeout=timeout) as response:
            reply = json.loads(response.read(1024 * 1024))
    except HTTPError as exc:
        raise WorkerError(f"provider_http_{exc.code}", retryable=exc.code == 429 or exc.code >= 500) from None
    except (URLError, OSError, ValueError):
        raise WorkerError("provider_unavailable", retryable=True) from None
    if not isinstance(reply, dict):
        raise WorkerError("provider_invalid_reply")
    return reply


def download(url, output, limit):
    request = Request(checked_url(url))
    part = output.with_suffix(output.suffix + ".part")
    try:
        with build_opener(RejectRedirect).open(request, timeout=120) as response, part.open("wb") as target:
            total = 0
            while chunk := response.read(1024 * 1024):
                total += len(chunk)
                if total > limit:
                    raise WorkerError("provider_media_too_large")
                target.write(chunk)
            if total == 0:
                raise WorkerError("provider_media_empty")
        part.replace(output)
    except HTTPError as exc:
        raise WorkerError(f"provider_media_http_{exc.code}", retryable=exc.code == 429 or exc.code >= 500) from None
    except (URLError, OSError):
        raise WorkerError("provider_media_unavailable", retryable=True) from None
    finally:
        part.unlink(missing_ok=True)


def data_uri(path):
    mime = "image/png" if path.suffix == ".png" else "image/jpeg"
    return f"data:{mime};base64," + b64encode(path.read_bytes()).decode("ascii")


@dataclass
class CloudProviders:
    ark_key: str | None
    kling_key: str
    journal: Journal
    poll_seconds: int

    def image(self, stage, prompt, references, output):
        state = self.journal.state.get(stage, {})
        if output.is_file():
            self.journal.update(stage, status="downloaded")
            return
        if state.get("status") == "submitting":
            raise WorkerError("image_submission_uncertain")
        url = state.get("url")
        if not url:
            if not self.ark_key:
                raise WorkerError("missing_ark_api_key")
            self.journal.update(stage, status="submitting", startedAt=now())
            try:
                reply = api_request(ARK, self.ark_key, timeout=180, body={
                    "model": os.environ.get("BOOTH360_AI_SEEDREAM_MODEL", "doubao-seedream-5-0-pro-260628"),
                    "prompt": prompt, "size": "1K",
                    "image": [data_uri(path) for path in references],
                    "response_format": "url", "output_format": "png", "background": "opaque",
                    "optimize_prompt_options": {"mode": "fast"}, "watermark": False,
                })
            except WorkerError as exc:
                raise WorkerError(str(exc)) from None
            rows = reply.get("data")
            url = next((row.get("url") for row in rows if isinstance(row, dict) and row.get("url")), None) if isinstance(rows, list) else None
            self.journal.update(stage, status="generated", finishedAt=now(), url=checked_url(url))
        download(url, output, 15 * 1024 * 1024)
        if output.stat().st_size < 24:
            output.unlink()
            raise WorkerError("invalid_provider_image")
        with output.open("rb") as stream:
            if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                output.unlink()
                raise WorkerError("invalid_provider_image")
        self.journal.update(stage, status="downloaded", url=None)

    def video(self, prompt, first, wardrobe, tail, guide_url, output):
        if output.is_file():
            self.journal.update("video", status="downloaded")
            return
        state = self.journal.state.get("video", {})
        if state.get("status") == "failed":
            raise WorkerError("video_generation_failed")
        task_id = state.get("taskId")
        if not task_id:
            if state.get("status") == "submitting":
                raise WorkerError("video_submission_uncertain")
            contents = [
                {"type": "prompt", "text": prompt},
                {"type": "first_frame", "url": data_uri(first)},
                {"type": "last_frame", "url": data_uri(tail)},
                {"type": "feature_video", "url": checked_url(guide_url)},
                {"type": "refer_image", "url": data_uri(wardrobe)},
            ]
            self.journal.update("video", status="submitting", startedAt=now())
            try:
                reply = api_request(f"{KLING}/omni-video", self.kling_key, timeout=90, body={
                    "model": "kling-video-v4", "contents": contents,
                    "settings": {"duration": 8, "resolution": "1080p", "aspect_ratio": "9:16"},
                })
            except WorkerError as exc:
                raise WorkerError(str(exc)) from None
            task_id = reply.get("data", {}).get("id") if isinstance(reply.get("data"), dict) else None
            if reply.get("code") != 0 or not isinstance(task_id, str) or not TASK_ID.fullmatch(task_id):
                raise WorkerError("video_submission_uncertain")
            state = self.journal.update("video", status="submitted", taskId=task_id)
        if not isinstance(task_id, str) or not TASK_ID.fullmatch(task_id):
            raise WorkerError("invalid_provider_task_id")
        deadline = time.monotonic() + self.poll_seconds
        while True:
            reply = api_request(f"{KLING}/tasks/{task_id}", self.kling_key, timeout=30)
            result = reply.get("data")
            rows = result if isinstance(result, list) else [result]
            item = next((row for row in rows if isinstance(row, dict) and row.get("id") == task_id), None)
            if reply.get("code") != 0 or not item:
                raise WorkerError("video_task_unavailable", retryable=True)
            status = item.get("status")
            if status == "failed":
                self.journal.update("video", status="failed", finishedAt=now())
                raise WorkerError("video_generation_failed")
            if status == "succeeded":
                usage = reply.get("tokenhub_usage")
                tokens = usage.get("total_tokens") if isinstance(usage, dict) else None
                self.journal.update("video", status="succeeded", finishedAt=state.get("finishedAt") or now(),
                                    tokens=tokens if type(tokens) is int else state.get("tokens"))
                outputs = item.get("outputs")
                url = next((row.get("url") for row in outputs if isinstance(row, dict) and row.get("type") == "video"), None) if isinstance(outputs, list) else None
                download(url, output, 256 * 1024 * 1024)
                self.journal.update("video", status="downloaded")
                return
            if status not in ("submitted", "processing", "queued", "running"):
                raise WorkerError("video_unknown_status", retryable=True)
            if state.get("status") != status:
                state = self.journal.update("video", status=status)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise WorkerError("video_waiting_for_provider", retryable=True)
            time.sleep(min(8, remaining))
