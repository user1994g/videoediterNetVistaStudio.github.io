package com.netvistastudio.editor.android;

import android.content.ContentValues;
import android.content.Context;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Log;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;

/**
 * Test-only generated-fixture/screenshot evidence. On modern emulator devices,
 * scoped MediaStore-created PNGs survive AGP uninstalling the instrumented app,
 * so CI can pull /sdcard/Pictures/NetVistaWorkspaceQA after a failing run.
 * No production code, account details, user photo access or storage permission.
 */
final class QaEvidence {
    private QaEvidence() {}

    static void savePng(Context context, String name, Bitmap image) throws IOException {
        if (!name.matches("[A-Za-z0-9_.-]+\\.png")) throw new IOException("Invalid QA image name");
        if (Build.VERSION.SDK_INT >= 29) {
            ContentValues values = new ContentValues();
            values.put(MediaStore.Images.Media.DISPLAY_NAME, name);
            values.put(MediaStore.Images.Media.MIME_TYPE, "image/png");
            values.put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/NetVistaWorkspaceQA");
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
            Uri uri = context.getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new IOException("Could not create scoped QA PNG");
            boolean completed = false;
            try {
                try (OutputStream output = context.getContentResolver().openOutputStream(uri, "w")) {
                    if (output == null || !image.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                        throw new IOException("Could not encode QA PNG");
                    }
                }
                ContentValues published = new ContentValues();
                published.put(MediaStore.Images.Media.IS_PENDING, 0);
                context.getContentResolver().update(uri, published, null, null);
                completed = true;
                Log.i("NetVistaNativeUiChecks", "Retained QA PNG: Pictures/NetVistaWorkspaceQA/" + name);
            } finally {
                if (!completed) context.getContentResolver().delete(uri, null, null);
            }
        } else {
            // Older personal test devices do not grant broad shared-storage
            // permissions. Keep their QA output within app-owned external files.
            File external = context.getExternalFilesDir(null);
            if (external == null) throw new IOException("QA external folder is unavailable");
            File directory = new File(external, "ui-screenshots");
            if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Could not create QA folder");
            try (OutputStream output = new FileOutputStream(new File(directory, name))) {
                if (!image.compress(Bitmap.CompressFormat.PNG, 100, output)) throw new IOException("Could not encode QA PNG");
            }
        }
    }
}
