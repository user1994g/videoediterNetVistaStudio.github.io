import Foundation

@main
enum AppUpdateChecks {
    static func reject(_ label: String, _ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection: " + label) }
        catch { print("PASS: rejected " + label) }
    }
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n",stderr); exit(1) }
    }
    static func run() throws {
        let fm = FileManager.default, root = NetVistaUpdateInstaller.cacheRoot
        try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? fm.removeItem(at:root) }
        let current = "v1.4.0-beta.3", next = "v1.4.0-beta.4"
        func expectTag(_ url: URL, _ tag: String) throws {
            let actual = try NetVistaUpdateInstaller.bundleInfo(url)["NetVistaReleaseTag"] as? String
            precondition(actual == tag)
        }
        precondition(NetVistaVersion(current) < NetVistaVersion(next))
        precondition(NetVistaVersion("v1.4.0-beta.9") < NetVistaVersion("v1.4.0-beta.10"))
        precondition(NetVistaVersion("v1.4.0-beta.10") < NetVistaVersion("v1.4.0"))
        precondition(NetVistaVersion("v1.4.0+build.10") == NetVistaVersion("1.4"))
        let downloadURL = URL(string:"https://github.com/user1994g/videoediterNetVistaStudio.github.io/releases/download/v1.4.0-beta.4/NetVista-Studio-macOS.zip")!
        precondition(AppUpdateService.isTrustedDownload(downloadURL))
        precondition(!AppUpdateService.isTrustedDownload(URL(string:"http://github.com/user1994g/videoediterNetVistaStudio.github.io/releases/download/a.zip")!))
        precondition(!AppUpdateService.isTrustedDownload(URL(string:"https://github.com/other/repository/releases/download/a.zip")!))
        precondition(AppUpdateService.expectedSHA256("sha256:" + String(repeating:"g",count:64)) == nil)
        let asset = NetVistaReleaseAsset(name:"NetVista-Studio-macOS-test.zip",downloadURL:downloadURL,size:3,digest:nil)
        func release(_ tag: String, draft: Bool = false, assets: [NetVistaReleaseAsset] = [asset]) -> NetVistaRelease {
            NetVistaRelease(tag:tag,name:tag,pageURL:downloadURL,draft:draft,prerelease:tag.contains("beta"),assets:assets)
        }
        let releases = [release(current),release(next),release("v99.0",draft:true),release("v100.0",assets:[])]
        precondition(AppUpdateService.bestUpdate(in:releases,currentTag:current,platform:"macOS")?.release.tag == next)
        precondition(AppUpdateService.bestUpdate(in:releases,currentTag:next,platform:"macOS") == nil)
        print("PASS: beta/final comparison, metadata, release filtering and trusted URLs")

        let bytes = root.appendingPathComponent("bytes")
        try Data("abc".utf8).write(to:bytes)
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try AppUpdateService.verifyDownload(bytes,size:3,expected:hash)
        reject("truncated download") { try AppUpdateService.verifyDownload(bytes,size:4,expected:hash) }
        reject("wrong checksum") { try AppUpdateService.verifyDownload(bytes,size:3,expected:String(repeating:"0",count:64)) }

        func app(_ parent: URL, _ tag: String, id: String = NetVistaUpdateInstaller.bundleID) throws -> URL {
            let url = parent.appendingPathComponent("NetVista Studio.app")
            let macos = url.appendingPathComponent("Contents/MacOS")
            try fm.createDirectory(at:macos,withIntermediateDirectories:true)
            try fm.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[0]),to:macos.appendingPathComponent("NetVistaStudio"))
            let info: [String:Any] = ["CFBundleIdentifier":id,"CFBundleExecutable":"NetVistaStudio","CFBundlePackageType":"APPL",
                "CFBundleVersion":"1","CFBundleShortVersionString":"1.4.0","NetVistaReleaseTag":tag,"LSMinimumSystemVersion":"11.0","NetVistaInPlaceUpdaterVersion":1]
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
            try NetVistaUpdateInstaller.command("/usr/bin/codesign",["--force","--sign","-",url.path])
            return url
        }
        let installed = try app(root.appendingPathComponent("Installed"),current)
        let source = try app(root.appendingPathComponent("Release"),next)
        let archive = root.appendingPathComponent("release.zip")
        try NetVistaUpdateInstaller.command("/usr/bin/ditto",["-c","-k","--keepParent","--sequesterRsrc",source.path,archive.path])
        try NetVistaUpdateArchive.validate(archive)
        try NetVistaUpdateInstaller.validateBundle(source,tag:next,installed:installed)
        reject("mismatched release version") { try NetVistaUpdateInstaller.validateBundle(source,tag:"v9",installed:installed) }
        let wrongApp = try app(root.appendingPathComponent("Other"),next,id:"other.app")
        reject("different application") { try NetVistaUpdateInstaller.validateBundle(wrongApp,tag:next,installed:installed) }
        let executable = source.appendingPathComponent("Contents/MacOS/NetVistaStudio")
        let handle = try FileHandle(forWritingTo:executable); try handle.seekToEnd(); try handle.write(contentsOf:Data("tampered".utf8)); try handle.close()
        reject("tampered executable signature") { try NetVistaUpdateInstaller.validateBundle(source,tag:next,installed:installed) }
        print("PASS: real ZIP preflight and signed application validation")

        let job = try NetVistaUpdateInstaller.makeJobDirectory()
        let plan = try NetVistaUpdateInstaller.prepare(archive:archive,job:job,target:installed,tag:next,recoveryManifest:nil)
        try NetVistaUpdateInstaller.replace(plan)
        try expectTag(installed,next)
        try expectTag(plan.previous,current)
        try NetVistaUpdateInstaller.rollback(plan)
        try expectTag(installed,current)
        NetVistaUpdateInstaller.discard(plan)
        print("PASS: stage, replace at the same app path, retain backup, rollback")

        let job2 = try NetVistaUpdateInstaller.makeJobDirectory()
        let plan2 = try NetVistaUpdateInstaller.prepare(archive:archive,job:job2,target:installed,tag:next,recoveryManifest:nil)
        reject("failed second rename") {
            try NetVistaUpdateInstaller.replace(plan2,move:{ from,to in
                if from == plan2.candidate { throw CocoaError(.fileWriteOutOfSpace) }
                try fm.moveItem(at:from,to:to)
            })
        }
        try expectTag(installed,current)
        NetVistaUpdateInstaller.discard(plan2)
        print("PASS: installation failure leaves the original app usable")

        // Modify both directory and local names so traversal cannot hide in either.
        var malicious = try Data(contentsOf:archive)
        let original = Data("NetVista Studio.app/".utf8), replacement = Data("../evilx Studio.app/".utf8)
        precondition(original.count == replacement.count)
        while let range = malicious.range(of:original) { malicious.replaceSubrange(range,with:replacement) }
        let maliciousURL = root.appendingPathComponent("traversal.zip"); try malicious.write(to:maliciousURL)
        reject("ZIP traversal") { try NetVistaUpdateArchive.validate(maliciousURL) }
        try Data([1,2,3]).write(to:maliciousURL)
        reject("truncated ZIP") { try NetVistaUpdateArchive.validate(maliciousURL) }
        let symlinkSource = root.appendingPathComponent("Link/NetVista Studio.app")
        try fm.createDirectory(at:symlinkSource,withIntermediateDirectories:true)
        try fm.createSymbolicLink(at:symlinkSource.appendingPathComponent("escape"),withDestinationURL:root)
        let linkZip = root.appendingPathComponent("link.zip")
        try NetVistaUpdateInstaller.command("/usr/bin/ditto",["-c","-k","--keepParent",symlinkSource.path,linkZip.path])
        reject("ZIP symlink") { try NetVistaUpdateArchive.validate(linkZip) }
        print("All updater checks passed; fixture apps and archives removed on exit.")
    }
}
