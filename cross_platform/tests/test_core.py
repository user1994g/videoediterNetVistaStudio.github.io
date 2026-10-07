from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
import threading
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT))

from netvista.ffmpeg_engine import ExportOptions, ExportProcess, build_command, ffmpeg_executable, probe_media, render_frame
from netvista.model import Project, ProjectHistory, TimelineClip, path_from_url


class PortableCoreTests(unittest.TestCase):
    def test_mac_source_file_url_decodes_spaces(self):
        self.assertTrue(path_from_url("file:///tmp/My%20Film.mov").endswith("My Film.mov"))
        self.assertEqual(path_from_url("/tmp/My Film.mov"), "/tmp/My Film.mov")
    def test_cancel_finishes_only_after_encoder_is_reaped(self):
        script = """import signal,time,sys
def stop(*args):
    print('terminating',flush=True)
    time.sleep(10)
    sys.exit(0)
signal.signal(signal.SIGTERM,stop)
while True:
    print('out_time_us=10',flush=True)
    time.sleep(.02)
"""
        engine = ExportProcess()
        ready = threading.Event()
        errors = []
        def run():
            try:
                engine.run(Project(), ExportOptions("unused.mp4"), lambda *_args: ready.set())
            except Exception as error:
                errors.append(str(error))
        with patch("netvista.ffmpeg_engine.build_command", return_value=[sys.executable, "-u", "-c", script]):
            worker = threading.Thread(target=run)
            worker.start()
            try:
                self.assertTrue(ready.wait(5))
                engine.cancel()
                worker.join(6)
                self.assertFalse(worker.is_alive())
                self.assertIsNotNone(engine.process.poll())
                self.assertTrue(engine.process.stdout.closed)
                self.assertEqual(errors, ["Export cancelled."])
            finally:
                if engine.process and engine.process.poll() is None:
                    engine.process.kill()
                    engine.process.wait()
                worker.join(5)

    def test_malformed_motion_is_safe_or_rejected(self):
        clip = TimelineClip.from_dict({"transform": {"scale": "NaN", "opacity": None}, "track": "Inf"})
        self.assertEqual(clip.transform["scale"], 1)
        self.assertEqual(clip.transform["opacity"], 1)
        self.assertEqual(clip.track, 0)
        with self.assertRaises(ValueError):
            TimelineClip.from_dict({"transform": [1, 2]})
    def test_project_round_trip_preserves_unknown_data(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "work.netvistastudio"
            path.write_text(json.dumps({"schemaVersion": 5, "title": "Work", "media": [], "timeline": [],
                                        "scenes": [], "futureSetting": {"keep": True}}))
            project = Project.load(path)
            project.title = "New Work"
            project.save()
            data = json.loads(path.read_text())
            self.assertEqual(data["title"], "New Work")
            self.assertEqual(data["futureSetting"], {"keep": True})

    def test_16k_and_custom_resolution_validation(self) -> None:
        options = ExportOptions("movie.mp4", 20000, 9001, codec="Automatic").validated()
        self.assertEqual((options.width, options.height), (15360, 8640))
        self.assertEqual(options.codec, "HEVC (H.265)")
        odd = ExportOptions("movie.mp4", 1919, 1079).validated()
        self.assertEqual((odd.width, odd.height), (1918, 1078))

    def test_side_by_side_timeline_builds_ffmpeg_graph(self) -> None:
        project = Project()
        one = project.add_asset("/tmp/one.mp4", "video", 4, False)
        two = project.add_asset("/tmp/two.mp4", "video", 3, False)
        project.add_to_timeline(one)
        project.add_to_timeline(two)
        command = build_command(project, ExportOptions("/tmp/out.mp4", 1920, 1080))
        graph = command[command.index("-filter_complex") + 1]
        self.assertIn("overlay", graph)
        self.assertIn("setpts=PTS+4.000000/TB", graph)

    def test_linked_split_keeps_two_independent_audio_video_pairs(self) -> None:
        project = Project()
        source = project.add_asset("/tmp/film.mp4", "video", 6, True)
        ids = project.add_to_timeline(source)
        right_ids = project.split_at(2, [ids[0]])
        self.assertEqual(len(right_ids), 2)
        left = [project.clip(value) for value in ids]
        right = [project.clip(value) for value in right_ids]
        self.assertEqual({clip.group_id for clip in left}, {left[0].group_id})
        self.assertEqual({clip.group_id for clip in right}, {right[0].group_id})
        self.assertNotEqual(left[0].group_id, right[0].group_id)
        project.move_clip(right_ids[0], 8, 1)
        self.assertEqual([clip.timeline_start for clip in right], [8, 8])
        self.assertEqual([clip.timeline_start for clip in left], [0, 0])
        self.assertEqual([project.clip_duration(clip) for clip in left + right], [2, 2, 4, 4])

    def test_unlinked_split_duplicate_and_bounded_history(self) -> None:
        project = Project()
        source = project.add_asset("/tmp/film.mp4", "video", 6, True)
        ids = project.add_to_timeline(source)
        self.assertEqual(len(project.split_at(2, [ids[0]], linked=False)), 1)
        self.assertEqual(project.clip(ids[1]).out_point, 6)
        history = ProjectHistory(2)
        for value in [1, 2, 3]:
            history.remember(project)
            project.title = str(value)
        self.assertEqual(len(history.undo_stack), 2)
        project = history.undo(project)
        self.assertEqual(project.title, "2")
        project = history.redo(project)
        self.assertEqual(project.title, "3")
        clone = project.duplicate_clip(ids[0], linked=False)
        self.assertEqual(len(clone), 1)
        self.assertEqual(project.clip(clone[0]).timeline_start, 2)

    def test_motion_filter_supports_zoom_rotation_zero_opacity_and_effects(self) -> None:
        project = Project()
        source = project.add_asset("/tmp/film.mp4", "video", 1, False)
        clip = project.clip(project.add_to_timeline(source)[0])
        clip.transform.update(scale=2, opacity=0, rotation=90, positionX=0.5, positionY=0.5)
        clip.effects.update(blurRadius=2, sharpenAmount=1)
        command = build_command(project, ExportOptions("/tmp/out.mp4", 320, 180))
        graph = command[command.index("-filter_complex") + 1]
        self.assertIn("scale=640:360", graph)
        self.assertIn("colorchannelmixer=aa=0.0000", graph)
        self.assertIn("rotate=-1.570796", graph)
        self.assertIn("gblur=sigma=2.0000", graph)
        self.assertIn("unsharp=5:5:1.0000", graph)
        self.assertIn("x=(W-w)/2+80.0000:y=(H-h)/2+-45.0000", graph)

    def test_real_ffmpeg_smoke_export(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            first = str(Path(folder) / "red.mp4")
            second = str(Path(folder) / "blue.mp4")
            output = str(Path(folder) / "joined.mp4")
            ffmpeg = ffmpeg_executable()
            for path, colour in [(first, "red"), (second, "blue")]:
                subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                                "-i", f"color={colour}:s=160x90:d=0.4:r=10", "-c:v", "libx264", path], check=True)
            project = Project()
            for path in [first, second]:
                info = probe_media(path)
                asset = project.add_asset(path, "video", info.duration, False)
                project.add_to_timeline(asset)
            ExportProcess().run(project, ExportOptions(output, 320, 180, 10, "H.264", "mp4", 32,
                                                       include_audio=False, preset="ultrafast"))
            self.assertGreater(Path(output).stat().st_size, 500)
            def pixel(seconds, x=160, y=90):
                raw = subprocess.check_output([ffmpeg, "-hide_banner", "-loglevel", "error", "-ss", str(seconds),
                                               "-i", output, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
                offset = (y * 320 + x) * 3
                return tuple(raw[offset:offset + 3])
            red, blue = pixel(0.1), pixel(0.6)
            self.assertGreater(red[0], red[2] + 120)
            self.assertGreater(blue[2], blue[0] + 120)
            project.timeline[0].transform.update(scale=0.5)
            project.timeline[1].transform.update(opacity=0)
            ExportProcess().run(project, ExportOptions(output, 320, 180, 10, "H.264", "mp4", 32,
                                                       include_audio=False, preset="ultrafast"))
            self.assertLess(max(pixel(0.1, 20, 20)), 12)
            self.assertGreater(pixel(0.1)[0], 180)
            self.assertLess(max(pixel(0.6)), 12)
            frame = str(Path(folder) / "frame.png")
            render_frame(project, 0.1, frame)
            frame_raw = subprocess.check_output([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", frame,
                                                "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
            self.assertGreater(frame_raw[(180 * 640 + 320) * 3], 180)
            render_frame(project, 0.6, frame)
            frame_raw = subprocess.check_output([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", frame,
                                                "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
            self.assertLess(max(frame_raw), 12)


if __name__ == "__main__":
    unittest.main()
