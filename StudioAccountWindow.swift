import Cocoa

final class StudioAccountWindow: NSWindowController {
    private let account: StudioAccount
    private let email = NSTextField()
    private let password = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let identity = NSTextField(wrappingLabelWithString: "")
    private let remember = NSButton(checkboxWithTitle: "Keep me signed in on this Mac", target: nil, action: nil)
    private let submit = NSButton(title: "Sign in", target: nil, action: nil)
    private let check = NSButton(title: "Check account now", target: nil, action: nil)
    private let signout = NSButton(title: "Sign out on this Mac", target: nil, action: nil)
    private let credentials = NSStackView()
    private let signedIn = NSStackView()

    init(account: StudioAccount) {
        self.account = account
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 590),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Your NetVista account"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        build(); window.center(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = weight == .regular ? .secondaryLabelColor : .labelColor
        return field
    }
    private func stack(_ stack: NSStackView) {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
    }
    private func build() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1).cgColor
        let column = NSStackView(); stack(column); column.spacing = 18
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 36),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 32)
        ])
        let brand = label("NETVISTA  /  STUDIO ACCOUNT", size: 10, weight: .semibold)
        brand.textColor = .systemRed
        column.addArrangedSubview(brand)
        column.addArrangedSubview(label("A space for your next idea.", size: 25, weight: .semibold))
        column.addArrangedSubview(label("Use the same account as the NetVista website. Your projects stay local, not in your account.", size: 13))
        let divider = NSBox(); divider.boxType = .separator; column.addArrangedSubview(divider)
        stack(credentials); stack(signedIn)
        email.placeholderString = "you@example.com"; email.font = .systemFont(ofSize: 14)
        password.placeholderString = "Your password"; password.font = .systemFont(ofSize: 14)
        email.setAccessibilityLabel("Email address"); password.setAccessibilityLabel("Password")
        credentials.addArrangedSubview(label("Email address", size: 12, weight: .medium))
        credentials.addArrangedSubview(email)
        credentials.addArrangedSubview(label("Password", size: 12, weight: .medium))
        credentials.addArrangedSubview(password)
        remember.state = .on; remember.font = .systemFont(ofSize: 12)
        credentials.addArrangedSubview(remember)
        submit.target = self; submit.action = #selector(login); submit.bezelStyle = .rounded
        submit.keyEquivalent = "\r"; submit.contentTintColor = .white
        credentials.addArrangedSubview(submit)
        let links = NSStackView(); links.spacing = 12
        for (title, action) in [("Create an account", #selector(createAccount)), ("Forgot password?", #selector(recoverPassword))] {
            let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .inline
            links.addArrangedSubview(button)
        }
        credentials.addArrangedSubview(links)
        identity.font = .systemFont(ofSize: 17, weight: .medium); signedIn.addArrangedSubview(identity)
        signedIn.addArrangedSubview(label("Connected to NetVista. Account checks run quietly every 25 minutes while the app is open, and catch up after sleep.", size: 13))
        check.target = self; check.action = #selector(checkNow); check.bezelStyle = .rounded
        signout.target = self; signout.action = #selector(logout); signout.bezelStyle = .rounded
        signedIn.addArrangedSubview(check); signedIn.addArrangedSubview(signout)
        column.addArrangedSubview(credentials); column.addArrangedSubview(signedIn)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.setAccessibilityRole(.staticText); column.addArrangedSubview(status)
        let later = NSButton(title: "Continue to Studio", target: self, action: #selector(dismiss))
        later.bezelStyle = .rounded; later.keyEquivalent = "\u{1b}"; column.addArrangedSubview(later)
        for child in [credentials, signedIn, status, divider] {
            child.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        for field in [email, password] {
            field.widthAnchor.constraint(equalTo: credentials.widthAnchor).isActive = true
            field.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        submit.widthAnchor.constraint(equalTo: credentials.widthAnchor).isActive = true
    }
    func refresh() {
        credentials.isHidden = account.session != nil; signedIn.isHidden = account.session == nil
        identity.stringValue = account.email ?? "NetVista account"
        status.stringValue = account.status
        submit.isEnabled = !account.busy; check.isEnabled = !account.busy
        email.isEnabled = !account.busy; password.isEnabled = !account.busy; remember.isEnabled = !account.busy
        submit.title = account.busy ? "Connecting…" : "Sign in"
        if account.session != nil { password.stringValue = "" }
    }
    func present() { refresh(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func login() {
        let secret = password.stringValue; password.stringValue = ""
        account.signIn(email: email.stringValue, password: secret, remember: remember.state == .on)
    }
    @objc private func logout() { account.signOut() }
    @objc private func checkNow() { account.check(force: true) }
    @objc private func createAccount() { NSWorkspace.shared.open(URL(string: "?mode=signup", relativeTo: StudioAuthConfig.accountURL)!.absoluteURL) }
    @objc private func recoverPassword() { NSWorkspace.shared.open(StudioAuthConfig.accountURL) }
    @objc private func dismiss() { password.stringValue = ""; window?.orderOut(nil) }
}
