"""Verify the paid submission boundary and source beat analysis without API calls."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from .media import Media, beat_peaks, direction_of, frame_anchors
from .providers import CloudProviders, Journal, WorkerError, exclusive_job


class ProviderTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.inputs = {"theme": "shanghai"}
        self.journal = Journal(self.root / "provider-state.json", self.inputs)
        self.provider = CloudProviders("fake-ark", "fake-kling", self.journal, 0)
        self.ref = self.root / "input.jpg"
        self.ref.write_bytes(b"placeholder")
        self.raw = self.root / "generated.mp4"

    def run_video(self, provider=None):
        return (provider or self.provider).video("test", self.ref, self.ref, self.ref,
                                                  "https://example.com/motion.mp4", self.raw)

    def test_timeout_resumes_the_same_task_id(self):
        task = "task-1234"
        replies = [
            {"code": 0, "data": {"id": task}},
            {"code": 0, "data": [{"id": task, "status": "processing"}]},
            {"code": 0, "tokenhub_usage": {"total_tokens": 1450000},
             "data": [{"id": task, "status": "succeeded",
                       "outputs": [{"type": "video", "url": "https://example.com/output.mp4"}]}]},
        ]

        def create_download(url, output, limit):
            output.write_bytes(b"mock-video")

        with patch("worker.providers.api_request", side_effect=replies) as request, \
                patch("worker.providers.download", side_effect=create_download):
            with self.assertRaisesRegex(WorkerError, "video_waiting_for_provider") as timeout:
                self.run_video()
            self.assertTrue(timeout.exception.retryable)
            journal = Journal(self.journal.path, self.inputs)
            self.assertEqual(journal.state["video"]["taskId"], task)
            self.run_video(CloudProviders(None, "fake-kling", journal, 0))
            self.assertEqual(sum(call.args[0].endswith("/omni-video") for call in request.call_args_list), 1)
            self.assertEqual(journal.state["video"]["tokens"], 1450000)
            self.assertEqual(self.raw.read_bytes(), b"mock-video")

    def test_unknown_submission_stays_reserved(self):
        with patch("worker.providers.api_request", side_effect=WorkerError("provider_unavailable", retryable=True)) as request:
            with self.assertRaisesRegex(WorkerError, "provider_unavailable") as first:
                self.run_video()
            self.assertFalse(first.exception.retryable)
            with self.assertRaisesRegex(WorkerError, "video_submission_uncertain"):
                self.run_video()
            self.assertEqual(request.call_count, 1)

    def test_worker_lock_prevents_same_directory_concurrency(self):
        lock = self.root / "worker.lock"
        with exclusive_job(lock):
            with self.assertRaisesRegex(WorkerError, "worker_job_already_running"):
                with exclusive_job(lock):
                    self.fail("second worker acquired the same job lock")
        with exclusive_job(lock):
            self.assertTrue(lock.exists())


class TimingTests(unittest.TestCase):
    def test_drum_onset_is_found_in_the_original_audio_timeline(self):
        sample_rate = 16000
        signal = np.zeros(sample_rate * 5, dtype=np.float32)
        time = np.arange(sample_rate // 7) / sample_rate
        sound = .75 * np.sin(2 * np.pi * 100 * time) * np.exp(-time * 30)
        for beat in (1.1, 3.4):
            start = round(beat * sample_rate)
            signal[start:start + len(sound)] = sound
        media = Media(1080, 1920, 30, 5, 0, 0, .13, "h264")
        with patch("worker.media.run", return_value=signal.tobytes()):
            peaks = beat_peaks(Path("test.mp4"), media)
        self.assertTrue(any(abs(peak - 3.53) < .045 for peak, _ in peaks))

    def test_calibrated_scene_and_continuous_source_timeline(self):
        original = Media(1080, 1920, 30, 10.533333, 0, 0, 0, "hevc")
        generated = Media(1080, 1920, 24, 8.041666, 0, 0, 0, "h264")
        timeline = {"seam": 1.967, "front": 3.93, "sceneBeat": 5.65, "ending": 8.65}
        override = {"generatedAnchors": [1.5, 3.6666666667, 6.25]}
        fps, seam, count, mapping, anchors = frame_anchors(timeline, override, original, generated)
        self.assertEqual((fps, seam, count, mapping[0], mapping[-1]), (30, 59, 316, 0, 192))
        self.assertTrue(np.all(np.diff(mapping) >= 0))
        self.assertEqual(anchors[2], (5.65, 3.6666666667))

    def test_direction_reports_conflicting_evidence_as_mixed(self):
        evidence = [(time, 8 if time % 2 else -8) for time in range(8)]
        self.assertEqual(direction_of(evidence, 0, 8), "mixed")
        self.assertEqual(direction_of([(time, -8) for time in range(8)], 0, 8), "left")


if __name__ == "__main__":
    unittest.main()
