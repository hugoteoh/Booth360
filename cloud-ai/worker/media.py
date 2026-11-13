"""Measure the input and compose an AI clip on the original soundtrack timeline."""

from contextlib import contextmanager
from dataclasses import dataclass
from fractions import Fraction
import hashlib
import json
import math
import os
import subprocess

import cv2
import numpy as np

from .providers import WorkerError


WIDTH = 1080
HEIGHT = 1920
SAMPLE_WIDTH = 270
SAMPLE_HEIGHT = 480
SAMPLE_RATE = 12
FRAME_BYTES = WIDTH * HEIGHT * 3 // 2
NORMALIZE = (
    f"scale={WIDTH}:{HEIGHT}:force_original_aspect_ratio=decrease:force_divisible_by=2,"
    f"pad={WIDTH}:{HEIGHT}:(ow-iw)/2:(oh-ih)/2,setsar=1"
)


def command(tool, *args):
    binary = os.environ.get(f"BOOTH360_AI_{tool.upper()}", tool)
    options = ("-hide_banner", "-nostdin", "-loglevel", "error") if tool == "ffmpeg" else ("-v", "error")
    return [binary, *options, *(str(arg) for arg in args)]


def run(tool, *args, timeout=90):
    try:
        return subprocess.run(command(tool, *args), capture_output=True, check=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        raise WorkerError(f"{tool}_failed") from None


@contextmanager
def process(*args, **stdio):
    with subprocess.Popen(command("ffmpeg", *args), stderr=subprocess.DEVNULL, **stdio) as child:
        try:
            yield child
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()


@dataclass(frozen=True)
class Media:
    width: int
    height: int
    fps: float
    duration: float
    video_start: float
    container_start: float
    audio_start: float | None
    codec: str


def probe(path):
    reply = json.loads(run("ffprobe", "-show_streams", "-show_format", "-of", "json", path))
    video = next((stream for stream in reply["streams"] if stream["codec_type"] == "video"), None)
    audio = next((stream for stream in reply["streams"] if stream["codec_type"] == "audio"), None)
    if not video:
        raise WorkerError("video_missing")
    container = reply["format"]
    try:
        width, height = int(video["width"]), int(video["height"])
        fps = float(Fraction(video["avg_frame_rate"]))
        duration = float(video.get("duration") or container["duration"])
        rotation = next((row.get("rotation", 0) for row in video.get("side_data_list", [])
                         if "rotation" in row), 0)
        if abs(int(rotation)) % 180 == 90:
            width, height = height, width
        return Media(width, height, fps, duration, float(video.get("start_time", 0)),
                     float(container.get("start_time", 0)), float(audio.get("start_time", 0)) if audio else None,
                     str(video["codec_name"]))
    except (KeyError, ValueError, ZeroDivisionError):
        raise WorkerError("invalid_video_metadata") from None


def source_check(media):
    if (not all(map(math.isfinite, (media.duration, media.fps))) or not 4 <= media.duration <= 45
            or not 12 <= media.fps <= 61 or not 0.44 <= media.width / media.height <= 0.72):
        raise WorkerError("unsupported_original_video")


def samples(path):
    raw = run("ffmpeg", "-threads", 2, "-i", path, "-map", "0:v:0", "-an", "-filter_threads", 2,
              "-vf", f"fps={SAMPLE_RATE},scale={SAMPLE_WIDTH}:{SAMPLE_HEIGHT}", "-pix_fmt", "gray",
              "-threads", 1, "-f", "rawvideo", "-")
    if not raw or len(raw) % (SAMPLE_WIDTH * SAMPLE_HEIGHT):
        raise WorkerError("video_samples_missing")
    return np.frombuffer(raw, np.uint8).reshape(-1, SAMPLE_HEIGHT, SAMPLE_WIDTH)


def frontal_time(frames, duration):
    classifier = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_alt2.xml")
    candidates = []
    for index in range(max(1, round(duration * .13 * SAMPLE_RATE)), min(len(frames), round(duration * .52 * SAMPLE_RATE))):
        if index % 2:
            continue
        frame = frames[index, 35:345, 50:220]
        boxes, _, scores = classifier.detectMultiScale3(frame, scaleFactor=1.1, minNeighbors=4,
                                                        minSize=(25, 25), outputRejectLevels=True)
        for (x, y, width, height), score in zip(boxes, scores):
            # Subject faces in Booth360 are larger and closer to center than event attendees.
            if abs(50 + x + width / 2 - SAMPLE_WIDTH / 2) <= SAMPLE_WIDTH * .19:
                candidates.append((index, float(score) + width / 10))
    if not candidates:
        return None
    best = max(score for _, score in candidates)
    return min(index for index, score in candidates if score >= best - 2.5) / SAMPLE_RATE


def flow_pairs(frames):
    background = np.zeros(frames.shape[1:], dtype=np.uint8)
    background[12:110, 12:-12] = 255
    background[110:345, 10:55] = 255
    background[110:345, -55:-10] = 255
    evidence = []
    for index, (before, after) in enumerate(zip(frames[:-1], frames[1:])):
        points = cv2.goodFeaturesToTrack(before, 100, .015, 7, mask=background)
        if points is None or len(points) < 8:
            continue
        following, matched, _ = cv2.calcOpticalFlowPyrLK(before, after, points, None, winSize=(25, 25))
        if following is None:
            continue
        backward, returned, _ = cv2.calcOpticalFlowPyrLK(after, before, following, None, winSize=(25, 25))
        if backward is None:
            continue
        good = (matched[:, 0] > 0) & (returned[:, 0] > 0) & (np.linalg.norm(backward - points, axis=(1, 2)) < 1.5)
        origin = points[good, 0]
        if len(origin) < 8 or np.ptp(origin[:, 0]) < 45:
            continue
        delta = following[good, 0] - origin
        horizontal, vertical = np.median(delta, axis=0)
        coherence = float(np.mean(np.sign(delta[:, 0]) == np.sign(horizontal)))
        if abs(horizontal) >= .65 and abs(vertical) <= max(abs(horizontal) * 1.35, 1.5) and coherence >= .70:
            evidence.append((round((index + .5) / SAMPLE_RATE, 3), round(float(horizontal * SAMPLE_RATE), 2)))
    return evidence


def direction_of(evidence, begin, end):
    velocities = [velocity for timestamp, velocity in evidence if begin <= timestamp < end]
    if len(velocities) < 4:
        return "uncertain"
    left = sum(velocity < 0 for velocity in velocities) / len(velocities)
    if left >= .72:
        return "left"
    if left <= .28:
        return "right"
    return "mixed"


def beat_peaks(path, media):
    if media.audio_start is None:
        return []
    raw = run("ffmpeg", "-i", path, "-map", "0:a:0", "-vn", "-ar", 16000, "-ac", 1, "-f", "f32le", "-")
    samples = np.frombuffer(raw, np.float32)
    hop, width = 160, 640
    if len(samples) < width:
        return []
    windows = np.lib.stride_tricks.sliding_window_view(samples, width)[::hop]
    spectrum = np.abs(np.fft.rfft(windows * np.hanning(width), axis=1))
    bins = np.fft.rfftfreq(width, 1 / 16000)
    spectrum = np.log1p(spectrum / np.maximum(spectrum.mean(axis=0), .02))
    flux = np.maximum(np.diff(spectrum, axis=0, prepend=spectrum[:1]), 0)
    score = (flux[:, (bins >= 40) & (bins <= 210)].mean(axis=1) * 2
             + flux[:, (bins >= 250) & (bins <= 3000)].mean(axis=1))
    score = np.convolve(score, np.ones(3) / 3, mode="same")
    threshold = max(float(np.percentile(score, 70)), .01)
    offset = media.audio_start - media.video_start
    return [(round(index * .01 + width / 32000 + offset, 3), float(score[index]))
            for index in range(1, len(score) - 1)
            if score[index] > threshold and score[index - 1] < score[index] >= score[index + 1]]


def timeline(path, media, override):
    cv2.setNumThreads(2)
    duration = media.duration
    frames = samples(path)
    evidence = flow_pairs(frames)
    front_detected = frontal_time(frames, duration) if "front" not in override else None
    front = override.get("front", front_detected or duration * .32)
    seam = override.get("seam", max(.15, front - min(1.65, duration * .16)))
    ending = override.get("ending", duration * .82)
    scene_center = max(front + .9, duration * .54)
    scene = override.get("sceneBeat")
    nearby = []
    if scene is None:
        nearby = [(time, strength) for time, strength in beat_peaks(path, media)
                  if abs(time - scene_center) <= min(.8, duration * .075) and front + .55 < time < ending - .55]
        scene = max(nearby, key=lambda item: item[1] / (1 + .6 * abs(item[0] - scene_center)))[0] if nearby else scene_center
    if not .05 < seam < front < scene < ending < duration - .08:
        raise WorkerError("invalid_orbit_timing")
    source_direction = direction_of(evidence, max(0, seam - .5), min(duration, front + .8))
    override_direction = override.get("direction")
    if source_direction in ("left", "right") and override_direction and override_direction != source_direction:
        raise WorkerError("manual_direction_conflicts_with_source")
    direction = override_direction or source_direction
    return {
        "seam": round(seam, 3), "front": round(front, 3), "sceneBeat": round(scene, 3), "ending": round(ending, 3),
        "direction": direction, "sourceDirection": source_direction,
        "frontEvidence": "operator" if "front" in override else ("face-detection" if front_detected else "estimate"),
        "beatEvidence": "operator" if "sceneBeat" in override else ("audio-onset" if nearby else "estimate"),
        "sourceMotionPairs": len(evidence),
    }


def take_frame(source, timestamp, fps, target):
    pending = target.with_suffix(".part.jpg")
    try:
        index = round(timestamp * fps)
        run("ffmpeg", "-y", "-threads", 2, "-i", source, "-map", "0:v:0", "-frames:v", 1,
            "-vf", f"fps={fps},select=eq(n\\,{index}),{NORMALIZE}", "-q:v", 2, "-threads", 1,
            "-update", 1, pending)
        if not pending.is_file():
            raise WorkerError("source_frame_missing")
        pending.replace(target)
    finally:
        pending.unlink(missing_ok=True)


def digest_audio(path):
    result = run("ffmpeg", "-i", path, "-map", "0:a:0", "-c:a", "copy", "-f", "hash", "-hash", "sha256", "-")
    return result.decode("ascii").strip()


def media_read_args(path, fps):
    return ("-threads", 2, "-i", path, "-map", "0:v:0", "-an", "-filter_threads", 2, "-vf", f"fps={fps},{NORMALIZE}",
            "-pix_fmt", "yuv420p", "-threads", 1, "-f", "rawvideo", "-")


def read_frame(stream):
    frame = stream.read(FRAME_BYTES)
    if len(frame) != FRAME_BYTES:
        raise WorkerError("unexpected_video_frame_count")
    return frame


def frame_anchors(analysis, override, original, generated):
    fps = original.fps
    frame_count = round(original.duration * fps)
    final_time = (frame_count - 1) / fps
    seam_frame = round(analysis["seam"] * fps)
    generated_frames = round(generated.duration * generated.fps)
    raw_end = (generated_frames - 1) / generated.fps
    raw_beats = override.get("generatedAnchors", [1.5, 3.667, 6.25])
    # Default hints match the timing guide. Exact event frames are checked in review.
    if not 0 < raw_beats[0] < raw_beats[1] < raw_beats[2] < raw_end:
        raise WorkerError("invalid_generated_timing")
    if not seam_frame / fps < analysis["front"] < analysis["sceneBeat"] < analysis["ending"] < final_time:
        raise WorkerError("invalid_output_timing")
    anchors = [(seam_frame / fps, 0), (analysis["front"], raw_beats[0]), (analysis["sceneBeat"], raw_beats[1]),
               (analysis["ending"], raw_beats[2]), (final_time, raw_end)]
    target = np.arange(seam_frame, frame_count) / fps
    mapping = np.clip(np.rint(np.interp(target, *zip(*anchors)) * generated.fps), 0, generated_frames - 1).astype(int)
    return fps, seam_frame, frame_count, mapping, anchors


def compose(source_path, generated_path, output, analysis, override):
    original, generated = probe(source_path), probe(generated_path)
    source_check(original)
    if (not 7.6 <= generated.duration <= 8.4 or not 12 <= generated.fps <= 61
            or generated.width != WIDTH or generated.height != HEIGHT):
        raise WorkerError("invalid_generated_video")
    fps, seam_frame, count, mapping, anchors = frame_anchors(analysis, override, original, generated)
    pending = output.with_suffix(".part.mp4")
    soundtrack = original.audio_start is not None
    adjustment = original.container_start - original.video_start
    audio_args = ("-itsoffset", f"{adjustment:.6f}", "-i", source_path, "-map", "0:v:0", "-map", "1:a:0",
                  "-c:a", "copy") if soundtrack else ("-map", "0:v:0", "-an")
    encoder_name = os.getenv("BOOTH360_AI_H264_ENCODER", "libx264")
    if encoder_name not in ("libx264", "libopenh264"):
        raise WorkerError("unsupported_h264_encoder")
    quality = ("-preset", "fast", "-crf", 17) if encoder_name == "libx264" else ("-b:v", "12M")
    try:
        with (process(*media_read_args(source_path, fps), stdout=subprocess.PIPE) as live,
              process(*media_read_args(generated_path, generated.fps), stdout=subprocess.PIPE) as effect,
              process("-y", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", f"{WIDTH}x{HEIGHT}", "-r", fps, "-i", "-",
                      *audio_args, "-c:v", encoder_name, "-threads", 4, *quality,
                      "-movflags", "+faststart", pending, stdin=subprocess.PIPE) as encoder):
            for _ in range(seam_frame):
                encoder.stdin.write(read_frame(live.stdout))
            effect_index = -1
            for target in mapping:
                while effect_index < target:
                    frame = read_frame(effect.stdout)
                    effect_index += 1
                encoder.stdin.write(frame)
            encoder.stdin.close()
            if encoder.wait(timeout=120):
                raise WorkerError("composition_failed")
        metadata = probe(pending)
        if (metadata.codec != "h264" or (metadata.width, metadata.height) != (WIDTH, HEIGHT)
                or abs(metadata.duration - count / fps) > 1.5 / fps):
            raise WorkerError("candidate_video_verification_failed")
        audio_hash = digest_audio(source_path) if soundtrack else None
        if soundtrack and (metadata.audio_start is None or digest_audio(pending) != audio_hash
                           or abs((metadata.audio_start - metadata.video_start)
                                  - (original.audio_start - original.video_start)) > .06):
            raise WorkerError("original_audio_verification_failed")
        run("ffmpeg", "-xerror", "-threads", 2, "-i", pending, "-map", "0:v:0", "-map", "0:a:0?", "-f", "null", "-")
        output_frames = samples(pending)
        evidence = flow_pairs(output_frames)
        markers = [analysis["seam"], analysis["front"], analysis["sceneBeat"], analysis["ending"], metadata.duration]
        segments = [{"start": start, "end": end, "direction": direction_of(evidence, start, end)}
                    for start, end in zip(markers, markers[1:])]
        seam_index = round(analysis["seam"] * SAMPLE_RATE)
        splice = np.abs(output_frames[seam_index].astype(float) - output_frames[seam_index - 1]).mean()
        expected = analysis["direction"]
        direction_status = "consistent" if expected in ("left", "right") and all(row["direction"] == expected for row in segments) else "needs-review"
        if any(row["direction"] in ("left", "right") and row["direction"] != expected for row in segments) and expected in ("left", "right"):
            direction_status = "possible-reversal"
        pending.replace(output)
    except (OSError, subprocess.SubprocessError):
        raise WorkerError("composition_failed") from None
    finally:
        pending.unlink(missing_ok=True)
    return {
        "anchors": anchors, "anchorEvidence": "operator" if "generatedAnchors" in override else "guide-estimate",
        "originalAudioCopied": soundtrack, "originalAudioHash": audio_hash, "decoded": True,
        "directionCheck": direction_status, "motionSegments": segments, "splicePixelChange": round(float(splice), 2),
    }


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()
