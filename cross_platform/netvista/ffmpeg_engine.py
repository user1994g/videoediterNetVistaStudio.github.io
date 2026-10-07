from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
from collections import deque
from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .model import Project, TimelineClip, finite


RESOLUTION_PRESETS: dict[str, tuple[int, int]] = {
    "720p HD": (1280, 720), "1080p HD": (1920, 1080), "1440p Quad HD": (2560, 1440),
    "4K Ultra HD": (3840, 2160), "6K": (6144, 3456), "8K Ultra HD": (7680, 4320),
    "12K": (11520, 6480), "16K Ultra HD": (15360, 8640),
}


@dataclass
class MediaInfo:
    duration: float
    width: int = 0
    height: int = 0
    has_video: bool = False
    has_audio: bool = False


@dataclass
class ExportOptions:
    output: str
    width: int = 1920
    height: int = 1080
    fps: int = 30
    codec: str = "Automatic"
    container: str = "mp4"
    quality: int = 20
    include_audio: bool = True
    preset: str = "medium"

    def validated(self) -> "ExportOptions":
        self.width = max(64, min(15360, int(self.width))) & ~1
        self.height = max(64, min(8640, int(self.height))) & ~1
        self.fps = max(1, min(120, int(self.fps)))
        self.quality = max(0, min(51, int(self.quality)))
        if self.width > 7680 and self.codec in {"Automatic", "H.264"}:
            self.codec = "HEVC (H.265)"
        return self


class FFmpegError(RuntimeError):
    pass


def ffmpeg_executable() -> str:
    configured = os.environ.get("NETVISTA_FFMPEG")
    if configured and Path(configured).exists():
        return configured
    system = shutil.which("ffmpeg")
    if system:
        return system
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception as error:
        raise FFmpegError("FFmpeg was not found. Reinstall NetVista Studio or set NETVISTA_FFMPEG.") from error


def probe_media(path: str) -> MediaInfo:
    process = subprocess.run([ffmpeg_executable(), "-hide_banner", "-i", path],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors="replace")
    text = process.stderr
    duration_match = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", text)
    duration = 6.0
    if duration_match:
        duration = int(duration_match[1]) * 3600 + int(duration_match[2]) * 60 + float(duration_match[3])
    video_line = next((line for line in text.splitlines() if "Video:" in line), "")
    audio_line = next((line for line in text.splitlines() if "Audio:" in line), "")
    size_match = re.search(r"(?<!\d)(\d{2,5})x(\d{2,5})(?!\d)", video_line)
    return MediaInfo(duration=max(duration, 1 / 120),
                     width=int(size_match[1]) if size_match else 0,
                     height=int(size_match[2]) if size_match else 0,
                     has_video=bool(video_line), has_audio=bool(audio_line))


def _escape_filter_path(path: str) -> str:
    return path.replace("\\", "/").replace(":", r"\:").replace("'", r"\'")


def _clip_filter(clip: TimelineClip, index: int, project: Project, width: int, height: int) -> str:
    duration = project.clip_duration(clip)
    brightness = max(-1.0, min(1.0, clip.brightness))
    contrast = max(0.0, min(4.0, clip.contrast))
    saturation = max(0.0, min(4.0, clip.saturation))
    gamma = max(0.1, min(10.0, clip.gamma))
    transform_scale = max(0.01, min(8.0, finite(clip.transform.get("scale"), 1.0)))
    # A zero value is an intentional transparent clip, not a missing setting.
    opacity = max(0.0, min(1.0, finite(clip.transform.get("opacity"), 1.0)))
    fit_w = max(2, int(width * transform_scale)) & ~1
    fit_h = max(2, int(height * transform_scale)) & ~1
    rotation = max(-360.0, min(360.0, finite(clip.transform.get("rotation"))))
    chain = [f"[{index}:v:0]trim=start={clip.in_point:.6f}:duration={duration:.6f}",
             "setpts=PTS-STARTPTS", "setsar=1",
             f"scale={fit_w}:{fit_h}:force_original_aspect_ratio=decrease",
             f"eq=brightness={brightness:.4f}:contrast={contrast:.4f}:saturation={saturation:.4f}:gamma={gamma:.4f}"]
    blur = max(0.0, min(50.0, finite(clip.effects.get("blurRadius"))))
    sharpen = max(0.0, min(4.0, finite(clip.effects.get("sharpenAmount"))))
    if blur:
        chain.append(f"gblur=sigma={blur:.4f}")
    if sharpen:
        chain.append(f"unsharp=5:5:{sharpen:.4f}:5:5:0")
    chain.append("format=rgba")
    if rotation:
        # Stored rotations share the Mac editor's counter-clockwise convention.
        angle = -rotation * 3.141592653589793 / 180
        chain.append(f"rotate={angle:.6f}:ow=rotw({angle:.6f}):oh=roth({angle:.6f}):c=black@0")
    chain += [f"colorchannelmixer=aa={opacity:.4f}", f"setpts=PTS+{clip.timeline_start:.6f}/TB[v{index}]"]
    return ",".join(chain)


