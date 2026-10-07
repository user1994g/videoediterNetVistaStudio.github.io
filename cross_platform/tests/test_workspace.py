"""Native widget checks; no account login, network or user media involved."""
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    from PySide6.QtCore import QPoint, Qt
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QApplication
    from netvista.main_window import MainWindow
    from netvista.mods import ModManager
except ImportError:
    QApplication = None


@unittest.skipIf(QApplication is None, "Qt dependencies not installed")
class NativeWorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])
        cls.app.setStyle("Fusion")

    def setUp(self):
        self.mod_folder = tempfile.TemporaryDirectory(prefix="netvista-widget-test-")
        self.mod_patch = patch("netvista.main_window.ModManager", side_effect=lambda version: ModManager(version, self.mod_folder.name))
        self.mod_patch.start()
        self.window = MainWindow()
        self.window.show()
        self.app.processEvents()
        self.window.preview_timer.stop()

    def tearDown(self):
        self.window.preview_timer.stop()
        self.window.project_dirty = False
        self.window.close()
        self.app.processEvents()
        self.mod_patch.stop()
        self.mod_folder.cleanup()

    def test_home_and_all_workspaces_fit_small_desktop(self):
        self.assertEqual(self.window.root_stack.currentIndex(), 0)
        self.window.resize(960, 640)
        for page in self.window.pages:
            self.window.show_page(page)
            self.app.processEvents()
            self.assertEqual(self.window.root_stack.currentWidget(), self.window.editor_root)
            self.assertLessEqual(self.window.minimumSizeHint().width(), 960)
            self.assertGreater(self.window.video_widget.width(), 200)
            if page == "Edit":
                numeric = self.window.opacity_slider.readout
                self.assertLessEqual(numeric.mapTo(self.window, QPoint(numeric.width(), 0)).x(), self.window.width())
        self.window.show_home()
        self.assertEqual(self.window.root_stack.currentIndex(), 0)

    def test_property_values_selection_and_undo(self):
        self.window.show_editor()
        self.assertFalse(self.window.opacity_slider.isEnabled())
        source = self.window.project.add_asset("/tmp/not-a-real-clip.mp4", "video", 6, True)
        ids = self.window.project.add_to_timeline(source)
        self.window.project.clip(ids[0]).transform.update(scale=1.23456, rotation=3.7)
        self.window.project.clip(ids[0]).effects.update(blurRadius=20, sharpenAmount=4)
        self.window.project.clip(ids[0]).brightness = 1e308
        self.window.timeline.set_project(self.window.project)
        self.window.select_clip(ids[0])
        self.window.opacity_slider.setValue(0)
        self.window.preview_timer.stop()
        self.assertEqual(self.window.project.clip(ids[0]).transform["opacity"], 0)
        self.assertEqual(self.window.opacity_slider.readout.value(), 0)
        self.assertEqual(self.window.project.clip(ids[0]).transform["scale"], 1.23456)
        self.assertEqual(self.window.project.clip(ids[0]).transform["rotation"], 3.7)
        self.assertEqual(self.window.project.clip(ids[0]).effects["blurRadius"], 20)
        self.assertEqual(self.window.project.clip(ids[0]).effects["sharpenAmount"], 4)
        self.assertEqual(self.window.project.clip(ids[0]).brightness, 1e308)
        self.window.undo()
        self.window.preview_timer.stop()
        self.assertEqual(self.window.project.clip(ids[0]).transform.get("opacity", 1), 1)
        self.window.redo()
        self.window.preview_timer.stop()
        self.assertEqual(self.window.project.clip(ids[0]).transform["opacity"], 0)

    def test_still_frame_transport_and_return_from_source_mode(self):
        window = self.window
        source = window.project.add_asset("/tmp/not-a-real-clip.mp4", "video", 6, False)
        window.project.add_to_timeline(source)
        window.timeline.set_project(window.project)
        window.program_mode = True
        window.step_transport(1)
        self.assertEqual(window.timeline.playhead, 1)
        self.assertEqual(window.time_label.text(), "00:00:01:00")
        window.frame_timer.stop()
        window.stop_playback()
        self.assertEqual(window.timeline.playhead, 0)
        self.assertTrue(window.frame_timer.isActive())
        window.frame_timer.stop()
        # Native source preview must be visible when a paused still is resumed.
        window.program_mode = False
        window.viewer_stack.setCurrentWidget(window.frame_view)
        window.toggle_playback()
        self.assertEqual(window.viewer_stack.currentWidget(), window.video_widget)

    def test_timeline_drag_and_scrub_have_one_history_entry(self):
        window = self.window
        window.show_editor()
        source = window.project.add_asset("/tmp/not-a-real-clip.mp4", "video", 6, True)
        ids = window.project.add_to_timeline(source)
        window.timeline.set_project(window.project)
        clip = window.project.clip(ids[0])
        start = window.timeline.clip_rect(clip).center().toPoint()
        QTest.mousePress(window.timeline, Qt.MouseButton.LeftButton, pos=start)
        QTest.mouseMove(window.timeline, start + QPoint(120, 0))
        QTest.mouseRelease(window.timeline, Qt.MouseButton.LeftButton, pos=start + QPoint(120, 0))
        window.preview_timer.stop()
        self.assertGreater(window.project.clip(ids[0]).timeline_start, 1)
        self.assertEqual(len(window.history.undo_stack), 1)
        QTest.mousePress(window.timeline, Qt.MouseButton.LeftButton, pos=QPoint(160, 10))
        QTest.mouseMove(window.timeline, QPoint(220, 10))
        QTest.mouseRelease(window.timeline, Qt.MouseButton.LeftButton, pos=QPoint(220, 10))
        self.assertAlmostEqual(window.timeline.playhead, (220 - window.timeline.header_width) / window.timeline.zoom)

    def test_stale_preview_never_replaces_new_edit(self):
        window = self.window
        window.preview_revision = 9
        stale = Path(window.preview_folder.name) / "preview-8.mp4"
        stale.touch()
        window.preview_ready(str(stale), 8)
        window.preview_timer.stop()
        self.assertFalse(stale.exists())
        self.assertIsNone(window.preview_path)


if __name__ == "__main__":
    unittest.main()
