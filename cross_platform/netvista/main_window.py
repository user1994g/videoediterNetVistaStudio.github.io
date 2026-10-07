from __future__ import annotations

import tempfile
import platform
import sys
from copy import deepcopy
from pathlib import Path
from typing import Callable

from PySide6.QtCore import QThread, QTimer, QUrl, Qt, Signal, QMimeData, QSize
from PySide6.QtGui import QAction, QCloseEvent, QDesktopServices, QDragEnterEvent, QDropEvent, QKeySequence, QDrag, QPixmap, QPainter
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer
from PySide6.QtMultimediaWidgets import QVideoWidget
from PySide6.QtWidgets import (QCheckBox, QComboBox, QFileDialog, QFormLayout, QFrame, QGroupBox,
                               QApplication, QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow,
                               QMessageBox, QProgressBar, QPushButton, QScrollArea, QSlider, QSpinBox,
                               QDialog, QDialogButtonBox, QSplitter, QStackedWidget, QVBoxLayout, QWidget, QToolButton, QMenu, QSizePolicy)

from .ffmpeg_engine import (RESOLUTION_PRESETS, ExportOptions, ExportProcess, FFmpegError,
                            probe_media, render_frame)
from .model import MediaAsset, Project, TimelineClip, ProjectHistory, finite
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


class MediaPoolList(QListWidget):
    """Native source drag: timeline instances keep a source's existing identity."""
    def startDrag(self, _actions) -> None:
        items = self.selectedItems()
        if not items:
            return
        mime = QMimeData()
        mime.setData("application/x-netvista-source", str(items[0].data(Qt.ItemDataRole.UserRole)).encode())
        drag = QDrag(self)
        drag.setMimeData(mime)
        drag.exec(Qt.DropAction.CopyAction)


class InspectorStack(QStackedWidget):
    def minimumSizeHint(self) -> QSize:
        # Hidden export/mod pages must not dictate a wide scroll document and
        # push property readouts off-screen on a compact desktop.
        return QSize(0, 0)


