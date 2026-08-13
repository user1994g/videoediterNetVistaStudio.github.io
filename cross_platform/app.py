from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtCore import QCoreApplication, QTimer, Qt
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication

from netvista import __version__
from netvista.main_window import MainWindow


def resource_path(name: str) -> Path:
    """Return a development or PyInstaller-bundled asset path."""
    bundle_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    return bundle_root / "assets" / name


def main() -> int:
    QCoreApplication.setOrganizationName("NetVista Studio")
    QCoreApplication.setApplicationName("NetVista Studio")
    QCoreApplication.setApplicationVersion(__version__)
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setWindowIcon(QIcon(str(resource_path("NetVistaStudio.png"))))
    window = MainWindow()
    window.show()
    if "--smoke-test" in sys.argv:
        # Packaging jobs use this to prove the frozen executable can construct
        # the complete UI and enter its event loop on the target OS.
        window.show_page("Export")
        window.resolution_combo.setCurrentText("16K Ultra HD")
        if (window.width_spin.value(), window.height_spin.value()) != (15360, 8640):
            return 2
        QTimer.singleShot(250, app.quit)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
