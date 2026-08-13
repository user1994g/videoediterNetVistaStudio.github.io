from __future__ import annotations

from PySide6.QtCore import QPoint, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QFont, QKeyEvent, QMouseEvent, QPainter, QPen
from PySide6.QtWidgets import QWidget

from .model import Project, TimelineClip


class TimelineWidget(QWidget):
    selection_changed = Signal(str)
    clips_changed = Signal()
    playhead_changed = Signal(float)

    ruler_height = 30
    header_width = 74
    track_height = 46

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self.project = Project()
        self.zoom = 55.0
        self.playhead = 0.0
        self.selected_id: str | None = None
        self.drag_origin: QPoint | None = None
        self.drag_clip_start = 0.0
        self.drag_clip_track = 0
        self.setMinimumHeight(250)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setMouseTracking(True)

    def set_project(self, project: Project) -> None:
        self.project = project
        if self.selected_id and not project.clip(self.selected_id):
            self.selected_id = None
        self.update_size()
        self.update()

    def set_zoom(self, pixels_per_second: float) -> None:
        self.zoom = max(8.0, min(300.0, pixels_per_second))
        self.update_size()
        self.update()

    def set_playhead(self, seconds: float) -> None:
        self.playhead = max(0.0, seconds)
        self.update()

    def video_tracks(self) -> int:
        return max(3, 2 + max((c.track for c in self.project.timeline if c.kind == "video"), default=0))

    def audio_tracks(self) -> int:
        return max(2, 2 + max((c.track for c in self.project.timeline if c.kind == "audio"), default=0))

    def update_size(self) -> None:
        width = self.header_width + max(900, int((self.project.duration() + 12) * self.zoom))
        height = self.ruler_height + (self.video_tracks() + self.audio_tracks()) * self.track_height
        self.resize(width, height)
        self.setMinimumSize(width, height)

    def lane_index(self, clip: TimelineClip) -> int:
        videos = self.video_tracks()
        return videos - 1 - clip.track if clip.kind == "video" else videos + clip.track

    def lane_for_y(self, y: float) -> tuple[str, int]:
        videos = self.video_tracks()
        lane = max(0, int((y - self.ruler_height) / self.track_height))
        return ("video", max(0, videos - 1 - lane)) if lane < videos else ("audio", max(0, lane - videos))

    def clip_rect(self, clip: TimelineClip) -> QRectF:
        x = self.header_width + clip.timeline_start * self.zoom
        y = self.ruler_height + self.lane_index(clip) * self.track_height + 4
        return QRectF(x, y, max(2.0, self.project.clip_duration(clip) * self.zoom), self.track_height - 8)

    def clip_at(self, point: QPoint) -> TimelineClip | None:
        for clip in reversed(self.project.timeline):
            if self.clip_rect(clip).adjusted(-3, 0, 3, 0).contains(point):
                return clip
        return None

    def paintEvent(self, _event) -> None:
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("#101318"))
        painter.fillRect(0, 0, self.width(), self.ruler_height, QColor("#161a21"))
        painter.fillRect(0, 0, self.header_width, self.height(), QColor("#171b22"))
        painter.setFont(QFont("Arial", 8))
        duration = max(self.project.duration() + 12, (self.width() - self.header_width) / self.zoom)
        tick = 1 if self.zoom >= 50 else 5 if self.zoom >= 16 else 10
        painter.setPen(QPen(QColor("#343a45"), 1))
        second = 0
        while second <= duration:
            x = self.header_width + second * self.zoom
            painter.drawLine(int(x), self.ruler_height, int(x), self.height())
            painter.setPen(QColor("#89909c"))
            painter.drawText(int(x + 4), 19, f"{int(second//60):02d}:{int(second%60):02d}")
            painter.setPen(QPen(QColor("#343a45"), 1))
            second += tick
        tracks = [("V", track) for track in reversed(range(self.video_tracks()))]
        tracks += [("A", track) for track in range(self.audio_tracks())]
        for lane, (kind, track) in enumerate(tracks):
            y = self.ruler_height + lane * self.track_height
            if kind == "A":
                painter.fillRect(self.header_width, y, self.width() - self.header_width, self.track_height,
                                 QColor("#10251f"))
            painter.setPen(QColor("#303641"))
            painter.drawLine(0, y + self.track_height, self.width(), y + self.track_height)
            painter.setPen(QColor("#d1d5dc"))
            painter.drawText(14, y + 28, f"{kind}{track + 1}")
        for clip in self.project.timeline:
            rect = self.clip_rect(clip)
            selected = clip.id == self.selected_id
            color = QColor("#1f8a68") if clip.kind == "audio" else QColor("#397eaf")
            if selected:
                color = color.lighter(135)
            painter.setPen(QPen(QColor("#d8efff") if selected else color.lighter(125), 2 if selected else 1))
            painter.setBrush(color)
            painter.drawRoundedRect(rect, 4, 4)
            painter.setPen(QColor("#f4f5f7"))
            painter.drawText(rect.adjusted(7, 0, -4, 0), Qt.AlignmentFlag.AlignVCenter,
                             ("♫ " if clip.kind == "audio" else "▣ ") + clip.name)
        x = self.header_width + self.playhead * self.zoom
        painter.setPen(QPen(QColor("#ff3548"), 2))
        painter.drawLine(int(x), 0, int(x), self.height())
        painter.setBrush(QColor("#ff3548"))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawPolygon([QPoint(int(x - 6), 0), QPoint(int(x + 6), 0), QPoint(int(x), 9)])

    def mousePressEvent(self, event: QMouseEvent) -> None:
        self.setFocus()
        clip = self.clip_at(event.position().toPoint())
        if clip:
            self.selected_id = clip.id
            self.drag_origin = event.position().toPoint()
            self.drag_clip_start = clip.timeline_start
            self.drag_clip_track = clip.track
            self.selection_changed.emit(clip.id)
            self.update()
            return
        self.drag_origin = None
        self.playhead = max(0.0, (event.position().x() - self.header_width) / self.zoom)
        self.playhead_changed.emit(self.playhead)
        self.update()

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if not self.drag_origin or not self.selected_id or not (event.buttons() & Qt.MouseButton.LeftButton):
            return
        clip = self.project.clip(self.selected_id)
        if not clip:
            return
        delta = (event.position().x() - self.drag_origin.x()) / self.zoom
        kind, track = self.lane_for_y(event.position().y())
        if kind != clip.kind:
            track = self.drag_clip_track
        start = max(0.0, round((self.drag_clip_start + delta) * 30) / 30)
        self.project.move_clip(clip.id, start, track, linked=True)
        self.update_size()
        self.update()

    def mouseReleaseEvent(self, _event: QMouseEvent) -> None:
        if self.drag_origin:
            self.clips_changed.emit()
        self.drag_origin = None

    def keyPressEvent(self, event: QKeyEvent) -> None:
        if event.key() in {Qt.Key.Key_Delete, Qt.Key.Key_Backspace} and self.selected_id:
            self.project.delete_clips([self.selected_id], linked=True)
            self.selected_id = None
            self.update_size()
            self.update()
            self.clips_changed.emit()
            return
        super().keyPressEvent(event)
