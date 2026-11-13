"""Run a Booth360 generation job or recompose an existing provider result."""

import argparse
from dataclasses import asdict
import json
import math
import os
from pathlib import Path
import sys

from . import media
from .providers import CloudProviders, Journal, WorkerError, api_key, checked_url, exclusive_job, write_json
from .themes import THEMES, tail_prompt, video_prompt, wardrobe_prompt


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def timing_override(path):
    if path is None:
        return {}
    values = json.loads(path.read_text(encoding="utf-8"))
    timestamps = {"seam", "front", "sceneBeat", "ending"}
    if not isinstance(values, dict) or values.keys() - (timestamps | {"direction", "generatedAnchors"}):
        raise WorkerError("invalid_timing_fields")
    if any(not number(values[key]) for key in timestamps & values.keys()):
        raise WorkerError("invalid_timing_timestamp")
    if "direction" in values and values["direction"] not in ("left", "right"):
        raise WorkerError("invalid_timing_direction")
    if "generatedAnchors" in values:
        anchors = values["generatedAnchors"]
        if not isinstance(anchors, list) or len(anchors) != 3 or not all(map(number, anchors)):
            raise WorkerError("invalid_generated_timing")
    return values


def generate(args, theme, timing, fps, directory, journal):
    raw = directory / "generated.mp4"
    if raw.is_file():
        return raw
    if args.mock_generated:
        return args.mock_generated
    guide_url = args.guide_url or os.environ.get("BOOTH360_AI_SHANGHAI_GUIDE_URL")
    guide_order = (
        "@video_1 demonstrates camera motion, timing, and continuity. The person in the video guide is "
        "unrelated to the subject and their appearance and accessories are not a reference. "
        "The real first frame and the supplied stills define the sole subject's facial identity, clothing, "
        "setting and any original event graphics."
    )
    has_task = bool(journal.state.get("video", {}).get("taskId"))
    if not has_task:
        checked_url(guide_url)
        if timing["direction"] not in ("left", "right"):
            raise WorkerError("source_orbit_direction_uncertain")
        if timing["direction"] != args.guide_direction:
            raise WorkerError("guide_direction_conflicts_with_source")
    providers = CloudProviders(
        api_key("ARK_API_KEY", "BOOTH360_AI_ARK_API_KEY") if not has_task else None,
        api_key("TENCENT_TOKENHUB_API_KEY", "TOKENHUB_API_KEY", "BOOTH360_AI_TOKENHUB_API_KEY"),
        journal, args.poll_seconds,
    )
    first, front, wardrobe, tail = (directory / name for name in ("seam.jpg", "front.jpg", "wardrobe.png", "tail.png"))
    if not has_task:
        for stamp, path in ((timing["seam"], first), (timing["front"], front)):
            if not path.is_file():
                media.take_frame(args.source, stamp, fps, path)
        providers.image("wardrobe", wardrobe_prompt(theme), [front], wardrobe)
        providers.image("tail", tail_prompt(theme), [front, wardrobe], tail)
    providers.video(video_prompt(theme, timing["direction"], (1.50, 3.67, 6.25), guide_order),
                    first, wardrobe, tail, guide_url, raw)
    return raw


def execute(args, directory):
    source = args.source
    candidate = directory / "candidate.mp4"
    report_path = directory / "review.json"
    source_media = media.probe(source)
    media.source_check(source_media)
    override = timing_override(args.timing)
    journal = Journal(directory / "provider-state.json", {
        "theme": args.theme, "sourceHash": media.sha256(source), "mock": bool(args.mock_generated),
        "mockHash": media.sha256(args.mock_generated) if args.mock_generated else None,
    })
    if candidate.is_file() and report_path.is_file():
        existing = json.loads(report_path.read_text(encoding="utf-8"))
        if existing.get("timingOverride") == override and existing.get("candidateHash") == media.sha256(candidate):
            return existing
    analysis = media.timeline(source, source_media, override)
    previous = journal.state.get("analysis", {})
    has_inputs = any((directory / name).exists() for name in ("seam.jpg", "front.jpg", "wardrobe.png", "tail.png"))
    if has_inputs and not (directory / "generated.mp4").exists():
        if any(previous.get(key) != analysis[key] for key in ("seam", "front", "direction")):
            raise WorkerError("submitted_source_timing_changed")
    journal.update("analysis", **analysis)
    generated = generate(args, THEMES[args.theme], analysis, source_media.fps, directory, journal)
    verification = media.compose(source, generated, candidate, analysis, override)
    report = {
        "version": 1, "theme": args.theme, "status": "review", "mock": bool(args.mock_generated),
        "timeline": analysis, "timingOverride": override, "verification": verification,
        "candidateHash": media.sha256(candidate), "original": asdict(source_media),
        "requiredChecks": [
            "确认首次正面时衣料逐步变化，活动现场仍可见",
            "确认换景主变化贴合原音乐拍点，镜头和动作连贯",
            "确认实拍接入和生成段中背景沿原片方向运动",
            "确认人物、原有标识和收尾动作自然",
        ],
    }
    write_json(report_path, report)
    journal.update("result", status="review")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--theme", choices=THEMES, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--guide-url")
    parser.add_argument("--guide-direction", choices=("left", "right"), default="left")
    parser.add_argument("--timing", type=Path)
    parser.add_argument("--mock-generated", type=Path)
    parser.add_argument("--poll-seconds", type=int, default=720)
    args = parser.parse_args()
    if not 0 <= args.poll_seconds <= 2400:
        parser.error("poll seconds must be between 0 and 2400")
    try:
        args.source = args.source.resolve(strict=True)
        args.work_dir.mkdir(parents=True, exist_ok=True)
        directory = args.work_dir.resolve()
        with exclusive_job(directory / "worker.lock"):
            report = execute(args, directory)
    except WorkerError as exc:
        print(json.dumps({"status": "retry" if exc.retryable else "failed", "reason": str(exc)}), file=sys.stderr)
        return 75 if exc.retryable else 1
    except (ValueError, OSError, KeyError, TypeError):
        print(json.dumps({"status": "failed", "reason": "worker_input_or_storage_error"}), file=sys.stderr)
        return 1
    print(json.dumps({"status": report["status"], "theme": report["theme"], "mock": report["mock"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
