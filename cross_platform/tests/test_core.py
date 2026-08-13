from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT))

from netvista.ffmpeg_engine import ExportOptions, ExportProcess, build_command, ffmpeg_executable, probe_media
from netvista.model import Project


class PortableCoreTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
