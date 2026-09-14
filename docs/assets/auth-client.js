import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.4/+esm';

// This is the browser-safe publishable key. Never replace it with a service-role key.
export const SUPABASE_URL = 'https://tsitgxafmtzjgtmiczsq.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable__tAdP-Xsu5Gh2ImdKvOHnw_WVujAfJh';
export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { autoRefreshToken: true, persistSession: true, detectSessionInUrl: true }
});

// Confirmation and password-reset emails always return to the branded account route.
export const authRedirect = 'https://video.netvistastudio.com/account/';
