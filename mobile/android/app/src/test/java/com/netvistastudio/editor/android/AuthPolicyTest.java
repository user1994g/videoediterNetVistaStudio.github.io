package com.netvistastudio.editor.android;

import org.junit.Test;
import static org.junit.Assert.*;

public final class AuthPolicyTest {
    @Test public void transientFailuresKeepSession() {
        assertFalse(AuthPolicy.rejectsSession(0, "")); assertFalse(AuthPolicy.rejectsSession(429, "over_request_rate_limit"));
        assertFalse(AuthPolicy.rejectsSession(500, "unexpected_failure")); assertFalse(AuthPolicy.rejectsSession(503, ""));
    }
    @Test public void deletedOrRevokedAccountsRequireSignIn() {
        assertTrue(AuthPolicy.rejectsSession(401, "bad_jwt")); assertTrue(AuthPolicy.rejectsSession(403, "user_banned"));
        assertTrue(AuthPolicy.rejectsSession(400, "refresh_token_not_found")); assertTrue(AuthPolicy.rejectsSession(400, "session_not_found"));
    }
    @Test public void checksAfter25MinutesWithoutPromptingForPassword() {
        long last = 100000; long expiry = 999999;
        assertFalse(AuthPolicy.due(last + 1000, last, 0, expiry));
        assertTrue(AuthPolicy.due(last + AuthPolicy.CHECK_INTERVAL_MS, last, 0, expiry));
    }
    @Test public void expiredCredentialsRefreshBeforeRegularCheck() { assertTrue(AuthPolicy.due(120000, 119000, 0, 150)); }
    @Test public void offlineRetryDoesNotHammerServer() {
        assertFalse(AuthPolicy.due(120000, 0, 180000, 0)); assertTrue(AuthPolicy.due(180000, 0, 180000, 0));
    }
}
