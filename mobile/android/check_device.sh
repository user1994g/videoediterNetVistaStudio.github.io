#!/bin/bash
# Runs inside a disposable Android emulator job. Keep the check exit status even
# when collecting diagnostic screenshots; emulator-runner starts one shell per
# script line, so this must be a single script invocation.
set -euo pipefail
adb install -r -t mobile/android/app/build/outputs/apk/debug/app-debug.apk
adb install -r -t mobile/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
check_status=0
# Gradle's managed connected-test cleanup removes the test application and its
# external-files screenshots. Run the already-built instrumentation directly on
# this disposable emulator so artifacts remain available until the job ends.
adb shell am instrument -w -r com.netvistastudio.editor.android.test/androidx.test.runner.AndroidJUnitRunner \
  | tee mobile/android/app/build/device-instrumentation.txt || check_status=$?
adb pull /sdcard/Android/data/com.netvistastudio.editor.android/files/ui-screenshots mobile/android/app/build/ui-screenshots || true
adb pull /sdcard/Pictures/NetVistaWorkspaceQA mobile/android/app/build/ui-screenshots-public || true
# Android's am instrument can exit zero even when JUnit reports failures.
if ! grep -Eq '^OK \([1-9][0-9]* tests?\)' mobile/android/app/build/device-instrumentation.txt; then check_status=1; fi
exit "$check_status"
