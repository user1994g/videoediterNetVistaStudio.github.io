from __future__ import annotations

import tempfile
import platform
from copy import deepcopy
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QThread, QTimer, QUrl, Qt, Signal
from PySide6.QtGui import QAction, QCloseEvent, QDesktopServices, QDragEnterEvent, QDropEvent, QKeySequence
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (QCheckBox, QComboBox, QFileDialog, QFormLayout, QFrame, QGroupBox,
                               QApplication, QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
                               QMessageBox, QProgressBar, QPushButton, QScrollArea, QSlider, QSpinBox,
                               QSplitter, QStackedWidget, QVBoxLayout, QWidget)

from .ffmpeg_engine import (RESOLUTION_PRESETS, ExportOptions, ExportProcess, FFmpegError,
                            probe_media, render_preview)
from .model import MediaAsset, Project, TimelineClip
from .mods import ModCatalog, ModError, ModManager, ModPackage
from .theme import build_app_style
from .timeline import TimelineWidget
from .updater import AvailableUpdate, check_for_update, download_update
from . import __version__


class TaskThread(QThread):
    progress = Signal(float, str)
    completed = Signal(object)
    failed = Signal(str)

    def __init__(self, function: Callable, *args) -> None:
        super().__init__()
        self.function = function
        self.args = args
        self.export_process: ExportProcess | None = None

    def run(self) -> None:
        try:
            result = self.function(*self.args, self.progress.emit)
            self.completed.emit(result)
        except Exception as error:
            self.failed.emit(str(error))

    def cancel(self) -> None:
        if self.export_process:
            self.export_process.cancel()


