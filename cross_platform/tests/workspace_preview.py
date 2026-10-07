"""Render native desktop layout references without touching real projects/login."""
import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PySide6.QtWidgets import QApplication
from netvista.main_window import MainWindow


def main():
    destination = Path(sys.argv[1])
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="netvista-ui-check-") as storage:
        os.environ["XDG_DATA_HOME"] = storage
        app = QApplication([])
        window = MainWindow()
        for name, duration in [("Coast.mov", 12), ("Flower.mov", 8)]:
            source = window.project.add_asset(Path(storage) / name, "video", duration, True)
            window.project.add_to_timeline(source)
        window.refresh_everything()
        window.preview_timer.stop()
        window.select_clip(window.project.timeline[0].id)
        window.show_page("Edit")
        window.show()
        for width, height in [(1500, 930), (960, 640)]:
            window.resize(width, height)
            app.processEvents()
            window.grab().save(str(destination / f"desktop-{width}x{height}.png"))
        window.show_home()
        app.processEvents()
        window.grab().save(str(destination / "desktop-home.png"))
        window.project_dirty = False
        window.close()
    print(destination)


if __name__ == "__main__":
    main()
