#!/bin/bash
# Runs inside a disposable Android emulator job. Keep the check exit status even
# when collecting diagnostic screenshots; emulator-runner starts one shell per
# script line, so this must be a single script invocation.
set -u
check_status=0
gradle --no-daemon -p mobile/android -Pandroid.injected.keepTestApksInstalled=true :app:connectedDebugAndroidTest || check_status=$?
adb pull /sdcard/Android/data/com.netvistastudio.editor.android/files/ui-screenshots mobile/android/app/build/ui-screenshots || true
exit "$check_status"
