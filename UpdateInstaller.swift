import Foundation
import Security
import Darwin

struct NetVistaInstallPlan: Codable {
    let id: UUID
    let target: URL
    let workDirectory: URL
    let jobDirectory: URL
    let parentPID: Int32
    let expectedTag: String
    let recoveryManifest: URL?
    var candidate: URL { workDirectory.appendingPathComponent("NetVista Studio.app") }
    var previous: URL { workDirectory.appendingPathComponent("Previous.app") }
    var receipt: URL { jobDirectory.appendingPathComponent("ready.txt") }
    var planURL: URL { jobDirectory.appendingPathComponent("install.json") }

    func validatePaths() throws {
        let fm = FileManager.default
        guard target.isFileURL, target.pathExtension == "app", target.pathComponents.count > 2,
              target.path == target.standardizedFileURL.resolvingSymlinksInPath().path,
              workDirectory.path == target.deletingLastPathComponent().appendingPathComponent(".netvista-update-" + id.uuidString).path,
              jobDirectory.path == NetVistaUpdateInstaller.cacheRoot.appendingPathComponent(id.uuidString).path,
              workDirectory.path == workDirectory.resolvingSymlinksInPath().path,
              jobDirectory.path == jobDirectory.resolvingSymlinksInPath().path,
              parentPID > 1 else { throw NetVistaUpdateError.unsafePackage("The update installation paths are invalid.") }
        for directory in [workDirectory,jobDirectory] {
            let attrs = try fm.attributesOfItem(atPath:directory.path)
            guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else {
                throw NetVistaUpdateError.unsafePackage("The update staging folder is not private.")
            }
        }
    }
}

