$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
function Assert-NativeSuccess($step) {
  if ($LASTEXITCODE -ne 0) { throw "$step failed with exit code $LASTEXITCODE." }
}
python -m venv .build-env
Assert-NativeSuccess "Create build environment"
& .\.build-env\Scripts\python.exe -m pip install --upgrade pip
Assert-NativeSuccess "Install pip"
& .\.build-env\Scripts\python.exe -m pip install -r requirements-build.txt
Assert-NativeSuccess "Install build dependencies"
& .\.build-env\Scripts\python.exe -m unittest discover -s tests -v
Assert-NativeSuccess "Native regression tests"
& .\.build-env\Scripts\pyinstaller.exe --noconfirm --clean --windowed --onedir `
  --name NetVistaStudio --collect-all imageio_ffmpeg `
  --icon assets\NetVistaStudio.ico --add-data "assets\NetVistaStudio.png;assets" `
  --add-data "..\assets\home-video-coast.png;assets" `
  --exclude-module PySide6.QtQml --exclude-module PySide6.QtQuick `
  --exclude-module PySide6.QtPdf --exclude-module PySide6.QtVirtualKeyboard `
  --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtWebEngineWidgets `
  app.py
Assert-NativeSuccess "Freeze native application"
$smoke = Start-Process -FilePath ".\dist\NetVistaStudio\NetVistaStudio.exe" -ArgumentList "--smoke-test" -Wait -PassThru
if ($smoke.ExitCode -ne 0) { throw "Packaged application smoke test failed with exit code $($smoke.ExitCode)." }
& .\.build-env\Scripts\python.exe tests\package_media_check.py dist\NetVistaStudio
Assert-NativeSuccess "Packaged FFmpeg export check"
Write-Host "Built dist\NetVistaStudio\NetVistaStudio.exe"
