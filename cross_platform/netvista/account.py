"""Native account lifecycle. Called serially off the UI thread; never saves passwords."""
from __future__ import annotations

import json
import sys
import time
from urllib.error import HTTPError
from urllib.request import Request, HTTPRedirectHandler, build_opener

AUTH_URL = "https://tsitgxafmtzjgtmiczsq.supabase.co/auth/v1/"
PUBLIC_KEY = "sb_publishable__tAdP-Xsu5Gh2ImdKvOHnw_WVujAfJh"
ACCOUNT_URL = "https://video.netvistastudio.com/account/"
CHECK_INTERVAL = 25 * 60


class AuthFailure(Exception):
    def __init__(self, status, code=""):
        self.status, self.code = status, code
        super().__init__("Authentication request failed")

    @property
    def rejected(self):
        return self.status in (401, 403) or self.code in {
            "user_not_found", "user_banned", "session_not_found", "session_expired",
            "refresh_token_not_found", "refresh_token_already_used", "bad_jwt"}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward credentials to a different endpoint.


def request(path, body=None, token=None):
    headers = {"apikey": PUBLIC_KEY, "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = Request(AUTH_URL + path, headers=headers,
                  data=json.dumps(body).encode() if body is not None else None)
    try:
        with build_opener(NoRedirect()).open(req, timeout=20) as response:
            data = response.read(1024 * 1024)
            return json.loads(data) if data else {}
    except HTTPError as error:
        try:
            data = json.loads(error.read(1024 * 1024))
        except (ValueError, OSError):
            data = {}
        raise AuthFailure(error.code, data.get("error_code", data.get("error", ""))) from None


class SecureStore:
    """Explicit OS backend only. No automatic/plaintext fallback."""
    service, user = "com.netvistastudio.account", "supabase-session"

    def _backend(self):
        if sys.platform == "win32":
            from keyring.backends.Windows import WinVaultKeyring
            return WinVaultKeyring()
        if sys.platform == "darwin":
            from keyring.backends.macOS import Keyring
        else:
            from keyring.backends.SecretService import Keyring
        return Keyring()

    def load(self):
        data = self._backend().get_password(self.service, self.user)
        return json.loads(data) if data else None

    def save(self, session):
        self._backend().set_password(self.service, self.user, json.dumps(session))

    def clear(self):
        from keyring.errors import PasswordDeleteError
        try:
            self._backend().delete_password(self.service, self.user)
        except PasswordDeleteError:
            # Some OS stores use this for both missing entries and other failures.
            if self._backend().get_password(self.service, self.user) is not None:
                raise


class Account:
    def __init__(self, store=None, transport=request, clock=time.time):
        self.store = store if store is not None else SecureStore()
        self.request, self.clock = transport, clock
        self.session = None
        self.remember = True
        self.last_verified = None
        self.next_check = 0
        self.storage_warning = False
        self.invalidated = False
        self.status = "Sign in with your NetVista account. Your projects stay on this computer."

    def _session(self, data):
        if not all(isinstance(data.get(k), str) and data[k] for k in ("access_token", "refresh_token")):
            raise ValueError("Invalid session")
        if not isinstance(data.get("user"), dict) or not data["user"].get("id"):
            raise ValueError("Missing user")
        # Explicit allowlist: no unexpected fields or credentials are persisted.
        return {"access_token": data["access_token"], "refresh_token": data["refresh_token"],
                "expires_at": float(data.get("expires_at") or self.clock() + float(data.get("expires_in", 3600))),
                "user": {"id": data["user"]["id"], "email": data["user"].get("email")}}

    def _persist(self):
        try:
            self.store.save(self.session) if self.remember else self.store.clear()
            self.storage_warning = False
        except Exception:
            self.storage_warning = True

    def start(self):
        try:
            saved = self.store.load()
            if saved:
                self.session = self._session(saved)
        except Exception:
            self.status = "Secure storage is unavailable. You can sign in for this session."
        if self.session:
            self.check(force=True)

    def sign_in(self, email, password, remember=True):
        self.invalidated = False
        if "@" not in email or not password:
            self.status = "Enter your email address and password."
            return
        try:
            self.session = self._session(self.request("token?grant_type=password",
                                         {"email": email.strip(), "password": password}))
            self.remember = remember
            self._persist()
            self.check(force=True)
        except AuthFailure as error:
            self.status = ("Confirm your email before signing in." if error.code == "email_not_confirmed"
                           else "Too many attempts. Please wait before trying again." if error.status == 429
                           else "Could not sign in. Check your email and password.")
        except Exception:
            self.status = "Could not reach NetVista. Check your connection and try again."

    def _refresh(self):
        old = self.session
        new = self._session(self.request("token?grant_type=refresh_token", {"refresh_token": old["refresh_token"]}))
        if new["user"]["id"] != old["user"]["id"]:
            raise AuthFailure(401, "user_not_found")
        self.session = new
        self._persist()

    def check(self, force=False):
        self.invalidated = False
        if not self.session or (not force and self.clock() < self.next_check):
            return
        try:
            refreshed = self.session["expires_at"] <= self.clock() + 60
            if refreshed:
                self._refresh()
            try:
                user = self.request("user", token=self.session["access_token"])
            except AuthFailure as error:
                if refreshed or error.status != 401 or error.code in ("user_not_found", "session_not_found"):
                    raise
                self._refresh()
                user = self.request("user", token=self.session["access_token"])
            if user.get("id") != self.session["user"]["id"]:
                raise AuthFailure(401, "user_not_found")
            self.session["user"] = {"id": user["id"], "email": user.get("email")}
            self._persist()
            self.last_verified = self.clock()
            self.next_check = min(self.clock() + CHECK_INTERVAL, max(self.clock() + 30, self.session["expires_at"] - 60))
            self.status = ("Account verified. Secure storage is unavailable; sign-in may not survive a restart."
                           if self.storage_warning else "Account verified. Next check in 25 minutes—no password needed.")
        except Exception as error:
            if isinstance(error, AuthFailure) and error.rejected:
                self.session = None
                self.last_verified = None
                self.invalidated = True
                self.status = "Your account or session is no longer available. Sign in again. Your open projects are safe."
                try:
                    self.store.clear()
                except Exception:
                    self.status += " Saved sign-in could not be removed from secure storage."
            else:
                self.next_check = self.clock() + 60
                self.status = "Account check postponed: connection unavailable. Your work is safe; we'll retry automatically."

    def sign_out(self):
        token = self.session["access_token"] if self.session else None
        self.session = None
        self.last_verified = None
        self.invalidated = False
        self.status = "Signed out on this device. You can continue editing locally."
        try:
            self.store.clear()
        except Exception:
            self.status += " Saved sign-in could not be cleared from secure storage."
        if token:
            try:
                self.request("logout?scope=local", {}, token=token)
            except Exception:
                pass

    def snapshot(self):
        return {"signed_in": self.session is not None,
                "email": self.session["user"].get("email") if self.session else None,
                "status": self.status, "invalidated": self.invalidated}