enum NetVistaUpdateInstaller {
    static let bundleID = "local.netvista.studio"
    static var cacheRoot: URL {
        #if UPDATER_CHECKS
        return FileManager.default.temporaryDirectory.appendingPathComponent("netvista-updater-checks-" + String(getpid())).standardizedFileURL.resolvingSymlinksInPath()
        #else
        FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("NetVistaStudio/Updates",isDirectory:true).standardizedFileURL.resolvingSymlinksInPath()
        #endif
    }
    static func makeJobDirectory() throws -> URL {
        let url = cacheRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        return url
    }
    static func checkTarget(_ target: URL) throws {
        let fm = FileManager.default
        guard target.isFileURL, target.pathExtension == "app", target.pathComponents.count > 2,
              target.path == target.standardizedFileURL.resolvingSymlinksInPath().path,
              !target.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath:target.path),
              fm.isWritableFile(atPath:target.deletingLastPathComponent().path),
              try bundleInfo(target)["CFBundleIdentifier"] as? String == bundleID else {
            throw NetVistaUpdateError.unsafePackage("NetVista Studio needs to be in a writable folder before it can update itself. Move it from the disk image into Applications, then open that copy and press Update.")
        }
    }
    static func prepare(archive: URL, job: URL, target: URL, tag: String, recoveryManifest: URL?) throws -> NetVistaInstallPlan {
        try checkTarget(target)
        guard let id = UUID(uuidString:job.lastPathComponent), job.path == cacheRoot.appendingPathComponent(id.uuidString).path else {
            throw NetVistaUpdateError.unsafePackage("Invalid update job.")
        }
        try NetVistaUpdateArchive.validate(archive)
        let extracted = job.appendingPathComponent("extracted",isDirectory:true)
        try FileManager.default.createDirectory(at:extracted,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try command("/usr/bin/ditto",["-x","-k",archive.path,extracted.path])
        let source = extracted.appendingPathComponent("NetVista Studio.app")
        try validateBundle(source,tag:tag,installed:target)
        let work = target.deletingLastPathComponent().appendingPathComponent(".netvista-update-" + id.uuidString)
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            let plan = NetVistaInstallPlan(id:id,target:target,workDirectory:work,jobDirectory:job,
                                          parentPID:ProcessInfo.processInfo.processIdentifier,expectedTag:tag,recoveryManifest:recoveryManifest)
            try plan.validatePaths()
            try FileManager.default.copyItem(at:source,to:plan.candidate)
            try validateBundle(plan.candidate,tag:tag,installed:target)
            try JSONEncoder().encode(plan).write(to:plan.planURL,options:.atomic)
            return plan
        } catch { try? FileManager.default.removeItem(at:work); throw error }
    }
    static func validateBundle(_ url: URL, tag: String, installed: URL) throws {
        let info = try bundleInfo(url), current = try bundleInfo(installed)
        guard info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleExecutable"] as? String == "NetVistaStudio",
              info["NetVistaReleaseTag"] as? String == tag,
              (info["NetVistaInPlaceUpdaterVersion"] as? Int ?? 0) >= 1,
              NetVistaVersion(tag) > NetVistaVersion(current["NetVistaReleaseTag"] as? String ?? "0"),
              FileManager.default.isExecutableFile(atPath:url.appendingPathComponent("Contents/MacOS/NetVistaStudio").path) else {
            throw NetVistaUpdateError.unsafePackage("The package does not contain the expected newer NetVista Studio app with restart support.")
        }
        let minimum = info["LSMinimumSystemVersion"] as? String ?? "11.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard NetVistaVersion(minimum) <= NetVistaVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
            throw NetVistaUpdateError.unsafePackage("This update requires macOS \(minimum) or later.")
        }
        let architecture = try command("/usr/bin/lipo",["-archs",url.appendingPathComponent("Contents/MacOS/NetVistaStudio").path])
        #if arch(arm64)
        let requiredArchitecture = "arm64"
        #else
        let requiredArchitecture = "x86_64"
        #endif
        guard architecture.split(whereSeparator: { $0.isWhitespace }).contains(Substring(requiredArchitecture)) else {
            throw NetVistaUpdateError.unsafePackage("This update is not built for this Mac's processor.")
        }
        let newTeam = try verifySignature(url)
        let oldTeam = try verifySignature(installed)
        // Existing public betas are ad-hoc signed. Once installed with Developer ID,
        // future packages must retain that same identity (no signing downgrade).
        if let oldTeam, newTeam != oldTeam {
            throw NetVistaUpdateError.unsafePackage("The update was not signed by the developer of the installed app.")
        }
    }
    static func bundleInfo(_ url: URL) throws -> [String:Any] {
        let data = try Data(contentsOf:url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any] else {
            throw NetVistaUpdateError.unsafePackage("The application metadata is damaged.")
        }
        return info
    }
    static func verifySignature(_ url: URL) throws -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL,[],&code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,SecCSFlags(rawValue:kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),nil) == errSecSuccess else {
            throw NetVistaUpdateError.unsafePackage("The update's application signature is invalid.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&information) == errSecSuccess else {
            throw NetVistaUpdateError.unsafePackage("The update's signing identity could not be read.")
        }
        return (information as? [String:Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
    @discardableResult
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NetVistaUpdateError.unsafePackage("Could not prepare the update. " + String(decoding:output.prefix(1500),as:UTF8.self))
        }
        return String(decoding:output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func startHelper(_ plan: NetVistaInstallPlan) throws {
        try plan.validatePaths()
        let bundled = plan.target.appendingPathComponent("Contents/Helpers/NetVistaUpdateHelper")
        let helper = plan.jobDirectory.appendingPathComponent("NetVistaUpdateHelper")
        try FileManager.default.copyItem(at:bundled,to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let process = Process(); process.executableURL = helper; process.arguments = [plan.planURL.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    /// Both renames are on the same volume. If the second fails, restore the old app.
    /// Launch confirmation is a separate phase: the backup remains until then.
    static func replace(_ plan: NetVistaInstallPlan, move: (URL,URL) throws -> Void = { try FileManager.default.moveItem(at:$0,to:$1) }) throws {
        try plan.validatePaths()
        guard !FileManager.default.fileExists(atPath:plan.previous.path) else {
            throw NetVistaUpdateError.unsafePackage("An earlier installation already exists in this staging folder.")
        }
        try move(plan.target,plan.previous)
        do { try move(plan.candidate,plan.target) }
        catch {
            do { try move(plan.previous,plan.target) }
            catch { throw NetVistaUpdateError.unsafePackage("The update could not finish. Your previous app is preserved at \(plan.previous.path).") }
            throw error
        }
    }
    static func rollback(_ plan: NetVistaInstallPlan) throws {
        try plan.validatePaths()
        let failed = plan.workDirectory.appendingPathComponent("Failed.app")
        try FileManager.default.moveItem(at:plan.target,to:failed)
        do { try FileManager.default.moveItem(at:plan.previous,to:plan.target) }
        catch {
            try? FileManager.default.moveItem(at:failed,to:plan.target)
            throw NetVistaUpdateError.unsafePackage("Your previous app is preserved at \(plan.previous.path).")
        }
    }
    static func discard(_ plan: NetVistaInstallPlan) {
        guard (try? plan.validatePaths()) != nil else { return }
        // Never remove a recoverable previous application after a partial failure.
        guard !FileManager.default.fileExists(atPath:plan.previous.path) else { return }
        try? FileManager.default.removeItem(at:plan.workDirectory)
        try? FileManager.default.removeItem(at:plan.jobDirectory)
    }
}

/// Inspect the ZIP central directory before extraction. Releases are small enough
/// for regular ZIP; encrypted archives, symlinks, traversal and ZIP64 are rejected.
enum NetVistaUpdateArchive {
    static func validate(_ url: URL) throws {
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        func invalid() -> Error { NetVistaUpdateError.unsafePackage("The update archive is invalid or contains unsupported paths.") }
        func number(_ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, offset <= data.count-count else { throw invalid() }
            return (0..<count).reduce(UInt64(0)) { $0 | UInt64(data[offset+$1]) << (8*$1) }
        }
        guard data.count >= 22 else { throw invalid() }
        var end: Int?
        for index in stride(from:data.count-22,through:max(0,data.count-65_557),by:-1) {
            if try number(index,4) == 0x06054b50, index+22+Int(try number(index+20,2)) == data.count { end = index; break }
        }
        guard let end, try number(end+4,2) == 0, try number(end+6,2) == 0 else { throw invalid() }
        let entries = Int(try number(end+10,2)), start = Int(try number(end+16,4)), size = Int(try number(end+12,4))
        guard entries > 0, entries < 65535, start+size == end, try number(end+8,2) == UInt64(entries) else { throw invalid() }
        var cursor = start, expanded: UInt64 = 0, names = Set<String>()
        for _ in 0..<entries {
            guard try number(cursor,4) == 0x02014b50 else { throw invalid() }
            let flags = try number(cursor+8,2), mode = (try number(cursor+38,4)) >> 16
            guard [UInt64(0),0o100000,0o040000].contains(mode & 0o170000) else { throw invalid() }
            let length = Int(try number(cursor+28,2)), extra = Int(try number(cursor+30,2)), comment = Int(try number(cursor+32,2))
            let next = cursor+46+length+extra+comment
            guard next <= end, flags & 1 == 0, mode & 0o170000 != 0o120000, try number(cursor+34,2) == 0 else { throw invalid() }
            guard let name = String(data:data[(cursor+46)..<(cursor+46+length)],encoding:.utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }),
                  !name.split(separator:"/",omittingEmptySubsequences:false).contains(".."),
                  !name.split(separator:"/").contains("."),
                  name.hasPrefix("NetVista Studio.app/") || name.hasPrefix("__MACOSX/"),
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalid() }
            expanded += try number(cursor+24,4)
            guard expanded <= 6_000_000_000 else { throw invalid() }
            // Check the local header name too, so an archive cannot disagree about
            // where its payload is written.
            let local = Int(try number(cursor+42,4)), localLength = Int(try number(local+26,2))
            guard local < start, try number(local,4) == 0x04034b50, localLength == length,
                  local+30+localLength <= start,
                  data[(local+30)..<(local+30+localLength)] == data[(cursor+46)..<(cursor+46+length)] else { throw invalid() }
            cursor = next
        }
        guard cursor == end else { throw invalid() }
    }
}