class HomeArtwork(QWidget):
    """Reuse the Mac home photograph without stretching its proportions."""
    def __init__(self):
        super().__init__()
        bundle = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
        image = bundle / "assets" / "home-video-coast.png"
        if not image.exists():
            image = Path(__file__).resolve().parents[2] / "assets" / "home-video-coast.png"
        self.artwork = QPixmap(str(image))
        self.setFixedHeight(220)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), Qt.GlobalColor.black)
        if not self.artwork.isNull():
            fitted = self.artwork.scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                                         Qt.TransformationMode.SmoothTransformation)
            painter.drawPixmap((self.width() - fitted.width()) // 2, (self.height() - fitted.height()) // 2, fitted)


class FramePreview(QWidget):
    def __init__(self):
        super().__init__()
        self.image = QPixmap()
        self.message = "Import media to start editing"
        self.setMinimumHeight(140)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Expanding)

    def setPixmap(self, image):
        self.image = image
        self.message = ""
        self.update()

    def setText(self, message):
        self.image = QPixmap()
        self.message = message
        self.update()

    def clear(self):
        self.setText("")

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), Qt.GlobalColor.black)
        if self.image.isNull():
            painter.setPen(Qt.GlobalColor.lightGray)
            painter.drawText(self.rect(), Qt.AlignmentFlag.AlignCenter, self.message)
        else:
            frame = self.image.scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio,
                                      Qt.TransformationMode.SmoothTransformation)
            painter.drawPixmap((self.width() - frame.width()) // 2, (self.height() - frame.height()) // 2, frame)


class MainWindow(QMainWindow):
    pages = ["Media", "Cut", "Edit", "Effects", "Color", "Audio", "3D Scene", "Mods", "Export"]

    def __init__(self) -> None:
        super().__init__()
        self.project = Project()
        self.history = ProjectHistory()
        self.project_dirty = False
        self.preview_path: str | None = None
        self.preview_thread: TaskThread | None = None
        self.frame_thread: TaskThread | None = None
        self.export_thread: TaskThread | None = None
        self.update_thread: TaskThread | None = None
        self.current_page = "Media"
        self.selected_clip_id: str | None = None
        self._closing = False
        self.preview_revision = 0
        self.preview_pending_play = False
        self.program_mode = True
        self.pending_seek: int | None = None
        self.preview_folder = tempfile.TemporaryDirectory(prefix="netvista-preview-")
        self.property_sliders: list[QSlider] = []
        self.mod_manager = ModManager(__version__)
        self.mod_catalog = self.mod_manager.scan()
        self.setWindowTitle("NetVista Studio")
        self.resize(1500, 930)
        self.setMinimumSize(960, 640)
        self.setAcceptDrops(True)
        self.setStyleSheet(build_app_style(self.mod_manager.active_theme_tokens(self.mod_catalog)))
        self._build_ui()
        self._build_shortcuts()
        self.preview_timer = QTimer(self)
        self.preview_timer.setSingleShot(True)
        self.preview_timer.setInterval(250)
        self.preview_timer.timeout.connect(self.refresh_timeline_preview)
        self.frame_timer = QTimer(self)
        self.frame_timer.setSingleShot(True)
        self.frame_timer.setInterval(90)
        self.frame_timer.timeout.connect(self.refresh_frame)
        self.refresh_everything()
        self.show_home()

    def _build_ui(self) -> None:
        root = QWidget()
        layout = QVBoxLayout(root)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(self._top_bar())

        self.timeline = TimelineWidget()
        self.timeline.selection_changed.connect(self.select_clip)
        self.timeline.edit_started.connect(self.remember_edit)
        self.timeline.clips_changed.connect(self.timeline_changed)
        self.timeline.playhead_changed.connect(self.seek_timeline)
        self.timeline.asset_dropped.connect(self.add_source_at)
        self.timeline_scroll = QScrollArea()
        self.timeline_scroll.setWidget(self.timeline)
        self.timeline_scroll.setWidgetResizable(False)
        self.timeline_scroll.setMinimumHeight(260)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        self.media_panel = self._media_panel()
        splitter.addWidget(self.media_panel)
        center = QWidget()
        center_layout = QVBoxLayout(center)
        center_layout.setContentsMargins(0, 0, 0, 0)
        center_layout.setSpacing(0)
        vertical = QSplitter(Qt.Orientation.Vertical)
        vertical.addWidget(self._program_panel())
        timeline_panel = QWidget()
        timeline_column = QVBoxLayout(timeline_panel)
        timeline_column.setContentsMargins(0, 0, 0, 0)
        timeline_column.setSpacing(0)
        timeline_column.addWidget(self._timeline_toolbar())
        timeline_column.addWidget(self.timeline_scroll, 1)
        vertical.addWidget(timeline_panel)
        vertical.setSizes([470, 300])
        center_layout.addWidget(vertical)
        splitter.addWidget(center)
        self.inspector_panel = self._inspector_panel()
        splitter.addWidget(self.inspector_panel)
        splitter.setSizes([250, 980, 280])
        splitter.setStretchFactor(1, 1)
        splitter.setChildrenCollapsible(False)
        layout.addWidget(splitter, 1)
        layout.addWidget(self._page_dock())
        self.status_label = QLabel("Ready")
        self.status_label.setObjectName("status")
        layout.addWidget(self.status_label)
        self.editor_root = root
        self.root_stack = QStackedWidget()
        self.root_stack.addWidget(self._home_panel())
        self.root_stack.addWidget(root)
        self.setCentralWidget(self.root_stack)

    def _brand(self, row: QHBoxLayout) -> None:
        asset_root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
        logo = QLabel()
        logo.setPixmap(QPixmap(str(asset_root / "assets" / "NetVistaStudio.png")).scaled(28, 28, Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation))
        row.addWidget(logo)
        row.addWidget(QLabel("NetVista", objectName="brand"))
        row.addWidget(QLabel("STUDIO", objectName="studio"))

    def _home_panel(self) -> QWidget:
        home = QWidget()
        column = QVBoxLayout(home)
        column.setContentsMargins(32, 20, 32, 28)
        header = QHBoxLayout()
        self._brand(header)
        header.addStretch()
        account = QPushButton("Account")
        account.clicked.connect(lambda: self.account_controller.show() if hasattr(self, "account_controller") else None)
        update = QPushButton("Update")
        update.clicked.connect(self.check_for_updates)
        header.addWidget(account)
        header.addWidget(update)
        column.addLayout(header)
        column.addStretch()
        heading = QLabel("Welcome to your studio.")
        heading.setStyleSheet("font-size:28px;font-weight:600")
        column.addWidget(heading)
        column.addWidget(QLabel("Open the Video Editor or continue a saved project."))
        card = QGroupBox("VIDEO EDITOR")
        content = QVBoxLayout(card)
        content.setContentsMargins(24, 24, 24, 24)
        content.addWidget(HomeArtwork())
        detail = QLabel("Your media, a full timeline, motion, effects and colour.\nProjects stay on this computer until you export them.")
        detail.setWordWrap(True)
        content.addWidget(detail)
        actions = QHBoxLayout()
        for text, callback in [("Open editor", self.show_editor), ("New project", self.new_project), ("Open project…", self.open_project)]:
            button = QPushButton(text)
            button.clicked.connect(callback)
            actions.addWidget(button)
        content.addLayout(actions)
        column.addWidget(card)
        note = QLabel("Windows / Linux native beta · Video workspace. Mac photo, modelling and game workspaces are not included in this edition yet.")
        note.setWordWrap(True)
        note.setObjectName("panelTitle")
        column.addWidget(note)
        column.addStretch()
        return home

    def show_home(self) -> None:
        self.preview_pending_play = False
        self.player.pause()
        self.play_button.setText("Play")
        self.root_stack.setCurrentIndex(0)

    def show_editor(self) -> None:
        self.root_stack.setCurrentWidget(self.editor_root)

    def new_project(self) -> None:
        if not self.confirm_discard():
            return
        self.player.stop()
        self.player.setSource(QUrl())
        self.project = Project()
        self.history = ProjectHistory()
        self.selected_clip_id = None
        self.preview_path = None
        self.preview_revision += 1
        self.program_mode = True
        self.preview_pending_play = False
        self.pending_seek = None
        self.timeline.set_playhead(0)
        self.frame_view.clear()
        self.frame_view.setText("Import media to start editing")
        self.viewer_stack.setCurrentWidget(self.frame_view)
        self.project_dirty = False
        self.refresh_everything()
        self.show_editor()

    def _top_bar(self) -> QWidget:
        frame = QFrame(objectName="topBar")
        row = QHBoxLayout(frame)
        row.setContentsMargins(14, 8, 14, 8)
        self._brand(row)
        home = QPushButton("Studio Home")
        home.clicked.connect(self.show_home)
        row.addWidget(home)
        self.account_button = QPushButton("Sign in")
        self.account_button.clicked.connect(lambda: self.account_controller.show() if hasattr(self, "account_controller") else None)
        row.addWidget(self.account_button)
        row.addStretch()
        self.title_edit = QLineEdit("Untitled Project")
        self.title_edit.setMaximumWidth(160)
        self.title_edit.setMinimumWidth(100)
        self.title_edit.editingFinished.connect(self.title_changed)
        row.addWidget(self.title_edit)
        for title, callback in [("Undo", self.undo), ("Redo", self.redo), ("Open", self.open_project), ("Update", self.check_for_updates),
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
        self.media_list = MediaPoolList()
        self.media_list.setDragEnabled(True)
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
        self.video_widget.setMinimumHeight(140)
        self.video_widget.setAspectRatioMode(Qt.AspectRatioMode.KeepAspectRatio)
        self.frame_view = FramePreview()
        self.viewer_stack = QStackedWidget()
        self.viewer_stack.addWidget(self.video_widget)
        self.viewer_stack.addWidget(self.frame_view)
        self.viewer_stack.setCurrentWidget(self.frame_view)
        column.addWidget(self.viewer_stack, 1)
        self.audio_output = QAudioOutput()
        self.player = QMediaPlayer()
        self.player.setAudioOutput(self.audio_output)
        self.player.setVideoOutput(self.video_widget)
        self.player.positionChanged.connect(self.player_position_changed)
        self.player.mediaStatusChanged.connect(self.media_loaded)
        controls = QHBoxLayout()
        controls.addWidget(QLabel("PROGRAM MONITOR", objectName="panelTitle"))
        back = QPushButton("‹")
        back.clicked.connect(lambda: self.step_transport(-1))
        self.play_button = QPushButton("Play")
        self.play_button.clicked.connect(self.toggle_playback)
        stop = QPushButton("Stop")
        stop.clicked.connect(self.stop_playback)
        forward = QPushButton("›")
        forward.clicked.connect(lambda: self.step_transport(1))
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
        self.selection_label = QLabel("No timeline clip selected")
        self.selection_label.setWordWrap(True)
        column.addWidget(self.selection_label)
        self.inspector_stack = InspectorStack()
        self.inspector_stack.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.inspector_pages: dict[str, QWidget] = {}
        for page in self.pages:
            widget = self._make_inspector(page)
            self.inspector_pages[page] = widget
            self.inspector_stack.addWidget(widget)
        self.inspector_stack.setMinimumWidth(0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setWidget(self.inspector_stack)
        column.addWidget(scroll, 1)
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
        menu = QMenu(self)
        menu.addAction("Duplicate selected", self.duplicate_selected)
        for text, setting in [("Link video and audio", "linked"), ("Snap to clip edges", "snapping")]:
            action = menu.addAction(text)
            action.setCheckable(True)
            action.setChecked(True)
            action.toggled.connect(lambda checked, key=setting: setattr(self.timeline, key, checked))
        more = QToolButton()
        more.setText("•••")
        more.setToolTip("Duplicate, linked selection and snapping")
        more.setMenu(menu)
        more.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        row.addWidget(more)
        row.addStretch()
        zoom = QSlider(Qt.Orientation.Horizontal)
        self.zoom_slider = zoom
        zoom.setRange(8, 300)
        zoom.setValue(55)
        zoom.setMaximumWidth(120)
        zoom.setMinimumWidth(50)
        zoom.setToolTip("Timeline zoom")
        zoom.valueChanged.connect(lambda value: self.timeline.set_zoom(value))
        row.addWidget(zoom)
        fit = QPushButton("Fit")
        fit.clicked.connect(self.fit_timeline)
        row.addWidget(fit)
        return frame

    def _page_dock(self) -> QWidget:
        frame = QFrame(objectName="dock")
        row = QHBoxLayout(frame)
        row.setContentsMargins(10, 7, 10, 7)
        row.addStretch()
        self.page_buttons: dict[str, QPushButton] = {}
        for page in self.pages:
            button = QPushButton({"Color": "Colour", "3D Scene": "3D Assets"}.get(page, page))
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
            self.position_x_slider = self._slider(column, "Position X", -100, 100, 0, self.clip_controls_changed)
            self.position_y_slider = self._slider(column, "Position Y", -100, 100, 0, self.clip_controls_changed)
            self.scale_slider = self._slider(column, "Scale", 1, 800, 100, self.clip_controls_changed)
            self.rotation_slider = self._slider(column, "Rotation", -180, 180, 0, self.clip_controls_changed)
            self.opacity_slider = self._slider(column, "Opacity", 0, 100, 100, self.clip_controls_changed)
            reset = QPushButton("Reset motion")
            reset.clicked.connect(lambda: self.reset_clip_settings("motion"))
            column.addWidget(reset)
        elif page == "Effects":
            self.blur_slider = self._slider(column, "Blur", 0, 500, 0, self.clip_controls_changed)
            self.sharpen_slider = self._slider(column, "Sharpen", 0, 400, 0, self.clip_controls_changed)
            self.effects_summary = QLabel("No effects applied")
            self.effects_summary.setWordWrap(True)
            column.addWidget(self.effects_summary)
            reset = QPushButton("Remove effects")
            reset.clicked.connect(lambda: self.reset_clip_settings("effects"))
            column.addWidget(reset)
        elif page == "Color":
            self.brightness_slider = self._slider(column, "Brightness", -100, 100, 0, self.clip_controls_changed)
            self.contrast_slider = self._slider(column, "Contrast", 0, 300, 100, self.clip_controls_changed)
            self.saturation_slider = self._slider(column, "Saturation", 0, 300, 100, self.clip_controls_changed)
            self.gamma_slider = self._slider(column, "Gamma", 10, 300, 100, self.clip_controls_changed)
            reset = QPushButton("Reset colour")
            reset.clicked.connect(lambda: self.reset_clip_settings("colour"))
            column.addWidget(reset)
        elif page == "Audio":
            self.volume_slider = self._slider(column, "Volume", 0, 200, 100, self.clip_controls_changed)
        elif page == "3D Scene":
            note = QLabel("3D source references\nOBJ, DAE, GLTF and GLB files can be catalogued here. This portable edition does not render or sculpt them.")
            note.setWordWrap(True)
            column.addWidget(note)
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
        row = QHBoxLayout(group)
        slider = QSlider(Qt.Orientation.Horizontal)
        slider.setRange(minimum, maximum)
        slider.setValue(value)
        numeric = QSpinBox()
        numeric.setRange(minimum, maximum)
        numeric.setValue(value)
        numeric.setMaximumWidth(74)
        slider.readout = numeric
        slider.sliderPressed.connect(self.remember_edit)
        slider.valueChanged.connect(numeric.setValue)
        slider.valueChanged.connect(callback)
        numeric.valueChanged.connect(slider.setValue)
        row.addWidget(slider, 1)
        row.addWidget(numeric)
        self.property_sliders.append(slider)
        parent.addWidget(group)
        return slider

    def _export_controls(self) -> QWidget:
        widget = QWidget()
        form = QFormLayout(widget)
        form.setRowWrapPolicy(QFormLayout.RowWrapPolicy.WrapLongRows)
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
        self.export_button = QPushButton("Choose resolution and export", objectName="primary")
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
                                         ("Undo", QKeySequence.StandardKey.Undo, self.undo),
                                         ("Redo", QKeySequence.StandardKey.Redo, self.redo),
                                         ("Split", "Ctrl+K", self.cut_selected),
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
        self.remember_edit()
        self.project.title = self.title_edit.text().strip() or "Untitled Project"
        self.mark_dirty()

    def show_page(self, page: str) -> None:
        self.show_editor()
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
        self.load_clip_controls()

    def import_media(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(self, "Import media", "",
                                                "Media (*.mp4 *.mov *.mkv *.avi *.webm *.m4v *.mp3 *.wav *.aac *.flac *.ogg);;All files (*)")
        self._import_paths(paths)

    def _import_paths(self, paths: list[str]) -> None:
        if not paths:
            return
        self.remember_edit()
        imported = 0
        for path in paths:
            try:
                info = probe_media(path)
                if not info.has_video and not info.has_audio:
                    continue
                self.project.add_asset(path, "video" if info.has_video else "audio", info.duration, info.has_audio)
                imported += 1
            except Exception as error:
                QMessageBox.warning(self, "Could not import", f"{Path(path).name}\n\n{error}")
        if imported:
            self.mark_dirty(); self.refresh_everything(); self.status(f"Imported {imported} media file(s). Drag a source to the timeline.")

    def selected_asset(self) -> MediaAsset | None:
        items = self.media_list.selectedItems()
        return self.project.asset(items[0].data(Qt.ItemDataRole.UserRole)) if items else None

    def media_selected(self) -> None:
        asset = self.selected_asset()
        if asset:
            self.program_mode = False
            self.preview_pending_play = False
            self.player.setSource(QUrl.fromLocalFile(asset.url))
            self.viewer_stack.setCurrentWidget(self.video_widget)
            self.status(f"Selected {asset.name}")

    def add_selected_media(self) -> None:
        asset = self.selected_asset()
        if not asset:
            self.status("Select media first."); return
        self.remember_edit()
        created = self.project.add_to_timeline(asset)
        self.selected_clip_id = created[0]
        self.timeline.selected_id = created[0]
        self.timeline_changed()

    def add_all_media(self) -> None:
        if not self.project.media:
            return
        self.remember_edit()
        for asset in self.project.media:
            self.project.add_to_timeline(asset)
        self.timeline_changed()

    def remove_selected_media(self) -> None:
        asset = self.selected_asset()
        if not asset:
            return
        self.remember_edit()
        self.project.delete_clips([c.id for c in self.project.timeline if c.asset_id == asset.id], linked=False)
        self.project.media = [item for item in self.project.media if item.id != asset.id]
        self.timeline_changed(); self.refresh_everything()

    def add_source_at(self, asset_id: str, start: float, kind: str, track: int) -> None:
        asset = self.project.asset(asset_id)
        if asset is None or asset.kind != kind:
            self.status("Drop video onto a video track, or audio onto an audio track.")
            return
        self.remember_edit()
        created = self.project.add_to_timeline(asset, start, track)
        self.selected_clip_id = created[0]
        self.timeline.selected_id = created[0]
        self.timeline_changed()

    def remember_edit(self) -> None:
        self.history.remember(self.project)

    def undo(self) -> None:
        previous = self.history.undo(self.project)
        if previous is not None:
            self.project = previous
            self.refresh_everything()
            self.timeline_changed()
            self.status("Undo complete.")

    def redo(self) -> None:
        following = self.history.redo(self.project)
        if following is not None:
            self.project = following
            self.refresh_everything()
            self.timeline_changed()
            self.status("Redo complete.")

    def fit_timeline(self) -> None:
        available = max(100, self.timeline_scroll.viewport().width() - self.timeline.header_width - 20)
        self.zoom_slider.setValue(max(8, min(300, int(available / max(8, self.project.duration())))))
        self.timeline_scroll.horizontalScrollBar().setValue(0)

    def duplicate_selected(self) -> None:
        if self.project.clip(self.selected_clip_id) is None:
            return
        self.remember_edit()
        created = self.project.duplicate_clip(self.selected_clip_id, self.timeline.linked)
        self.selected_clip_id = created[0]
        self.timeline.selected_id = created[0]
        self.timeline_changed()

    def reset_clip_settings(self, group: str) -> None:
        clip = self.project.clip(self.selected_clip_id)
        if clip is None:
            self.status("Select a timeline clip first.")
            return
        self.remember_edit()
        if group == "motion":
            clip.transform.update(positionX=0, positionY=0, rotation=0, scale=1, opacity=1)
        elif group == "effects":
            clip.effects.update(blurRadius=0, sharpenAmount=0)
        elif group == "colour":
            clip.brightness, clip.contrast, clip.saturation, clip.gamma = 0, 1, 1, 1
        self.timeline_changed()

    def select_clip(self, clip_id: str) -> None:
        self.selected_clip_id = clip_id
        self.load_clip_controls()
        clip = self.project.clip(clip_id)
        self.program_mode = True
        if clip is not None and not (clip.timeline_start <= self.timeline.playhead < clip.timeline_start + self.project.clip_duration(clip)):
            self.timeline.set_playhead(clip.timeline_start)
        self.seek_timeline(self.timeline.playhead)

    def load_clip_controls(self) -> None:
        clip = self.project.clip(self.selected_clip_id)
        self.selection_label.setText(clip.name if clip else "No timeline clip selected")
        for slider in self.property_sliders:
            slider.setEnabled(clip is not None)
            slider.readout.setEnabled(clip is not None)
        if not clip:
            self.effects_summary.setText("Select a clip to edit its effects.")
            return
        values = [(self.scale_slider, finite(clip.transform.get("scale"), 1) * 100),
                  (self.position_x_slider, finite(clip.transform.get("positionX")) * 100),
                  (self.position_y_slider, finite(clip.transform.get("positionY")) * 100),
                  (self.rotation_slider, finite(clip.transform.get("rotation"))),
                  (self.opacity_slider, finite(clip.transform.get("opacity"), 1) * 100),
                  (self.blur_slider, finite(clip.effects.get("blurRadius")) * 10),
                  (self.sharpen_slider, finite(clip.effects.get("sharpenAmount")) * 100),
                  (self.brightness_slider, finite(clip.brightness) * 100),
                  (self.contrast_slider, finite(clip.contrast, 1) * 100),
                  (self.saturation_slider, finite(clip.saturation, 1) * 100),
                  (self.gamma_slider, finite(clip.gamma, 1) * 100),
                  (self.volume_slider, finite(clip.volume, 1) * 100)]
        for slider, value in values:
            if slider:
                value = int(max(slider.minimum(), min(slider.maximum(), value)))
                slider.blockSignals(True); slider.setValue(value); slider.blockSignals(False)
                slider.readout.blockSignals(True); slider.readout.setValue(value); slider.readout.blockSignals(False)
        active = []
        if finite(clip.effects.get("blurRadius")):
            active.append("Blur")
        if finite(clip.effects.get("sharpenAmount")):
            active.append("Sharpen")
        self.effects_summary.setText("Applied: " + " + ".join(active) if active else "No effects applied")

    def clip_controls_changed(self, _value: int) -> None:
        clip = self.project.clip(self.selected_clip_id)
        if not clip:
            return
        if not any(slider.isSliderDown() for slider in self.property_sliders):
            self.remember_edit()
        changed = self.sender()
        # Write only the property the user touched. A portable UI with fewer
        # controls must never replace richer Mac values just by editing opacity.
        properties = [
            (self.position_x_slider, "transform", "positionX", 100),
            (self.position_y_slider, "transform", "positionY", 100),
            (self.rotation_slider, "transform", "rotation", 1),
            (self.scale_slider, "transform", "scale", 100),
            (self.opacity_slider, "transform", "opacity", 100),
            (self.blur_slider, "effects", "blurRadius", 10),
            (self.sharpen_slider, "effects", "sharpenAmount", 100),
            (self.brightness_slider, None, "brightness", 100),
            (self.contrast_slider, None, "contrast", 100),
            (self.saturation_slider, None, "saturation", 100),
            (self.gamma_slider, None, "gamma", 100),
            (self.volume_slider, None, "volume", 100),
        ]
        for slider, group, key, divisor in properties:
            if changed is slider:
                if group is None:
                    setattr(clip, key, slider.value() / divisor)
                else:
                    getattr(clip, group)[key] = slider.value() / divisor
                break
        self.timeline_changed()

    def timeline_changed(self) -> None:
        self.mark_dirty()
        self.preview_revision += 1
        self.preview_path = None
        self.program_mode = True
        self.preview_pending_play = self.preview_pending_play or self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState
        self.player.pause()
        if self.preview_thread and self.preview_thread.isRunning():
            self.preview_thread.cancel()
        self.timeline.set_project(self.project)
        self.load_clip_controls()
        if not any(c.kind == "video" for c in self.project.timeline):
            self.preview_path = None
            self.player.setSource(QUrl())
            self.frame_view.clear()
            self.frame_view.setText("Import media to start editing")
            self.viewer_stack.setCurrentWidget(self.frame_view)
            self.play_button.setText("Play")
            return
        self.frame_timer.start()
        if self.preview_pending_play:
            self.preview_timer.start()
        self.status("Timeline updated — preparing the current frame…")

    def cut_selected(self) -> None:
        ids = [self.selected_clip_id] if self.selected_clip_id else None
        self.remember_edit()
        created = self.project.split_at(self.timeline.playhead, ids, self.timeline.linked)
        if created:
            self.selected_clip_id = created[0]
            self.timeline.selected_id = created[0]
            self.timeline_changed()
        else:
            self.status("Move the playhead inside the selected clip before cutting.")

    def delete_selected_clip(self) -> None:
        if self.selected_clip_id:
            self.remember_edit()
            self.project.delete_clips([self.selected_clip_id], linked=self.timeline.linked)
            self.selected_clip_id = None
            self.timeline_changed()

    def seek_timeline(self, seconds: float) -> None:
        self.program_mode = True
        self.player_position_changed(int(seconds * 1000))
        if self.preview_path:
            if self.player.source().toLocalFile() != self.preview_path:
                self.pending_seek = int(seconds * 1000)
                self.player.setSource(QUrl.fromLocalFile(self.preview_path))
            self.player.setPosition(int(seconds * 1000))
        if self.player.playbackState() != QMediaPlayer.PlaybackState.PlayingState:
            self.frame_timer.start()

    def refresh_frame(self) -> None:
        if self._closing or not self.program_mode or self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            return
        if self.frame_thread and self.frame_thread.isRunning():
            self.frame_timer.start()
            return
        revision, position = self.preview_revision, self.timeline.playhead
        destination = str(Path(self.preview_folder.name) / "frame.png")
        def task(snapshot, seconds, output, _emit):
            return render_frame(snapshot, seconds, output)
        self.frame_thread = TaskThread(task, deepcopy(self.project), position, destination)
        self.frame_thread.completed.connect(lambda path: self.frame_ready(path, revision, position))
        self.frame_thread.failed.connect(lambda text: self.status(f"Frame preview unavailable: {text.splitlines()[-1]}"))
        self.frame_thread.start()

    def frame_ready(self, path: str, revision: int, position: float) -> None:
        if self._closing:
            return
        if revision != self.preview_revision or abs(position - self.timeline.playhead) > 1 / 60:
            self.frame_timer.start()
            return
        if not self.program_mode or self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            return
        pixmap = QPixmap(path)
        self.frame_view.setPixmap(pixmap)
        self.viewer_stack.setCurrentWidget(self.frame_view)
        self.status("Current frame updated.")

    def refresh_timeline_preview(self) -> None:
        if self._closing:
            return
        if not any(c.kind == "video" for c in self.project.timeline):
            return
        if self.preview_thread and self.preview_thread.isRunning():
            self.preview_timer.start(); return
        revision = self.preview_revision
        destination = str(Path(self.preview_folder.name) / f"preview-{revision}.mp4")
        snapshot = deepcopy(self.project)
        process = ExportProcess()
        def task(project: Project, output: str, emit) -> str:
            emit(0.05, "Rendering preview")
            return process.run(project, ExportOptions(output, 1280, 720, 30, "H.264", "mp4", 30,
                                                       include_audio=True, preset="ultrafast"), emit)
        self.preview_thread = TaskThread(task, snapshot, destination)
        self.preview_thread.export_process = process
        self.preview_thread.progress.connect(lambda value, text: self.status(f"{text} · {int(value*100)}%"))
        self.preview_thread.completed.connect(lambda path, version=revision: self.preview_ready(path, version))
        self.preview_thread.failed.connect(lambda message: self.status(f"Preview unavailable: {message.splitlines()[-1]}")
                                           if revision == self.preview_revision else None)
        self.preview_thread.start()

    def preview_ready(self, path: str, revision: int) -> None:
        if self._closing:
            return
        if revision != self.preview_revision:
            Path(path).unlink(missing_ok=True)
            self.preview_timer.start()
            return
        self.preview_path = path
        if self.program_mode:
            self.pending_seek = int(self.timeline.playhead * 1000)
            self.player.setSource(QUrl.fromLocalFile(path))
            self.viewer_stack.setCurrentWidget(self.video_widget)
        self.status("Timeline preview is ready.")

    def media_loaded(self, status) -> None:
        if status == QMediaPlayer.MediaStatus.LoadedMedia and self.program_mode:
            if self.pending_seek is not None:
                self.player.setPosition(self.pending_seek)
                self.pending_seek = None
            if self.preview_pending_play:
                self.preview_pending_play = False
                self.player.play()
                self.play_button.setText("Pause")
            # Keep at most the current rendered movie and any still-loaded
            # source; preview revisions must not accumulate multi-GB files.
            loaded = self.player.source().toLocalFile()
            for old in Path(self.preview_folder.name).glob("preview-*.mp4"):
                if str(old) not in {self.preview_path, loaded}:
                    try:
                        old.unlink()
                    except OSError:
                        pass  # A native codec may retain it until the next swap.

    def toggle_playback(self) -> None:
        if self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            self.player.pause(); self.play_button.setText("Play")
            if self.program_mode:
                self.frame_timer.start()
        else:
            if self.program_mode and not self.preview_path and self.project.timeline:
                self.preview_pending_play = True
                self.refresh_timeline_preview()
                return
            self.viewer_stack.setCurrentWidget(self.video_widget)
            if self.program_mode and self.preview_path:
                self.seek_timeline(self.timeline.playhead)
            self.player.play(); self.play_button.setText("Pause")

    def step_transport(self, delta: float) -> None:
        if self.program_mode:
            position = min(self.project.duration(), max(0.0, self.timeline.playhead + delta))
            self.timeline.set_playhead(position)
            self.seek_timeline(position)
        else:
            self.player.setPosition(max(0, self.player.position() + int(delta * 1000)))

    def stop_playback(self) -> None:
        self.preview_pending_play = False
        self.player.stop(); self.timeline.set_playhead(0); self.play_button.setText("Play")
        if self.program_mode:
            self.seek_timeline(0)

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
        if not any(clip.kind == "video" for clip in self.project.timeline):
            self.status("Add a video to the timeline before exporting.")
            return
        if not self.choose_export_resolution():
            return
        container = self.container_combo.currentText()
        path, _ = QFileDialog.getSaveFileName(self, "Export movie", str(Path.home() / "Downloads" / f"{self.project.title}.{container}"),
                                              f"{container.upper()} (*.{container})")
        if not path:
            return
        options = ExportOptions(path, self.width_spin.value(), self.height_spin.value(),
                                int(self.fps_combo.currentText()), self.codec_combo.currentText(), container,
                                include_audio=self.audio_check.isChecked()).validated()
        self.export_dialog = QDialog(self)
        self.export_dialog.setWindowTitle("Exporting movie")
        self.export_dialog.setMinimumWidth(420)
        popup = QVBoxLayout(self.export_dialog)
        popup.addWidget(QLabel(f"{options.width} × {options.height} · {options.fps} fps · {options.codec}"))
        self.export_popup_progress = QProgressBar()
        self.export_popup_progress.setRange(0, 100)
        popup.addWidget(self.export_popup_progress)
        self.export_popup_label = QLabel("Starting export…")
        popup.addWidget(self.export_popup_label)
        cancel = QPushButton("Cancel export")
        cancel.clicked.connect(self.cancel_export)
        popup.addWidget(cancel)
        self.export_dialog.rejected.connect(self.cancel_export)
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
        self.export_dialog.show()
        self.status(f"Exporting {options.width} × {options.height}…")

    def choose_export_resolution(self) -> bool:
        """Always confirm the output raster before opening the save picker."""
        dialog = QDialog(self)
        dialog.setWindowTitle("Export settings")
        form = QFormLayout(dialog)
        message = QLabel("Choose all movie settings here, then select where to save the finished export.")
        message.setWordWrap(True)
        form.addRow(message)

        resolution = QComboBox()
        resolution.addItems(list(RESOLUTION_PRESETS) + ["Custom"])
        resolution.setCurrentText(self.resolution_combo.currentText())
        width = QSpinBox(); width.setRange(64, 15360); width.setValue(self.width_spin.value())
        height = QSpinBox(); height.setRange(64, 8640); height.setValue(self.height_spin.value())

        def update_size(title: str) -> None:
            custom = title == "Custom"
            width.setEnabled(custom); height.setEnabled(custom)
            if title in RESOLUTION_PRESETS:
                preset_width, preset_height = RESOLUTION_PRESETS[title]
                width.setValue(preset_width); height.setValue(preset_height)

        resolution.currentTextChanged.connect(update_size)
        update_size(resolution.currentText())
        form.addRow("Resolution", resolution)
        form.addRow("Custom width", width)
        form.addRow("Custom height", height)
        fps = QComboBox()
        fps.addItems([self.fps_combo.itemText(i) for i in range(self.fps_combo.count())])
        fps.setCurrentText(self.fps_combo.currentText())
        codec = QComboBox()
        codec.addItems([self.codec_combo.itemText(i) for i in range(self.codec_combo.count())])
        codec.setCurrentText(self.codec_combo.currentText())
        container = QComboBox()
        container.addItems([self.container_combo.itemText(i) for i in range(self.container_combo.count())])
        container.setCurrentText(self.container_combo.currentText())
        audio = QCheckBox("Include timeline audio")
        audio.setChecked(self.audio_check.isChecked())
        form.addRow("Frame rate", fps)
        form.addRow("Video codec", codec)
        form.addRow("Container", container)
        form.addRow(audio)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("Continue to Save")
        buttons.accepted.connect(dialog.accept); buttons.rejected.connect(dialog.reject)
        form.addRow(buttons)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return False

        self.resolution_combo.setCurrentText(resolution.currentText())
        self.width_spin.setValue(width.value())
        self.height_spin.setValue(height.value())
        self.fps_combo.setCurrentText(fps.currentText())
        self.codec_combo.setCurrentText(codec.currentText())
        self.container_combo.setCurrentText(container.currentText())
        self.audio_check.setChecked(audio.isChecked())
        return True

    def export_progress_changed(self, value: float, text: str) -> None:
        self.export_progress.setValue(int(value * 100)); self.status(f"Exporting · {text}")
        self.export_popup_progress.setValue(int(value * 100))
        self.export_popup_label.setText(text)

    def export_finished(self, path: str) -> None:
        self.export_progress.setValue(100); self.export_button.setEnabled(True); self.cancel_export_button.setEnabled(False)
        self.status(f"Export complete: {path}")
        self.export_dialog.accept()

    def export_failed(self, message: str) -> None:
        self.export_button.setEnabled(True); self.cancel_export_button.setEnabled(False)
        self.status("Export failed.")
        self.export_dialog.accept()
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
        if not self.confirm_discard():
            return
        try:
            project = Project.load(path)
            self.player.stop()
            self.player.setSource(QUrl())
            self.preview_revision += 1
            self.program_mode = True
            self.preview_pending_play = False
            self.pending_seek = None
            self.project = project
            self.history = ProjectHistory()
            self.timeline.set_playhead(0)
            self.project_dirty = False; self.selected_clip_id = None; self.preview_path = None
            self.refresh_everything(); self.status(f"Opened {Path(path).name}")
            if self.project.timeline:
                self.frame_timer.start()
        except Exception as error:
            QMessageBox.critical(self, "Could not open project", str(error))

    def confirm_discard(self) -> bool:
        if not self.project_dirty:
            return True
        answer = QMessageBox.question(self, "Save your work?", "Save changes before opening another project?",
                                      QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel)
        if answer == QMessageBox.StandardButton.Cancel:
            return False
        if answer == QMessageBox.StandardButton.Save:
            self.save_project()
            return not self.project_dirty
        return True

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
        self._closing = True
        self.preview_timer.stop()
        self.frame_timer.stop()
        for worker in [self.frame_thread, self.preview_thread, self.export_thread, self.update_thread]:
            if worker and worker.isRunning():
                worker.cancel()
                if not worker.wait(2000):
                    self._closing = False
                    self.status("Finishing the active background task before closing…")
                    event.ignore()
                    return
        self.player.stop()
        self.player.setSource(QUrl())
        self.preview_folder.cleanup()
        event.accept()
