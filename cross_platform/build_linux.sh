#!/bin/sh
set -eu
cd "$(dirname "$0")"
python3 -m venv .build-env
. .build-env/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements-build.txt
python -m unittest discover -s tests -v
pyinstaller --noconfirm --clean --windowed --onedir \
  --name NetVistaStudio --collect-all imageio_ffmpeg \
  --exclude-module PySide6.QtQml --exclude-module PySide6.QtQuick \
  --exclude-module PySide6.QtPdf --exclude-module PySide6.QtVirtualKeyboard \
  --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtWebEngineWidgets \
  app.py
QT_QPA_PLATFORM=offscreen dist/NetVistaStudio/NetVistaStudio --smoke-test
echo "Built dist/NetVistaStudio/NetVistaStudio"
