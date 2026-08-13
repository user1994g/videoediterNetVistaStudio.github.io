#!/bin/sh
set -eu
cd "$(dirname "$0")"
python3 -m venv .build-env
. .build-env/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements-build.txt
python -m unittest discover -s tests -v
pyinstaller --noconfirm --clean --windowed --onedir \
  --name NetVistaStudio --collect-all imageio_ffmpeg app.py
echo "Built dist/NetVistaStudio/NetVistaStudio"
