package com.netvistastudio.editor.android;

import android.content.Context;
import android.net.Uri;
import android.util.AtomicFile;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

/** App-private atomic photo draft and immutable SAF save payloads. */
final class PhotoWorkspaceFiles {
    private final Context context; private final File directory;
    PhotoWorkspaceFiles(Context context)throws IOException{this.context=context.getApplicationContext();directory=new File(context.getFilesDir(),"photos");if(!directory.isDirectory()&&!directory.mkdirs())throw new IOException("Cannot create photo storage.");}
    String readDraft()throws IOException{AtomicFile file=new AtomicFile(new File(directory,"draft.netvistaphoto"));if(!file.getBaseFile().exists())return null;try(InputStream input=file.openRead()){return new String(read(input,budget()),StandardCharsets.UTF_8);}}
    void saveDraft(PhotoDocument state)throws IOException{try{writeAtomic(new File(directory,"draft.netvistaphoto"),state.encode().getBytes(StandardCharsets.UTF_8));}catch(OutOfMemoryError error){throw new IOException("Insufficient memory to encode this photo draft. Existing saved files are intact.",error);}}
    String prepare(PhotoDocument state,boolean png)throws IOException{
        String id=UUID.randomUUID().toString();File target=pending(id,png);FileOutputStream output=null;AtomicFile file=new AtomicFile(target);android.graphics.Bitmap image=null;
        try{output=file.startWrite();if(png){image=PhotoBitmapEngine.render(state,0,renderBudget());if(!image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,output))throw new IOException("Unable to encode photo export.");}else output.write(state.encode().getBytes(StandardCharsets.UTF_8));file.finishWrite(output);return id;}
        catch(IOException|RuntimeException error){if(output!=null)file.failWrite(output);throw error;}
        catch(OutOfMemoryError error){if(output!=null)file.failWrite(output);throw new IOException("Insufficient memory to prepare this photo save. Your current edit remains intact.",error);}
        finally{if(image!=null)image.recycle();}
    }
    void deliver(String id,boolean png,Uri destination)throws IOException{if(destination==null)throw new IOException("No destination selected.");try(InputStream input=new FileInputStream(pending(id,png));OutputStream output=context.getContentResolver().openOutputStream(destination,"wt")){if(output==null)throw new IOException("The chosen Files provider did not open the destination.");byte[] buffer=new byte[65536];int count;while((count=input.read(buffer))!=-1)output.write(buffer,0,count);}}
    boolean pendingExists(String id,boolean png){try{return pending(id,png).isFile();}catch(IOException error){return false;}}
    void deletePending(String id,boolean png){if(id==null)return;try{new AtomicFile(pending(id,png)).delete();}catch(IOException ignored){}}
    String readProject(Uri uri)throws IOException{try(InputStream input=context.getContentResolver().openInputStream(uri)){if(input==null)throw new IOException("Cannot read photo project.");return new String(read(input,budget()),StandardCharsets.UTF_8);}}
    static byte[] read(InputStream input,long maximum)throws IOException{if(input==null)throw new IOException("The selected file could not be read.");try{ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] buffer=new byte[32768];int count;while((count=input.read(buffer))!=-1){if((long)out.size()+count>maximum)throw new IOException("This file exceeds the device's safe working memory budget.");out.write(buffer,0,count);}return out.toByteArray();}catch(OutOfMemoryError error){throw new IOException("Insufficient memory to read this photo. Your current edit remains intact.",error);}}
    static long renderBudget(){Runtime r=Runtime.getRuntime();return Math.max(1,(long)((r.maxMemory()-(r.totalMemory()-r.freeMemory()))*.65));}
    private static long budget(){return Math.max(1,Math.min(PhotoDocument.MAX_PROJECT_BYTES,renderBudget()/6));}
    private File pending(String id,boolean png)throws IOException{try{if(id==null||!UUID.fromString(id).toString().equals(id))throw new IllegalArgumentException();}catch(IllegalArgumentException error){throw new IOException("Invalid photo save identifier.");}return new File(directory,"pending-"+id+(png?".png":".netvistaphoto"));}
    private static void writeAtomic(File path,byte[] bytes)throws IOException{AtomicFile file=new AtomicFile(path);FileOutputStream output=null;try{output=file.startWrite();output.write(bytes);file.finishWrite(output);}catch(IOException error){if(output!=null)file.failWrite(output);throw error;}}
}
