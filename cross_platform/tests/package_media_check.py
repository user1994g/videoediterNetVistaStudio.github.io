"""Verify the FFmpeg executable inside a frozen portable app, not the dev copy."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> None:
    package = Path(sys.argv[1]).resolve()
    candidates = list((package / "_internal" / "imageio_ffmpeg" / "binaries").glob("ffmpeg*"))
    binaries = [path for path in candidates if path.is_file() and path.suffix not in {".py", ".pyc"}]
    if len(binaries) != 1:
        raise RuntimeError(f"Expected one bundled FFmpeg binary; found {binaries}")
    ffmpeg = str(binaries[0])
    with tempfile.TemporaryDirectory(prefix="netvista-packaged-media-") as temporary:
        movie = str(Path(temporary) / "probe.mp4")
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                        "color=c=red:s=96x54:r=30:d=0.2", "-an", "-c:v", "libx264",
                        "-threads", "1", "-pix_fmt", "yuv420p", "-y", movie], check=True, timeout=30)
        decoded = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", movie,
                                  "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                 check=True, capture_output=True, timeout=30).stdout
        if len(decoded) != 96 * 54 * 3:
            raise RuntimeError("Bundled FFmpeg did not decode a complete exported frame")
        centre = (27 * 96 + 48) * 3
        red, green, blue = decoded[centre:centre + 3]
        if not (red > 180 and green < 30 and blue < 30):
            raise RuntimeError(f"Bundled encoder/decoder returned incorrect pixels: {red, green, blue}")
    print("PASS: packaged FFmpeg executes, exports H.264 and decodes actual expected pixels")


if __name__ == "__main__":
    main()
