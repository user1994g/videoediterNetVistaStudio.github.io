$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
python -m venv .build-env
& .\.build-env\Scripts\python.exe -m pip install --upgrade pip
& .\.build-env\Scripts\python.exe -m pip install -r requirements-build.txt
& .\.build-env\Scripts\python.exe -m unittest discover -s tests -v
& .\.build-env\Scripts\pyinstaller.exe --noconfirm --clean --windowed --onedir `
  --name NetVistaStudio --collect-all imageio_ffmpeg app.py
Write-Host "Built dist\NetVistaStudio\NetVistaStudio.exe"