def build_command(project: Project, options: ExportOptions) -> list[str]:
    options.validated()
    video = sorted((c for c in project.timeline if c.kind == "video"), key=lambda c: (c.track, c.timeline_start))
    audio = sorted((c for c in project.timeline if c.kind == "audio"), key=lambda c: (c.track, c.timeline_start))
    if not video:
        raise FFmpegError("The timeline has no video clips.")
    all_clips = video + (audio if options.include_audio else [])
    command = [ffmpeg_executable(), "-hide_banner", "-y"]
    for clip in all_clips:
        command += ["-i", clip.url]
    duration = max(1 / options.fps, project.duration())
    filters = [f"color=c=black:s={options.width}x{options.height}:r={options.fps}:d={duration:.6f}[base]"]
    for index, clip in enumerate(video):
        filters.append(_clip_filter(clip, index, project, options.width, options.height))
    previous = "base"
    for number, (index, clip) in enumerate(enumerate(video)):
        output = "vout" if number == len(video) - 1 else f"ov{number}"
        x = max(-2.0, min(2.0, finite(clip.transform.get("positionX")))) * options.width / 2
        y = -max(-2.0, min(2.0, finite(clip.transform.get("positionY")))) * options.height / 2
        filters.append(f"[{previous}][v{index}]overlay=x=(W-w)/2+{x:.4f}:y=(H-h)/2+{y:.4f}:"
                       f"eof_action=pass:shortest=0:format=auto[{output}]")
        previous = output
    if options.include_audio and audio:
        audio_labels = []
        offset = len(video)
        for number, clip in enumerate(audio):
            input_index = offset + number
            label = f"a{number}"
            delay = max(0, int(round(clip.timeline_start * 1000)))
            clip_duration = project.clip_duration(clip)
            filters.append(f"[{input_index}:a:0]atrim=start={clip.in_point:.6f}:duration={clip_duration:.6f},"
                           f"asetpts=PTS-STARTPTS,volume={max(0, clip.volume):.4f},adelay={delay}|{delay}[{label}]")
            audio_labels.append(f"[{label}]")
        filters.append("".join(audio_labels) + f"amix=inputs={len(audio_labels)}:duration=longest:normalize=0[aout]")
    command += ["-filter_complex", ";".join(filters), "-map", "[vout]"]
    if options.include_audio and audio:
        command += ["-map", "[aout]", "-c:a", "aac", "-b:a", "256k"]
    codec = options.codec
    if codec == "Automatic":
        codec = "HEVC (H.265)" if options.width > 3840 or options.height > 2160 else "H.264"
    codec_arguments = {
        "H.264": ["-c:v", "libx264", "-crf", str(options.quality), "-preset", options.preset],
        "HEVC (H.265)": ["-c:v", "libx265", "-crf", str(options.quality + 4), "-preset", options.preset],
        "AV1": ["-c:v", "libsvtav1", "-crf", str(options.quality + 8), "-preset", "8"],
        "ProRes 422 HQ": ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"],
    }
    command += codec_arguments.get(codec, codec_arguments["H.264"])
    command += ["-r", str(options.fps), "-pix_fmt", "yuv420p10le" if codec == "HEVC (H.265)" else "yuv420p"]
    if options.container in {"mp4", "mov"}:
        command += ["-movflags", "+faststart"]
    command += ["-progress", "pipe:1", "-nostats", options.output]
    return command