class MainWindow(QMainWindow):
    pages = ["Media", "Cut", "Edit", "Effects", "Color", "Audio", "3D Scene", "Mods", "Export"]

    def __init__(self) -> None:
        super().__init__()
        self.project = Project()
        self.project_dirty = False
        self.preview_path: str | None = None
        self.preview_thread: TaskThread | None = None
        self.export_thread: TaskThread | None = None
        self.update_thread: TaskThread | None = None
        self.current_page = "Media"
        self.selected_clip_id: str | None = None
        self.mod_manager = ModManager(__version__)
        self.mod_catalog = self.mod_manager.scan()
        self.setWindowTitle("NetVista Studio — Windows / Linux Beta")
        self.resize(1500, 930)
        self.setMinimumSize(960, 640)
        self.setAcceptDrops(True)
        self.setStyleSheet(build_app_style(self.mod_manager.active_theme_tokens(self.mod_catalog)))
        self._build_ui()
        self._build_shortcuts()
        self.preview_timer = QTimer(self)
        self.preview_timer.setSingleShot(True)
        self.preview_timer.setInterval(700)
        self.preview_timer.timeout.connect(self.refresh_timeline_preview)
        self.refresh_everything()

    def _build_ui(self) -> None:
        root = QWidget()
        layout = QVBoxLayout(root)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(self._top_bar())

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.addWidget(self._media_panel())
        splitter.addWidget(self._program_panel())
        splitter.addWidget(self._inspector_panel())
        splitter.setSizes([250, 980, 280])
        splitter.setStretchFactor(1, 1)
        layout.addWidget(splitter, 1)

        layout.addWidget(self._timeline_toolbar())
        self.timeline = TimelineWidget()
        self.timeline.selection_changed.connect(self.select_clip)
        self.timeline.clips_changed.connect(self.timeline_changed)
        self.timeline.playhead_changed.connect(self.seek_timeline)
        self.timeline_scroll = QScrollArea()
        self.timeline_scroll.setWidget(self.timeline)
        self.timeline_scroll.setWidgetResizable(False)
        self.timeline_scroll.setMinimumHeight(245)
        layout.addWidget(self.timeline_scroll)
        layout.addWidget(self._page_dock())
        self.status_label = QLabel("Ready")
        self.status_label.setObjectName("status")
        layout.addWidget(self.status_label)
        self.setCentralWidget(root)

    def _top_bar(self) -> QWidget:
        frame = QFrame(objectName="topBar")
        row = QHBoxLayout(frame)
        row.setContentsMargins(14, 8, 14, 8)
        brand = QLabel("NetVista  STUDIO", objectName="brand")
        row.addWidget(brand)
        row.addStretch()
        self.title_edit = QLineEdit("Untitled Project")
        self.title_edit.setMaximumWidth(260)
        self.title_edit.editingFinished.connect(self.title_changed)
        row.addWidget(self.title_edit)
        for title, callback in [("Open", self.open_project), ("Update", self.check_for_updates),
                                ("Save your work", self.save_project)]:
            button = QPushButton(title)
            button.clicked.connect(callback)
            row.addWidget(button)
            if title == "Update":
                self.update_button = button
        return frame

    def _media_panel(self) -> QWidget:
        panel = QWidget()
        column = QVBoxLayout(panel)
        column.setContentsMargins(8, 10, 8, 8)
        heading = QLabel("MEDIA POOL", objectName="panelTitle")
        column.addWidget(heading)
        actions = QHBoxLayout()
        add = QPushButton("Import")
        add.clicked.connect(self.import_media)
        add_all = QPushButton("Add all")
        add_all.clicked.connect(self.add_all_media)
        actions.addWidget(add_all)
        actions.addWidget(add)
        column.addLayout(actions)
        self.media_list = QListWidget()
        self.media_list.itemSelectionChanged.connect(self.media_selected)
        self.media_list.itemDoubleClicked.connect(lambda _item: self.add_selected_media())
        column.addWidget(self.media_list, 1)
        add_timeline = QPushButton("Add selected to timeline", objectName="primary")
        add_timeline.clicked.connect(self.add_selected_media)
        remove = QPushButton("Remove selected media", objectName="danger")
        remove.clicked.connect(self.remove_selected_media)
        column.addWidget(add_timeline)
        column.addWidget(remove)
        return panel

    def _program_panel(self) -> QWidget:
        panel = QWidget()
        column = QVBoxLayout(panel)
        column.setContentsMargins(0, 0, 0, 0)
        self.workspace_title = QLabel("MEDIA WORKSPACE")
        self.workspace_title.setObjectName("panelTitle")
        self.workspace_title.setContentsMargins(12, 8, 8, 8)
        column.addWidget(self.workspace_title)
        self.video_widget = QVideoWidget()
        self.video_widget.setStyleSheet("background: black;")
        self.video_widget.setMinimumHeight(260)
        column.addWidget(self.video_widget, 1)
        self.audio_output = QAudioOutput()
        self.player = QMediaPlayer()
        self.player.setAudioOutput(self.audio_output)
        self.player.setVideoOutput(self.video_widget)
        self.player.positionChanged.connect(self.player_position_changed)
        controls = QHBoxLayout()
        back = QPushButton("‹")
        back.clicked.connect(lambda: self.player.setPosition(max(0, self.player.position() - 1000)))
        self.play_button = QPushButton("Play")
        self.play_button.clicked.connect(self.toggle_playback)
        stop = QPushButton("Stop")
        stop.clicked.connect(self.stop_playback)
        forward = QPushButton("›")
        forward.clicked.connect(lambda: self.player.setPosition(self.player.position() + 1000))
        self.time_label = QLabel("00:00:00:00")
        controls.addStretch()
        for widget in [back, self.play_button, stop, forward, self.time_label]:
            controls.addWidget(widget)
        controls.addStretch()
        column.addLayout(controls)
        return panel

    def _inspector_panel(self) -> QWidget:
        panel = QWidget()
        column = QVBoxLayout(panel)
        column.setContentsMargins(10, 10, 10, 10)
        self.inspector_title = QLabel("INSPECTOR", objectName="panelTitle")
        column.addWidget(self.inspector_title)
        self.inspector_stack = QStackedWidget()
        self.inspector_pages: dict[str, QWidget] = {}
        for page in self.pages:
            widget = self._make_inspector(page)
            self.inspector_pages[page] = widget
            self.inspector_stack.addWidget(widget)
        column.addWidget(self.inspector_stack, 1)
        return panel

    def _timeline_toolbar(self) -> QWidget:
        frame = QFrame(objectName="timelineTools")
        row = QHBoxLayout(frame)
        row.setContentsMargins(10, 5, 10, 5)
        row.addWidget(QLabel("TIMELINE 1", objectName="panelTitle"))
        cut = QPushButton("Cut clip")
        cut.clicked.connect(self.cut_selected)
        delete = QPushButton("Delete")
        delete.clicked.connect(self.delete_selected_clip)
        row.addWidget(cut)
        row.addWidget(delete)
        row.addStretch()
        row.addWidget(QLabel("Zoom"))
        zoom = QSlider(Qt.Orientation.Horizontal)
        zoom.setRange(8, 300)
        zoom.setValue(55)
        zoom.setMaximumWidth(190)
        zoom.valueChanged.connect(lambda value: self.timeline.set_zoom(value))
        row.addWidget(zoom)
        refresh = QPushButton("Refresh preview")
        refresh.clicked.connect(self.refresh_timeline_preview)
        row.addWidget(refresh)
        return frame

    def _page_dock(self) -> QWidget:
        frame = QFrame(objectName="dock")
        row = QHBoxLayout(frame)
        row.setContentsMargins(10, 7, 10, 7)
        row.addStretch()
        self.page_buttons: dict[str, QPushButton] = {}
        for page in self.pages:
            button = QPushButton(page)
            button.setCheckable(True)
            button.clicked.connect(lambda _checked=False, name=page: self.show_page(name))
            self.page_buttons[page] = button
            row.addWidget(button)
        row.addStretch()
        return frame

    def _make_inspector(self, page: str) -> QWidget:
        widget = QWidget()
        column = QVBoxLayout(widget)
        column.setContentsMargins(0, 8, 0, 0)
        if page == "Media":
            column.addWidget(QLabel("Import video and audio, then double-click an item or press Add selected to place it on the timeline."))
        elif page == "Cut":
            column.addWidget(QLabel("Select clips, drag them side by side or between tracks, and cut at the red playhead."))
        elif page == "Edit":
            self.scale_slider = self._slider(column, "Scale", 10, 400, 100, self.clip_controls_changed)
            self.opacity_slider = self._slider(column, "Opacity", 0, 100, 100, self.clip_controls_changed)
        elif page == "Effects":
            self.blur_slider = self._slider(column, "Blur", 0, 100, 0, self.clip_controls_changed)
            self.sharpen_slider = self._slider(column, "Sharpen", 0, 100, 0, self.clip_controls_changed)
            column.addWidget(QLabel("Effect values are saved in the shared project and applied during FFmpeg export."))
        elif page == "Color":
            self.brightness_slider = self._slider(column, "Brightness", -100, 100, 0, self.clip_controls_changed)
            self.contrast_slider = self._slider(column, "Contrast", 0, 300, 100, self.clip_controls_changed)
            self.saturation_slider = self._slider(column, "Saturation", 0, 300, 100, self.clip_controls_changed)
            self.gamma_slider = self._slider(column, "Gamma", 10, 300, 100, self.clip_controls_changed)
        elif page == "Audio":
            self.volume_slider = self._slider(column, "Volume", 0, 200, 100, self.clip_controls_changed)
        elif page == "3D Scene":
            column.addWidget(QLabel("Portable 3D assets\nOBJ, DAE, GLTF and GLB references are saved with the project."))
            self.model_list = QListWidget()
            column.addWidget(self.model_list)
            add_model = QPushButton("Add 3D model")
            add_model.clicked.connect(self.add_3d_model)
            column.addWidget(add_model)
        elif page == "Mods":
            column.addWidget(self._mods_controls())
        elif page == "Export":
            column.addWidget(self._export_controls())
        column.addStretch()
        return widget

    def _mods_controls(self) -> QWidget:
        widget = QWidget()
        column = QVBoxLayout(widget)
        column.setContentsMargins(0, 0, 0, 0)
        intro = QLabel("Install data-only .netvistamod packages. Mods v1 can change approved theme colours but cannot run scripts, commands, or app code.")
        intro.setWordWrap(True)
        column.addWidget(intro)
        drop_hint = QLabel("Drop a .netvistamod file or folder anywhere on this window", objectName="panelTitle")
        drop_hint.setWordWrap(True)
        drop_hint.setFrameShape(QFrame.Shape.StyledPanel)
        drop_hint.setContentsMargins(8, 8, 8, 8)
        column.addWidget(drop_hint)

        self.mod_list = QListWidget()
        self.mod_list.setMinimumHeight(170)
        self.mod_list.itemSelectionChanged.connect(self.mod_selection_changed)
        column.addWidget(self.mod_list, 1)

        self.mod_detail = QLabel("Select an installed mod to see its details.")
        self.mod_detail.setWordWrap(True)
        self.mod_detail.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        column.addWidget(self.mod_detail)

        self.mod_error_label = QLabel("")
        self.mod_error_label.setWordWrap(True)
        self.mod_error_label.setStyleSheet("color: #ff7a84;")
        column.addWidget(self.mod_error_label)

        install_row = QHBoxLayout()
        install = QPushButton("Install package…", objectName="primary")
        install.clicked.connect(self.install_mod_dialog)
        refresh = QPushButton("Refresh")
        refresh.clicked.connect(lambda: self.refresh_mods(announce=True))
        install_row.addWidget(install)
        install_row.addWidget(refresh)
        column.addLayout(install_row)

        action_row = QHBoxLayout()
        self.mod_toggle_button = QPushButton("Enable")
        self.mod_toggle_button.clicked.connect(self.toggle_selected_mod)
        self.mod_remove_button = QPushButton("Remove", objectName="danger")
        self.mod_remove_button.clicked.connect(self.remove_selected_mod)
        action_row.addWidget(self.mod_toggle_button)
        action_row.addWidget(self.mod_remove_button)
        column.addLayout(action_row)

        open_folder = QPushButton("Open Mods Folder")
        open_folder.clicked.connect(self.open_mods_folder)
        column.addWidget(open_folder)
        self._populate_mod_list()
        return widget

    def _slider(self, parent: QVBoxLayout, label: str, minimum: int, maximum: int, value: int,
                callback: Callable) -> QSlider:
        group = QGroupBox(label)
        row = QVBoxLayout(group)
        slider = QSlider(Qt.Orientation.Horizontal)
        slider.setRange(minimum, maximum)
        slider.setValue(value)
        slider.valueChanged.connect(callback)
        row.addWidget(slider)
        parent.addWidget(group)
        return slider

    def _export_controls(self) -> QWidget:
        widget = QWidget()
        form = QFormLayout(widget)
        self.resolution_combo = QComboBox()
        self.resolution_combo.addItems(list(RESOLUTION_PRESETS) + ["Custom"])
        self.resolution_combo.setCurrentText("1080p HD")
        self.resolution_combo.currentTextChanged.connect(self.resolution_changed)
        self.width_spin = QSpinBox(); self.width_spin.setRange(64, 15360); self.width_spin.setValue(1920)
        self.height_spin = QSpinBox(); self.height_spin.setRange(64, 8640); self.height_spin.setValue(1080)
        self.fps_combo = QComboBox(); self.fps_combo.addItems(["24", "25", "30", "50", "60", "120"]); self.fps_combo.setCurrentText("30")
        self.codec_combo = QComboBox(); self.codec_combo.addItems(["Automatic", "H.264", "HEVC (H.265)", "AV1", "ProRes 422 HQ"])
        self.container_combo = QComboBox(); self.container_combo.addItems(["mp4", "mov", "mkv"])
        self.audio_check = QCheckBox("Include timeline audio"); self.audio_check.setChecked(True)
        for title, control in [("Resolution", self.resolution_combo), ("Width", self.width_spin),
                               ("Height", self.height_spin), ("Frame rate", self.fps_combo),
                               ("Video codec", self.codec_combo), ("Container", self.container_combo)]:
            form.addRow(title, control)
        form.addRow(self.audio_check)
        self.export_progress = QProgressBar(); self.export_progress.setRange(0, 100)
        form.addRow(self.export_progress)
        self.export_button = QPushButton("Choose file and export", objectName="primary")
        self.export_button.clicked.connect(self.start_export)
        self.cancel_export_button = QPushButton("Cancel export", objectName="danger")
        self.cancel_export_button.clicked.connect(self.cancel_export)
        self.cancel_export_button.setEnabled(False)
        form.addRow(self.export_button)
        form.addRow(self.cancel_export_button)
        return widget

    def _build_shortcuts(self) -> None:
        for text, shortcut, callback in [("Open", QKeySequence.StandardKey.Open, self.open_project),
                                         ("Save", QKeySequence.StandardKey.Save, self.save_project),
                                         ("Import", "Ctrl+I", self.import_media),
                                         ("Play", Qt.Key.Key_Space, self.toggle_playback)]:
            action = QAction(text, self)
            action.setShortcut(shortcut)
            action.triggered.connect(callback)
            self.addAction(action)

    def status(self, message: str) -> None:
        self.status_label.setText(message)

    def mark_dirty(self) -> None:
        self.project_dirty = True
        self.setWindowTitle(f"NetVista Studio — {self.project.title} *")

    def _populate_mod_list(self, selected_id: str | None = None) -> None:
        if not hasattr(self, "mod_list"):
            return
        selected_id = selected_id or self.selected_mod_id()
        self.mod_list.blockSignals(True)
        self.mod_list.clear()
        selected_row = -1
        for row, package in enumerate(self.mod_catalog.packages):
            state = "ON" if self.mod_manager.is_enabled(package.identifier) else "OFF"
            warning = " · incompatible" if not package.compatible else ""
            item = QListWidgetItem(f"{state}  {package.name}\n     {package.version}{warning}")
            item.setData(Qt.ItemDataRole.UserRole, package.identifier)
            item.setToolTip(f"{package.identifier}\n{package.compatibility_message}")
            self.mod_list.addItem(item)
            if package.identifier == selected_id:
                selected_row = row
        self.mod_list.blockSignals(False)
        if selected_row >= 0:
            self.mod_list.setCurrentRow(selected_row)
        elif self.mod_list.count():
            self.mod_list.setCurrentRow(0)
        else:
            self.mod_selection_changed()
        if self.mod_catalog.errors:
            shown = self.mod_catalog.errors[:3]
            extra = len(self.mod_catalog.errors) - len(shown)
            suffix = f"\n…and {extra} more" if extra else ""
            self.mod_error_label.setText("Package errors:\n" + "\n".join(shown) + suffix)
        else:
            self.mod_error_label.setText("")

    def selected_mod_id(self) -> str | None:
        if not hasattr(self, "mod_list"):
            return None
        items = self.mod_list.selectedItems()
        return str(items[0].data(Qt.ItemDataRole.UserRole)) if items else None

    def selected_mod(self) -> ModPackage | None:
        identifier = self.selected_mod_id()
        return self.mod_catalog.package(identifier) if identifier else None

    def mod_selection_changed(self) -> None:
        if not hasattr(self, "mod_detail"):
            return
        package = self.selected_mod()
        if package is None:
            self.mod_detail.setText("No mods installed. Install a package or copy one into the Mods folder, then press Refresh.")
            self.mod_toggle_button.setEnabled(False)
            self.mod_remove_button.setEnabled(False)
            return
        enabled = self.mod_manager.is_enabled(package.identifier)
        state = "Enabled" if enabled else "Disabled"
        author = f" by {package.author}" if package.author else ""
        capabilities = ", ".join(package.capabilities) or "metadata only"
        description = f"\n\n{package.description}" if package.description else ""
        content = ""
        if package.content_items:
            entries = [f"{item.kind}: {item.name}" for item in package.content_items[:8]]
            if len(package.content_items) > len(entries):
                entries.append(f"…and {len(package.content_items) - len(entries)} more")
            content = "\nContent:\n" + "\n".join(entries)
        self.mod_detail.setText(
            f"{state} · {package.name} {package.version}{author}\n"
            f"ID: {package.identifier}\nCapabilities: {capabilities}\n"
            f"{package.compatibility_message}{description}{content}"
        )
        self.mod_toggle_button.setText("Disable" if enabled else "Enable")
        self.mod_toggle_button.setEnabled(enabled or package.compatible)
        self.mod_remove_button.setEnabled(True)

    def refresh_mods(self, selected_id: str | None = None, announce: bool = False) -> None:
        self.mod_catalog = self.mod_manager.scan()
        self._populate_mod_list(selected_id)
        self.apply_mod_theme()
        if announce:
            self.status(f"Mods refreshed · {len(self.mod_catalog.packages)} valid package(s).")

    def install_mod_dialog(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(
            self,
            "Install NetVista Studio Mod",
            str(Path.home() / "Downloads"),
            "NetVista Studio Mod (*.netvistamod);;All files (*)",
        )
        if paths:
            self.install_mod_paths(paths)

    def install_mod_paths(self, paths: list[str]) -> None:
        installed: list[ModPackage] = []
        errors: list[str] = []
        for path in paths:
            try:
                installed.append(self.mod_manager.install(path))
            except Exception as error:
                errors.append(f"{Path(path).name}: {error}")
        selected = installed[-1].identifier if installed else None
        self.refresh_mods(selected)
        if installed:
            names = ", ".join(package.name for package in installed)
            self.status(f"Installed {names}. New mods stay disabled until you switch them on.")
        if errors:
            QMessageBox.warning(
                self,
                "Some mods could not be installed",
                "NetVista Studio rejected unsafe, invalid, or incompatible package data.\n\n" + "\n".join(errors),
            )

    def toggle_selected_mod(self) -> None:
        package = self.selected_mod()
        if package is None:
            return
        enabled = not self.mod_manager.is_enabled(package.identifier)
        try:
            self.mod_manager.set_enabled(package.identifier, enabled)
            self.refresh_mods(package.identifier)
            self.status(f"{package.name} is now {'enabled' if enabled else 'disabled'}.")
        except ModError as error:
            QMessageBox.warning(self, "Could not change mod", str(error))

    def remove_selected_mod(self) -> None:
        package = self.selected_mod()
        if package is None:
            return
        answer = QMessageBox.question(
            self,
            "Remove mod?",
            f"Remove {package.name} from this computer?\n\nThis deletes its package from the per-user Mods folder.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.Cancel,
            QMessageBox.StandardButton.Cancel,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        try:
            self.mod_manager.remove(package.identifier)
            self.refresh_mods()
            self.status(f"Removed {package.name}.")
        except ModError as error:
            QMessageBox.warning(self, "Could not remove mod", str(error))

    def open_mods_folder(self) -> None:
        self.mod_manager.root.mkdir(parents=True, exist_ok=True)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(self.mod_manager.root)))
        self.status(f"Opened Mods folder: {self.mod_manager.root}")

    def apply_mod_theme(self) -> None:
        stylesheet = build_app_style(self.mod_manager.active_theme_tokens(self.mod_catalog))
        app = QApplication.instance()
        if app is not None:
            app.setStyleSheet(stylesheet)
        self.setStyleSheet(stylesheet)

    def check_for_updates(self) -> None:
        if self.update_thread and self.update_thread.isRunning():
            return
        self.update_button.setEnabled(False)
        self.status("Checking GitHub for a NetVista Studio update…")
        self.update_thread = TaskThread(check_for_update, __version__, platform.system())
        self.update_thread.progress.connect(lambda _value, text: self.status(text))
        self.update_thread.completed.connect(self.update_check_finished)
        self.update_thread.failed.connect(self.update_failed)
        self.update_thread.start()

    def update_check_finished(self, update: AvailableUpdate | None) -> None:
        self.update_button.setEnabled(True)
        if update is None:
            self.status(f"NetVista Studio {__version__} is up to date.")
            QMessageBox.information(self, "You have the newest beta",
                                    f"NetVista Studio {__version__} is the newest version currently published on GitHub.")
            return
        self.status(f"NetVista Studio {update.tag} is available.")
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Icon.Information)
        box.setWindowTitle("NetVista Studio update")
        box.setText("A newer NetVista Studio beta is available")
        box.setInformativeText(f"Installed: {__version__}\nAvailable: {update.tag}\n\n"
                               "Save your project before installing. The verified package will be downloaded to Downloads; "
                               "you choose when to quit and replace the current app.")
        download_button = box.addButton("Download update", QMessageBox.ButtonRole.AcceptRole)
        notes_button = box.addButton("View release notes", QMessageBox.ButtonRole.ActionRole)
        box.addButton("Later", QMessageBox.ButtonRole.RejectRole)
        box.exec()
        if box.clickedButton() is download_button:
            # Let the completed check thread finish before replacing the
            # retained worker with the package-download worker.
            QTimer.singleShot(0, lambda: self.begin_update_download(update))
        elif box.clickedButton() is notes_button and update.page_url:
            QDesktopServices.openUrl(QUrl(update.page_url))

    def begin_update_download(self, update: AvailableUpdate) -> None:
        self.update_button.setEnabled(False)
        self.status(f"Downloading {update.asset.name} to Downloads…")
        self.update_thread = TaskThread(download_update, update)
        self.update_thread.progress.connect(
            lambda value, text: self.status(f"{text} · {int(value * 100)}%"))
        self.update_thread.completed.connect(self.update_download_finished)
        self.update_thread.failed.connect(self.update_failed)
        self.update_thread.start()

    def update_download_finished(self, path: str) -> None:
        self.update_button.setEnabled(True)
        package = Path(path)
        self.status(f"Update downloaded and verified: {package.name}")
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(package.parent)))
        QMessageBox.information(self, "Update ready in Downloads",
                                f"{package.name} passed its size and SHA-256 safety checks.\n\n"
                                "Save your work, quit NetVista Studio, unpack the download, and replace the old app.")

    def update_failed(self, message: str) -> None:
        self.update_button.setEnabled(True)
        self.status(f"Update failed: {message}")
        QMessageBox.warning(self, "Could not update NetVista Studio",
                            f"Check your internet connection and press Update again.\n\n{message}")

    def title_changed(self) -> None:
        self.project.title = self.title_edit.text().strip() or "Untitled Project"
        self.mark_dirty()

    def show_page(self, page: str) -> None:
        self.current_page = page
        self.workspace_title.setText(f"{page.upper()} WORKSPACE")
        self.inspector_title.setText(f"{page.upper()} INSPECTOR")
        self.inspector_stack.setCurrentWidget(self.inspector_pages[page])
        for name, button in self.page_buttons.items():
            button.setChecked(name == page)
        if page == "Mods":
            self.refresh_mods()

    def refresh_everything(self) -> None:
        self.title_edit.setText(self.project.title)
        self.media_list.clear()
        for asset in self.project.media:
            prefix = "♫" if asset.kind == "audio" else "▶"
            item = QListWidgetItem(f"{prefix}  {asset.name}\n     {asset.duration:.1f}s")
            item.setData(Qt.ItemDataRole.UserRole, asset.id)
            self.media_list.addItem(item)
        self.timeline.set_project(self.project)
        self.refresh_3d_models()
        self.show_page(self.current_page)

    def import_media(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(self, "Import media", "",
                                                "Media (*.mp4 *.mov *.mkv *.avi *.webm *.m4v *.mp3 *.wav *.aac *.flac *.ogg);;All files (*)")
        self._import_paths(paths)

    def _import_paths(self, paths: list[str]) -> None:
        for path in paths:
            try:
                info = probe_media(path)
                if not info.has_video and not info.has_audio:
                    continue
                self.project.add_asset(path, "video" if info.has_video else "audio", info.duration, info.has_audio)
            except Exception as error:
                QMessageBox.warning(self, "Could not import", f"{Path(path).name}\n\n{error}")
        if paths:
            self.mark_dirty(); self.refresh_everything(); self.status(f"Imported {len(paths)} media file(s).")

    def selected_asset(self) -> MediaAsset | None:
        items = self.media_list.selectedItems()
        return self.project.asset(items[0].data(Qt.ItemDataRole.UserRole)) if items else None

    def media_selected(self) -> None:
        asset = self.selected_asset()
        if asset:
            self.player.setSource(QUrl.fromLocalFile(asset.url))
            self.status(f"Selected {asset.name}")

    def add_selected_media(self) -> None:
        asset = self.selected_asset()
        if not asset:
            self.status("Select media first."); return
        created = self.project.add_to_timeline(asset)
        self.selected_clip_id = created[0]
        self.timeline.selected_id = created[0]
        self.timeline_changed()

    def add_all_media(self) -> None:
        for asset in self.project.media:
            self.project.add_to_timeline(asset)
        self.timeline_changed()

    def remove_selected_media(self) -> None:
        asset = self.selected_asset()
        if not asset:
            return
        self.project.delete_clips([c.id for c in self.project.timeline if c.asset_id == asset.id], linked=False)
        self.project.media = [item for item in self.project.media if item.id != asset.id]
        self.mark_dirty(); self.refresh_everything()

    def select_clip(self, clip_id: str) -> None:
        self.selected_clip_id = clip_id
        self.load_clip_controls()

    def load_clip_controls(self) -> None:
        clip = self.project.clip(self.selected_clip_id)
        if not clip:
            return
        values = [(getattr(self, "scale_slider", None), int(float(clip.transform.get("scale", 1)) * 100)),
                  (getattr(self, "opacity_slider", None), int(float(clip.transform.get("opacity", 1)) * 100)),
                  (getattr(self, "blur_slider", None), int(float(clip.effects.get("blurRadius", 0)) * 10)),
                  (getattr(self, "sharpen_slider", None), int(float(clip.effects.get("sharpenAmount", 0)) * 100)),
                  (getattr(self, "brightness_slider", None), int(clip.brightness * 100)),
                  (getattr(self, "contrast_slider", None), int(clip.contrast * 100)),
                  (getattr(self, "saturation_slider", None), int(clip.saturation * 100)),
                  (getattr(self, "gamma_slider", None), int(clip.gamma * 100)),
                  (getattr(self, "volume_slider", None), int(clip.volume * 100))]
        for slider, value in values:
            if slider:
                slider.blockSignals(True); slider.setValue(value); slider.blockSignals(False)

    def clip_controls_changed(self, _value: int) -> None:
        clip = self.project.clip(self.selected_clip_id)
        if not clip:
            return
        clip.transform["scale"] = self.scale_slider.value() / 100
        clip.transform["opacity"] = self.opacity_slider.value() / 100
        clip.effects["blurRadius"] = self.blur_slider.value() / 10
        clip.effects["sharpenAmount"] = self.sharpen_slider.value() / 100
        clip.brightness = self.brightness_slider.value() / 100
        clip.contrast = self.contrast_slider.value() / 100
        clip.saturation = self.saturation_slider.value() / 100
        clip.gamma = self.gamma_slider.value() / 100
        clip.volume = self.volume_slider.value() / 100
        self.timeline_changed()

    def timeline_changed(self) -> None:
        self.mark_dirty()
        self.timeline.set_project(self.project)
        self.preview_timer.start()
        self.status("Timeline updated — preparing a live preview…")

    def cut_selected(self) -> None:
        ids = [self.selected_clip_id] if self.selected_clip_id else None
        created = self.project.split_at(self.timeline.playhead, ids)
        if created:
            self.selected_clip_id = created[0]
            self.timeline.selected_id = created[0]
            self.timeline_changed()
        else:
            self.status("Move the playhead inside the selected clip before cutting.")

    def delete_selected_clip(self) -> None:
        if self.selected_clip_id:
            self.project.delete_clips([self.selected_clip_id], linked=True)
            self.selected_clip_id = None
            self.timeline_changed()

    def seek_timeline(self, seconds: float) -> None:
        if self.preview_path:
            self.player.setPosition(int(seconds * 1000))

    def refresh_timeline_preview(self) -> None:
        if not any(c.kind == "video" for c in self.project.timeline):
            return
        if self.preview_thread and self.preview_thread.isRunning():
            self.preview_timer.start(); return
        destination = str(Path(tempfile.gettempdir()) / "netvista-portable-preview.mp4")
        snapshot = deepcopy(self.project)
        def task(project: Project, output: str, emit) -> str:
            emit(0.05, "Rendering preview")
            return render_preview(project, output)
        self.preview_thread = TaskThread(task, snapshot, destination)
        self.preview_thread.progress.connect(lambda value, text: self.status(f"{text} · {int(value*100)}%"))
        self.preview_thread.completed.connect(self.preview_ready)
        self.preview_thread.failed.connect(lambda message: self.status(f"Preview unavailable: {message.splitlines()[-1]}"))
        self.preview_thread.start()

    def preview_ready(self, path: str) -> None:
        self.preview_path = path
        position = int(self.timeline.playhead * 1000)
        self.player.setSource(QUrl.fromLocalFile(path))
        self.player.setPosition(position)
        self.status("Timeline preview is ready.")

    def toggle_playback(self) -> None:
        if self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            self.player.pause(); self.play_button.setText("Play")
        else:
            if not self.preview_path and self.project.timeline:
                self.refresh_timeline_preview()
            self.player.play(); self.play_button.setText("Pause")

    def stop_playback(self) -> None:
        self.player.stop(); self.timeline.set_playhead(0); self.play_button.setText("Play")

    def player_position_changed(self, milliseconds: int) -> None:
        seconds = milliseconds / 1000
        if self.preview_path and Path(self.player.source().toLocalFile()) == Path(self.preview_path):
            self.timeline.set_playhead(seconds)
        frames = int((seconds % 1) * 30)
        self.time_label.setText(f"{int(seconds//3600):02d}:{int(seconds//60)%60:02d}:{int(seconds)%60:02d}:{frames:02d}")

    def resolution_changed(self, title: str) -> None:
        if title in RESOLUTION_PRESETS:
            width, height = RESOLUTION_PRESETS[title]
            self.width_spin.setValue(width); self.height_spin.setValue(height)
        custom = title == "Custom"
        self.width_spin.setEnabled(custom); self.height_spin.setEnabled(custom)

    def start_export(self) -> None:
        if self.export_thread and self.export_thread.isRunning():
            return
        container = self.container_combo.currentText()
        path, _ = QFileDialog.getSaveFileName(self, "Export movie", str(Path.home() / "Downloads" / f"{self.project.title}.{container}"),
                                              f"{container.upper()} (*.{container})")
        if not path:
            return
        options = ExportOptions(path, self.width_spin.value(), self.height_spin.value(),
                                int(self.fps_combo.currentText()), self.codec_combo.currentText(), container,
                                include_audio=self.audio_check.isChecked()).validated()
        if options.width >= 15360:
            answer = QMessageBox.question(self, "16K export", "16K output uses very large amounts of memory and storage and may take a long time. Continue?")
            if answer != QMessageBox.StandardButton.Yes:
                return
        process = ExportProcess()
        def task(project: Project, export_options: ExportOptions, emit) -> str:
            return process.run(project, export_options, emit)
        self.export_thread = TaskThread(task, deepcopy(self.project), options)
        self.export_thread.export_process = process
        self.export_thread.progress.connect(self.export_progress_changed)
        self.export_thread.completed.connect(self.export_finished)
        self.export_thread.failed.connect(self.export_failed)
        self.export_button.setEnabled(False); self.cancel_export_button.setEnabled(True)
        self.export_thread.start()
        self.status(f"Exporting {options.width} × {options.height}…")

    def export_progress_changed(self, value: float, text: str) -> None:
        self.export_progress.setValue(int(value * 100)); self.status(f"Exporting · {text}")

    def export_finished(self, path: str) -> None:
        self.export_progress.setValue(100); self.export_button.setEnabled(True); self.cancel_export_button.setEnabled(False)
        self.status(f"Export complete: {path}")

    def export_failed(self, message: str) -> None:
        self.export_button.setEnabled(True); self.cancel_export_button.setEnabled(False)
        self.status("Export failed.")
        QMessageBox.critical(self, "Export failed", message)

    def cancel_export(self) -> None:
        if self.export_thread:
            self.export_thread.cancel(); self.status("Cancelling export…")

    def add_3d_model(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(self, "Add 3D model", "", "3D models (*.obj *.dae *.gltf *.glb *.usdz);;All files (*)")
        if not paths:
            return
        portable = self.project.raw.setdefault("portable3DModels", [])
        for path in paths:
            if path not in portable:
                portable.append(path)
        self.mark_dirty(); self.refresh_3d_models()

    def refresh_3d_models(self) -> None:
        if not hasattr(self, "model_list"):
            return
        self.model_list.clear()
        for path in self.project.raw.get("portable3DModels", []):
            self.model_list.addItem(Path(path).name)

    def save_project(self) -> None:
        path = self.project.file_path
        if not path:
            path, _ = QFileDialog.getSaveFileName(self, "Save project", str(Path.home() / "Downloads" / f"{self.project.title}.netvistastudio"),
                                                  "NetVista Studio Project (*.netvistastudio)")
        if not path:
            return
        try:
            saved = self.project.save(path)
            self.project_dirty = False; self.setWindowTitle(f"NetVista Studio — {self.project.title}")
            self.status(f"Saved {saved.name}")
        except Exception as error:
            QMessageBox.critical(self, "Could not save", str(error))

    def open_project(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Open project", str(Path.home() / "Downloads"),
                                              "NetVista Studio Project (*.netvistastudio);;All files (*)")
        if not path:
            return
        try:
            self.project = Project.load(path)
            self.project_dirty = False; self.selected_clip_id = None; self.preview_path = None
            self.refresh_everything(); self.status(f"Opened {Path(path).name}")
            if self.project.timeline:
                self.preview_timer.start()
        except Exception as error:
            QMessageBox.critical(self, "Could not open project", str(error))

    def dragEnterEvent(self, event: QDragEnterEvent) -> None:
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event: QDropEvent) -> None:
        paths = [url.toLocalFile() for url in event.mimeData().urls() if url.isLocalFile()]
        mod_paths = [path for path in paths if self.mod_manager.is_package_source(path)]
        media_paths = [path for path in paths if path not in mod_paths]
        if mod_paths:
            self.show_page("Mods")
            self.install_mod_paths(mod_paths)
        if media_paths:
            self._import_paths(media_paths)
        event.acceptProposedAction()

    def closeEvent(self, event: QCloseEvent) -> None:
        if self.project_dirty:
            answer = QMessageBox.question(self, "Save your work?", "Save changes before closing?",
                                          QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel)
            if answer == QMessageBox.StandardButton.Cancel:
                event.ignore(); return
            if answer == QMessageBox.StandardButton.Save:
                self.save_project()
                if self.project_dirty:
                    event.ignore(); return
        if self.export_thread and self.export_thread.isRunning():
            self.export_thread.cancel(); self.export_thread.wait(2000)
        event.accept()
