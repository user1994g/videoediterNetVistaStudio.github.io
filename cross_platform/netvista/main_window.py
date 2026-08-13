from __future__ import annotations

import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QThread, QTimer, QUrl, Qt, Signal
from PySide6.QtGui import QAction, QCloseEvent, QDragEnterEvent, QDropEvent, QKeySequence
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (QCheckBox, QComboBox, QFileDialog, QFormLayout, QFrame, QGroupBox,
                               QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
                               QMessageBox, QProgressBar, QPushButton, QScrollArea, QSlider, QSpinBox,
                               QSplitter, QStackedWidget, QVBoxLayout, QWidget)

from .ffmpeg_engine import (RESOLUTION_PRESETS, ExportOptions, ExportProcess, FFmpegError,
                            probe_media, render_preview)
from .model import MediaAsset, Project, TimelineClip
from .theme import APP_STYLE
from .timeline import TimelineWidget


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
    pages = ["Media", "Cut", "Edit", "Effects", "Color", "Audio", "3D Scene", "Export"]

    def __init__(self) -> None:
        super().__init__()
        self.project = Project()
        self.project_dirty = False
        self.preview_path: str | None = None
        self.preview_thread: TaskThread | None = None
        self.export_thread: TaskThread | None = None
        self.current_page = "Media"
        self.selected_clip_id: str | None = None
        self.setWindowTitle("NetVista Studio — Windows / Linux Beta")
        self.resize(1500, 930)
        self.setMinimumSize(960, 640)
        self.setAcceptDrops(True)
        self.setStyleSheet(APP_STYLE)
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
        for title, callback in [("Open", self.open_project), ("Save your work", self.save_project)]:
            button = QPushButton(title)
            button.clicked.connect(callback)
            row.addWidget(button)
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
        elif page == "Export":
            column.addWidget(self._export_controls())
        column.addStretch()
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
        self._import_paths(paths)
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
