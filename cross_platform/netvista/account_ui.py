from PySide6.QtCore import QObject, QThread, QTimer, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QCheckBox, QDialog, QLabel, QLineEdit, QPushButton, QVBoxLayout, QWidget

from .account import Account, ACCOUNT_URL


class AccountJob(QThread):
    result = Signal(object)

    def __init__(self, account, operation):
        super().__init__()
        self.account, self.operation = account, operation

    def run(self):
        try:
            self.operation()
        except Exception:
            self.account.status = "Account connection is unavailable. Your work is safe; please try again."
        self.result.emit(self.account.snapshot())
        self.operation = None  # Release any short-lived password closure.


class AccountController(QObject):
    def __init__(self, window):
        super().__init__(window)
        self.host = window
        self.account = Account()
        self.job = None
        self.state = self.account.snapshot()
        self.dialog = QDialog(window)
        self.dialog.setWindowTitle("Your NetVista account")
        self.dialog.setMinimumWidth(420)
        self.dialog.setStyleSheet("QDialog{background:#1b1d1f;color:#eee} QLabel{color:#d3d6d1} QLineEdit{padding:10px;border:1px solid #4b5149;border-radius:5px;background:#242726;color:white} QPushButton{padding:10px}")
        layout = QVBoxLayout(self.dialog)
        layout.setContentsMargins(32, 28, 32, 28)
        layout.setSpacing(15)
        layout.addWidget(QLabel("NETVISTA / STUDIO ACCOUNT"))
        title = QLabel("A space for your next idea.")
        title.setStyleSheet("font-size:23px;font-weight:600")
        layout.addWidget(title)
        intro = QLabel("Use the same account as the website.\nYour projects stay on this computer.")
        layout.addWidget(intro)
        self.form = QWidget()
        form = QVBoxLayout(self.form)
        form.setContentsMargins(0, 0, 0, 0)
        self.email = QLineEdit(); self.email.setPlaceholderText("you@example.com")
        self.password = QLineEdit(); self.password.setEchoMode(QLineEdit.EchoMode.Password)
        self.password.setPlaceholderText("Your password")
        for text, field in [("Email address", self.email), ("Password", self.password)]:
            label = QLabel(text); label.setBuddy(field); form.addWidget(label); form.addWidget(field)
        self.remember = QCheckBox("Keep me signed in on this device"); self.remember.setChecked(True)
        form.addWidget(self.remember)
        self.submit = QPushButton("Sign in"); self.submit.clicked.connect(self.login); form.addWidget(self.submit)
        self.password.returnPressed.connect(self.login)
        for text, url in [("Create an account", ACCOUNT_URL + "?mode=signup"), ("Forgot password?", ACCOUNT_URL)]:
            button = QPushButton(text); button.clicked.connect(lambda checked=False, url=url: QDesktopServices.openUrl(QUrl(url)))
            form.addWidget(button)
        layout.addWidget(self.form)
        self.identity = QLabel(); self.identity.setWordWrap(True); layout.addWidget(self.identity)
        self.check = QPushButton("Check account now"); self.check.clicked.connect(lambda: self.run(lambda: self.account.check(force=True)))
        self.signout = QPushButton("Sign out on this device"); self.signout.clicked.connect(lambda: self.run(self.account.sign_out))
        layout.addWidget(self.check); layout.addWidget(self.signout)
        self.status = QLabel(); self.status.setWordWrap(True); self.status.setMinimumWidth(350); layout.addWidget(self.status)
        close = QPushButton("Continue to Studio"); close.clicked.connect(self.dialog.reject); layout.addWidget(close)
        self.dialog.finished.connect(self.password.clear)
        self.timer = QTimer(self); self.timer.setInterval(30_000)
        self.timer.timeout.connect(lambda: self.run(self.account.check, quiet=True))
        self.render()

    def start(self):
        self.run(self.account.start, startup=True)
        self.timer.start()

    def run(self, operation, quiet=False, startup=False):
        if self.job is not None:
            return
        if quiet and (not self.state["signed_in"] or self.account.clock() < self.account.next_check):
            return
        self.job = AccountJob(self.account, operation)
        self.job.result.connect(lambda state: self.received(state, startup))
        self.job.finished.connect(self.finished)
        self.form.setEnabled(False); self.check.setEnabled(False); self.signout.setEnabled(False)
        if not quiet:
            self.status.setText("Connecting securely…")
        self.job.start()

    def received(self, state, startup):
        self.state = state
        self.render()
        if state["invalidated"] or (startup and not state["signed_in"]):
            self.show()

    def finished(self):
        self.job.deleteLater(); self.job = None
        self.render()

    def render(self):
        signed = self.state["signed_in"]
        self.form.setVisible(not signed); self.identity.setVisible(signed)
        self.check.setVisible(signed); self.signout.setVisible(signed)
        self.identity.setText(self.state["email"] or "NetVista account")
        self.status.setText(self.state["status"])
        self.form.setEnabled(self.job is None); self.check.setEnabled(self.job is None); self.signout.setEnabled(self.job is None)
        self.host.account_button.setText("Account" if signed else "Sign in")
        self.host.account_button.setToolTip(self.state["status"])

    def login(self):
        if self.job is not None:
            return
        email, password, remember = self.email.text(), self.password.text(), self.remember.isChecked()
        self.password.clear()
        self.run(lambda: self.account.sign_in(email, password, remember))

    def show(self):
        self.dialog.show(); self.dialog.raise_(); self.dialog.activateWindow()

    def stop(self):
        self.timer.stop()
        if self.job:
            # The bounded network worker must finish before Qt destroys it.
            self.job.wait()
