package com.netvistastudio.editor.android;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Best-effort 25-minute checks while backgrounded. Android may defer during Doze. */
public final class AccountCheckJob extends JobService {
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    public static void schedule(Context context) {
        JobScheduler scheduler = (JobScheduler) context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if (scheduler != null) scheduler.schedule(new JobInfo.Builder(7307,
                new ComponentName(context, AccountCheckJob.class))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(AuthPolicy.CHECK_INTERVAL_MS).setPersisted(true).build());
    }
    @Override public boolean onStartJob(JobParameters params) {
        executor.execute(() -> {
            StudioAccount.get(this).checkBlocking(false);
            jobFinished(params, false);
        });
        return true;
    }
    @Override public boolean onStopJob(JobParameters params) { return true; }
    @Override public void onDestroy() { executor.shutdown(); super.onDestroy(); }
}