class ExportProcess:
    def __init__(self) -> None:
        self.process: subprocess.Popen[str] | None = None
        self.cancelled = threading.Event()

    def cancel(self) -> None:
        self.cancelled.set()
        if self.process and self.process.poll() is None:
            self.process.terminate()

    def run(self, project: Project, options: ExportOptions,
            progress: Callable[[float, str], None] | None = None) -> str:
        if self.cancelled.is_set():
            raise FFmpegError("Export cancelled.")
        command = build_command(project, options)
        total = max(project.duration(), 1 / options.fps)
        # FFmpeg writes diagnostics to stderr and progress records to stdout.
        # Keeping both as unread PIPEs can deadlock a long render as soon as
        # stderr's small OS buffer fills. Merge the streams and drain them
        # continuously so exports of real-length movies cannot silently stall.
        self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, errors="replace", bufsize=1)
        assert self.process.stdout is not None
        diagnostic_tail: deque[str] = deque(maxlen=20)
        try:
            for line in self.process.stdout:
                if self.cancelled.is_set():
                    raise FFmpegError("Export cancelled.")
                key, _, value = line.strip().partition("=")
                if key in {"out_time_us", "out_time_ms"}:
                    try:
                        seconds = int(value) / 1_000_000
                        if progress:
                            progress(min(0.999, seconds / total), f"{seconds:.1f} of {total:.1f} seconds")
                    except ValueError:
                        pass
                elif line.strip():
                    diagnostic_tail.append(line.rstrip())
            status = self.process.wait()
            if self.cancelled.is_set():
                raise FFmpegError("Export cancelled.")
            if status != 0:
                tail = "\n".join(diagnostic_tail)
                raise FFmpegError(tail or f"FFmpeg stopped with status {status}.")
            if progress:
                progress(1.0, "Complete")
            return options.output
        finally:
            # A worker is not finished until its encoder is reaped. Otherwise
            # Cancel/close can remove files while a child still writes to them.
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.process.stdout.close()


def render_preview(project: Project, destination: str) -> str:
    return ExportProcess().run(project, ExportOptions(destination, 1280, 720, 30, "H.264", "mp4", 30,
                                                       include_audio=True, preset="ultrafast"))


def render_frame(project: Project, seconds: float, destination: str) -> str:
    """Seek only active source frames; don't encode a whole movie for a slider."""
    snapshot = deepcopy(project)
    active = sorted((clip for clip in snapshot.timeline if clip.kind == "video" and
                     clip.timeline_start <= seconds < clip.timeline_start + snapshot.clip_duration(clip)),
                    key=lambda clip: (clip.track, clip.timeline_start))
    command = [ffmpeg_executable(), "-hide_banner", "-loglevel", "error", "-y"]
    source_offsets = []
    for clip in active:
        source_offsets.append(clip.in_point + seconds - clip.timeline_start)
        clip.in_point, clip.out_point, clip.timeline_start = 0, 0.1, 0
    snapshot.timeline = active
    filters = ["color=c=black:s=640x360:r=30:d=0.1[base]"]
    previous = "base"
    for index, (clip, offset) in enumerate(zip(active, source_offsets)):
        command += ["-ss", f"{offset:.6f}", "-i", clip.url]
        filters.append(_clip_filter(clip, index, snapshot, 640, 360))
        x = max(-2.0, min(2.0, finite(clip.transform.get("positionX")))) * 320
        y = -max(-2.0, min(2.0, finite(clip.transform.get("positionY")))) * 180
        output = f"frame{index}"
        filters.append(f"[{previous}][v{index}]overlay=x=(W-w)/2+{x:.4f}:y=(H-h)/2+{y:.4f}:"
                       f"eof_action=pass:format=auto[{output}]")
        previous = output
    command += ["-filter_complex", ";".join(filters), "-map", f"[{previous}]", "-frames:v", "1", "-update", "1", destination]
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=30)
    if result.returncode:
        raise FFmpegError(result.stderr[-2000:] or "Frame preview failed.")
    return destination
