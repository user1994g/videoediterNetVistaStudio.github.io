from __future__ import annotations

import json
import math
import uuid
from copy import deepcopy
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


def new_id() -> str:
    return str(uuid.uuid4()).upper()


def finite(value: Any, fallback: float = 0.0) -> float:
    try:
        number = float(value)
        return number if math.isfinite(number) else fallback
    except (TypeError, ValueError):
        return fallback


def path_from_url(value: Any) -> str:
    if isinstance(value, str):
        return value[7:] if value.startswith("file://") else value
    if isinstance(value, dict):
        return str(value.get("relative") or value.get("absolute") or value.get("url") or "")
    return ""


@dataclass
class MediaAsset:
    id: str
    name: str
    url: str
    kind: str = "video"
    duration: float = 6.0
    has_audio: bool = True
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "MediaAsset":
        return cls(
            id=str(data.get("id") or new_id()),
            name=str(data.get("name") or Path(path_from_url(data.get("url"))).name or "Media"),
            url=path_from_url(data.get("url")),
            kind=str(data.get("kind") or "video"),
            duration=max(0.001, finite(data.get("duration"), 6.0)),
            has_audio=bool(data.get("hasAudio", True)),
            raw=deepcopy(data),
        )

    def to_dict(self) -> dict[str, Any]:
        data = deepcopy(self.raw)
        data.update({"id": self.id, "name": self.name, "url": self.url, "kind": self.kind,
                     "duration": self.duration, "hasAudio": self.has_audio})
        return data


@dataclass
class TimelineClip:
    id: str
    asset_id: str
    name: str
    url: str
    kind: str = "video"
    in_point: float = 0.0
    out_point: float = 0.0
    timeline_start: float = 0.0
    track: int = 0
    group_id: str | None = None
    brightness: float = 0.0
    contrast: float = 1.0
    saturation: float = 1.0
    gamma: float = 1.0
    temperature: float = 6500.0
    volume: float = 1.0
    transform: dict[str, Any] = field(default_factory=dict)
    effects: dict[str, Any] = field(default_factory=dict)
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "TimelineClip":
        return cls(
            id=str(data.get("id") or new_id()), asset_id=str(data.get("assetID") or new_id()),
            name=str(data.get("name") or Path(path_from_url(data.get("url"))).name or "Clip"),
            url=path_from_url(data.get("url")), kind=str(data.get("kind") or "video"),
            in_point=max(0.0, finite(data.get("inPoint"))), out_point=max(0.0, finite(data.get("outPoint"))),
            timeline_start=max(0.0, finite(data.get("timelineStart"))), track=max(0, int(data.get("track") or 0)),
            group_id=str(data["groupID"]) if data.get("groupID") else None,
            brightness=finite(data.get("brightness")), contrast=finite(data.get("contrast"), 1.0),
            saturation=finite(data.get("saturation"), 1.0), gamma=finite(data.get("gamma"), 1.0),
            temperature=finite(data.get("temperature"), 6500.0), volume=finite(data.get("volume"), 1.0),
            transform=deepcopy(data.get("transform") or {}), effects=deepcopy(data.get("effects") or {}),
            raw=deepcopy(data),
        )

    def duration(self, source_duration: float = 6.0) -> float:
        if self.out_point > self.in_point:
            return max(1 / 120, self.out_point - self.in_point)
        return max(1 / 120, source_duration - self.in_point)

    def to_dict(self) -> dict[str, Any]:
        data = deepcopy(self.raw)
        data.update({
            "id": self.id, "assetID": self.asset_id, "name": self.name, "url": self.url,
            "kind": self.kind, "inPoint": self.in_point, "outPoint": self.out_point,
            "timelineStart": self.timeline_start, "track": self.track,
            "brightness": self.brightness, "contrast": self.contrast, "saturation": self.saturation,
            "gamma": self.gamma, "temperature": self.temperature, "volume": self.volume,
            "transform": deepcopy(self.transform), "effects": deepcopy(self.effects),
        })
        if self.group_id:
            data["groupID"] = self.group_id
        else:
            data.pop("groupID", None)
        return data


