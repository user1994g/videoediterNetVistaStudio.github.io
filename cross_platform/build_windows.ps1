$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
python -m venv .build-env
& .\.build-env\Scripts\python.exe -m pip install --upgrade pip
& .\.build-env\Scripts\python.exe -m pip install -r requirements-build.txt
& .\.build-env\Scripts\python.exe -m unittest discover -s tests -v
& .\.build-env\Scripts\pyinstaller.exe --noconfirm --clean --windowed --onedir `
  --name NetVistaStudio --collect-all imageio_ffmpeg `
  --icon assets\NetVistaStudio.ico --add-data "assets\NetVistaStudio.png;assets" `
  --exclude-module PySide6.QtQml --exclude-module PySide6.QtQuick `
  --exclude-module PySide6.QtPdf --exclude-module PySide6.QtVirtualKeyboard `
  --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtWebEngineWidgets `
  app.py
& .\dist\NetVistaStudio\NetVistaStudio.exe --smoke-test
if ($LASTEXITCODE -ne 0) { throw "Packaged application smoke test failed." }
Write-Host "Built dist\NetVistaStudio\NetVistaStudio.exe"
