import copy
import unittest

from netvista.account import Account, AuthFailure, CHECK_INTERVAL


class Store:
    data = None
    def load(self): return copy.deepcopy(self.data)
    def save(self, data): self.data = copy.deepcopy(data)
    def clear(self): self.data = None


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.now = 10_000
        self.store, self.calls, self.replies = Store(), [], []
        def transport(path, body=None, token=None):
            self.calls.append((path, body, token))
            result = self.replies.pop(0)
            if isinstance(result, Exception): raise result
            return copy.deepcopy(result)
        self.account = Account(store=self.store, transport=transport, clock=lambda: self.now)
        self.user = {"id": "user-1", "email": "person@example.invalid"}

    def session(self, expiry=20_000, refresh="refresh-1"):
        return {"access_token": "access", "refresh_token": refresh,
                "expires_at": expiry, "user": self.user, "unused_field": "not-stored"}

    def login(self, remember=True):
        self.replies = [self.session(), self.user]
        self.account.sign_in("person@example.invalid", "not-a-real-password", remember)
        self.assertIsNotNone(self.account.session)

    def test_login_and_exact_interval(self):
        self.login()
        self.assertNotIn("not-a-real-password", str(self.store.data))
        self.assertNotIn("unused_field", self.store.data)
        self.assertEqual(self.calls[-1][0], "user")
        self.now += CHECK_INTERVAL - 1
        self.account.check()
        self.assertEqual(len(self.calls), 2)
        self.now += 1
        self.replies = [self.user]
        self.account.check()
        self.assertEqual(len(self.calls), 3)

    def test_offline_and_retry(self):
        self.login()
        for error in [OSError("offline"), AuthFailure(429), AuthFailure(500)]:
            self.replies = [error]
            self.account.check(force=True)
            self.assertIsNotNone(self.account.session)
            self.assertIsNotNone(self.store.data)
            self.assertFalse(self.account.invalidated)
        self.now += 59; self.account.check()
        self.now += 1; self.replies = [self.user]; self.account.check()
        self.assertFalse(self.replies)

    def test_refresh_and_restart(self):
        self.login()
        self.now = 20_001
        self.replies = [self.session(30_000, "rotated"), self.user]
        self.account.check()
        self.assertEqual(self.store.data["refresh_token"], "rotated")
        self.account.session = None
        self.replies = [self.user]
        self.account.start()
        self.assertIsNotNone(self.account.last_verified)

    def test_deleted_or_revoked(self):
        self.login()
        self.replies = [AuthFailure(403, "user_not_found")]
        self.account.check(force=True)
        self.assertTrue(self.account.invalidated)
        self.assertIsNone(self.account.session)
        self.assertIsNone(self.store.data)
        self.login()
        self.replies = [AuthFailure(401, "bad_jwt"), AuthFailure(400, "refresh_token_not_found")]
        self.account.check(force=True)
        self.assertTrue(self.account.invalidated)

    def test_bad_password_and_session_only(self):
        self.replies = [AuthFailure(400, "invalid_credentials")]
        self.account.sign_in("person@example.invalid", "bad")
        self.assertIsNone(self.account.session)
        self.login(False)
        self.assertIsNone(self.store.data)
        self.replies = [{}]; self.account.sign_out()
        self.assertIsNone(self.account.session)

    def test_storage_failure_never_saves_plaintext(self):
        class Broken(Store):
            def save(self, data): raise OSError("locked")
        self.account.store = Broken()
        self.login()
        self.assertTrue(self.account.storage_warning)
        self.assertIn("Secure storage is unavailable", self.account.status)


if __name__ == "__main__": unittest.main()
