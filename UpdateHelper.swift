import Cocoa
import Darwin

@main
enum NetVistaUpdateHelper {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        do {
            guard CommandLine.arguments.count == 2 else { throw NetVistaUpdateError.invalidResponse }
            let path = URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
            let plan = try JSONDecoder().decode(NetVistaInstallPlan.self,from:Data(contentsOf:path))
            try plan.validatePaths()
            guard path == plan.planURL else { throw NetVistaUpdateError.invalidResponse }
            let lockURL = plan.target.deletingLastPathComponent().appendingPathComponent("." + plan.target.lastPathComponent + ".update-lock")
            let descriptor = Darwin.open(lockURL.path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
            guard descriptor >= 0 else { throw NetVistaUpdateError.unsafePackage("Could not reserve the app for updating.") }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else { throw NetVistaUpdateError.unsafePackage("Another NetVista Studio update is already installing.") }
            defer { flock(descriptor,LOCK_UN) }
            let deadline = Date().addingTimeInterval(120)
            while kill(plan.parentPID,0) == 0 {
                guard Date() < deadline else {
                    NetVistaUpdateInstaller.discard(plan)
                    throw NetVistaUpdateError.unsafePackage("NetVista Studio did not close. The installed app has not been changed.")
                }
                RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier:NetVistaUpdateInstaller.bundleID)
                .contains(where:{ $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == plan.target.path }) else {
                NetVistaUpdateInstaller.discard(plan)
                throw NetVistaUpdateError.unsafePackage("Another copy of this app is still running. Close it before updating.")
            }
            try NetVistaUpdateInstaller.validateBundle(plan.candidate,tag:plan.expectedTag,installed:plan.target)
            try NetVistaUpdateInstaller.replace(plan)
            var launched: NSRunningApplication?
            do {
                launched = try launch(plan.target,arguments:["--netvista-update-job",plan.planURL.path])
                let readyDeadline = Date().addingTimeInterval(90)
                while Date() < readyDeadline {
                    if (try? String(contentsOf:plan.receipt,encoding:.utf8)) == plan.id.uuidString {
                        // Cleanup failure must never roll back an app that opened.
                        try? FileManager.default.removeItem(at:plan.previous)
                        NetVistaUpdateInstaller.discard(plan)
                        return
                    }
                    if launched?.isTerminated == true { break }
                    RunLoop.current.run(until:Date().addingTimeInterval(0.15))
                }
                throw NetVistaUpdateError.unsafePackage("The updated app did not finish opening.")
            } catch {
                if launched == nil {
                    launched = NSRunningApplication.runningApplications(withBundleIdentifier:NetVistaUpdateInstaller.bundleID)
                        .first { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == plan.target.path }
                }
                if let launched, !launched.isTerminated {
                    launched.terminate()
                    let deadline = Date().addingTimeInterval(15)
                    while !launched.isTerminated && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
                    guard launched.isTerminated else {
                        throw NetVistaUpdateError.unsafePackage("The new app is still running, so it was not replaced again. Your previous app is preserved at \(plan.previous.path).")
                    }
                }
                try NetVistaUpdateInstaller.rollback(plan)
                let args = plan.recoveryManifest.map { ["--netvista-update-recovery",$0.path] } ?? []
                _ = try launch(plan.target,arguments:args)
                NetVistaUpdateInstaller.discard(plan)
                throw NetVistaUpdateError.unsafePackage("The update could not open, so your previous app was restored and reopened. \(error.localizedDescription)")
            }
        } catch {
            let alert = NSAlert(); alert.messageText = "NetVista Studio update could not finish"
            alert.informativeText = error.localizedDescription; alert.addButton(withTitle:"OK")
            NSApp.activate(ignoringOtherApps:true); alert.runModal()
        }
    }
    static func launch(_ app: URL, arguments: [String]) throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration(); config.arguments = arguments
        config.activates = true; config.createsNewApplicationInstance = true
        var result: Result<NSRunningApplication, Error>?
        NSWorkspace.shared.openApplication(at:app,configuration:config) { running,error in
            if let running { result = .success(running) }
            else { result = .failure(error ?? NetVistaUpdateError.invalidResponse) }
        }
        let deadline = Date().addingTimeInterval(45)
        while result == nil && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
        guard let result else { throw NetVistaUpdateError.unsafePackage("macOS did not finish opening NetVista Studio.") }
        return try result.get()
    }
}
