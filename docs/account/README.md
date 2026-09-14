# NetVista Studio account setup

The account page uses Supabase Auth with the browser-safe publishable key. It never includes a service-role key and it does not store project files in the account database.

## Supabase dashboard settings

In the NetVista Supabase project (`tsitgxafmtzjgtmiczsq`), open **Authentication → URL Configuration** and set:

- **Site URL:** `https://video.netvistastudio.com/`
- **Additional Redirect URLs:** `https://video.netvistastudio.com/account/`

Keep the **Email** provider enabled. Email confirmation is controlled in Supabase, not by a GitHub Pages deployment. The site supports both immediate sign-in when confirmations are disabled and confirmation-required signup when they are enabled. Disabling confirmation means signup does not prove ownership of an email address.

All confirmation and recovery requests use the production account URL above, even when testing the website locally. The redirect must be allowed in Supabase; otherwise Supabase can fall back to its configured Site URL.

## What the page supports

- Email/password sign-in
- New account creation with an optional display name
- Password reset email and a new-password form on return
- Password changes for signed-in users
- Persistent browser sessions and sign-out
- A link back to the native editor download page

The main editor landing page uses the same client and opens this sign-in/create-account flow inline when a visitor chooses **Get the beta**. The Account page remains available as the confirmation and password-reset return route, but it is not required from the main navigation.

The page is intentionally static and can be deployed with GitHub Pages. Supabase handles password storage and token exchange; the site only receives the user session through the official JavaScript client.

Credential fields remain disabled until authentication loads, have no HTML submission names, and use POST forms as a fallback. JavaScript cancels native submissions before loading the remote client. Run the offline regression checks with `node --experimental-vm-modules Tests/web_auth_regression.cjs` from the repository root.