@dataclass
class Project:
    title: str = "Untitled Project"
    media: list[MediaAsset] = field(default_factory=list)
    timeline: list[TimelineClip] = field(default_factory=list)
    scenes: list[dict[str, Any]] = field(default_factory=list)
    schema_version: int = 5
    raw: dict[str, Any] = field(default_factory=dict, repr=False)
    file_path: str | None = None

    @classmethod
    def load(cls, path: str | Path) -> "Project":
        source = Path(path)
        data = json.loads(source.read_text(encoding="utf-8"))
        project = cls(
            title=str(data.get("title") or source.stem),
            media=[MediaAsset.from_dict(item) for item in data.get("media", [])],
            timeline=[TimelineClip.from_dict(item) for item in data.get("timeline", [])],
            scenes=deepcopy(data.get("scenes", [])),
            schema_version=max(1, int(data.get("schemaVersion") or 1)), raw=deepcopy(data),
            file_path=str(source),
        )
        if project.schema_version < 4:
            for clip in project.timeline:
                if clip.kind == "audio":
                    clip.track = max(0, clip.track - 2)
        return project

    def save(self, path: str | Path | None = None) -> Path:
        destination = Path(path or self.file_path or f"{self.title}.netvistastudio")
        data = deepcopy(self.raw)
        data.update({"schemaVersion": max(5, self.schema_version), "title": self.title,
                     "media": [asset.to_dict() for asset in self.media],
                     "timeline": [clip.to_dict() for clip in self.timeline], "scenes": deepcopy(self.scenes)})
        destination.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        self.file_path = str(destination)
        return destination

    def asset(self, asset_id: str) -> MediaAsset | None:
        return next((item for item in self.media if item.id == asset_id), None)

    def clip(self, clip_id: str | None) -> TimelineClip | None:
        return next((item for item in self.timeline if item.id == clip_id), None)

    def clip_duration(self, clip: TimelineClip) -> float:
        asset = self.asset(clip.asset_id)
        return clip.duration(asset.duration if asset else max(clip.out_point, 6.0))

    def duration(self) -> float:
        return max((clip.timeline_start + self.clip_duration(clip) for clip in self.timeline), default=0.0)

    def append_time(self, kind: str, track: int = 0) -> float:
        return max((c.timeline_start + self.clip_duration(c) for c in self.timeline
                    if c.kind == kind and c.track == track), default=0.0)

    def add_asset(self, path: str | Path, kind: str, duration: float, has_audio: bool) -> MediaAsset:
        source = Path(path).resolve()
        asset = MediaAsset(new_id(), source.name, str(source), kind, max(duration, 1 / 120), has_audio)
        self.media.append(asset)
        return asset

    def add_to_timeline(self, asset: MediaAsset, start: float | None = None, video_track: int = 0) -> list[str]:
        group = new_id() if asset.kind == "video" and asset.has_audio else None
        start = self.append_time("video" if asset.kind == "video" else "audio", video_track) if start is None else max(0, start)
        created: list[TimelineClip] = []
        main = TimelineClip(new_id(), asset.id, asset.name, asset.url, asset.kind, 0, asset.duration,
                            start, video_track, group)
        created.append(main)
        if asset.kind == "video" and asset.has_audio:
            audio_track = 0
            while self._overlaps("audio", audio_track, start, start + asset.duration):
                audio_track += 1
            created.append(TimelineClip(new_id(), asset.id, asset.name, asset.url, "audio", 0,
                                        asset.duration, start, audio_track, group))
        self.timeline.extend(created)
        return [clip.id for clip in created]

    def _overlaps(self, kind: str, track: int, start: float, end: float, ignore: Iterable[str] = ()) -> bool:
        ignored = set(ignore)
        return any(c.id not in ignored and c.kind == kind and c.track == track and
                   start < c.timeline_start + self.clip_duration(c) - 1e-6 and
                   end > c.timeline_start + 1e-6 for c in self.timeline)

    def move_clip(self, clip_id: str, start: float, track: int, linked: bool = True) -> None:
        anchor = self.clip(clip_id)
        if not anchor:
            return
        moving = [anchor]
        if linked and anchor.group_id:
            moving = [c for c in self.timeline if c.group_id == anchor.group_id]
        delta = max(0.0, start) - anchor.timeline_start
        track_delta = max(0, track) - anchor.track
        for clip in moving:
            clip.timeline_start = max(0.0, clip.timeline_start + delta)
            if clip.kind == anchor.kind:
                clip.track = max(0, clip.track + track_delta)

    def delete_clips(self, ids: Iterable[str], linked: bool = True) -> None:
        deleting = set(ids)
        if linked:
            groups = {c.group_id for c in self.timeline if c.id in deleting and c.group_id}
            deleting.update(c.id for c in self.timeline if c.group_id in groups)
        self.timeline = [c for c in self.timeline if c.id not in deleting]

    def split_at(self, time: float, ids: Iterable[str] | None = None) -> list[str]:
        selected = set(ids or [])
        created: list[str] = []
        additions: list[TimelineClip] = []
        for clip in list(self.timeline):
            if selected and clip.id not in selected:
                continue
            end = clip.timeline_start + self.clip_duration(clip)
            if not (clip.timeline_start + 1 / 120 < time < end - 1 / 120):
                continue
            local = time - clip.timeline_start
            right = deepcopy(clip)
            right.id = new_id()
            right.timeline_start = time
            right.in_point = clip.in_point + local
            right.out_point = clip.out_point if clip.out_point > clip.in_point else clip.in_point + self.clip_duration(clip)
            clip.out_point = right.in_point
            additions.append(right)
            created.append(right.id)
        self.timeline.extend(additions)
        return created
