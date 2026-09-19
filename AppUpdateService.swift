import Foundation
import CryptoKit

struct NetVistaReleaseAsset: Decodable, Equatable {
    let name: String
    let downloadURL: URL
    let size: Int64
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
        case digest
    }
}

struct NetVistaRelease: Decodable, Equatable {
    let tag: String
    let name: String?
    let pageURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [NetVistaReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case name
        case pageURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

struct NetVistaAvailableUpdate: Equatable {
    let release: NetVistaRelease
    let asset: NetVistaReleaseAsset
}

enum NetVistaUpdateError: LocalizedError {
    case invalidResponse
    case serverStatus(Int)
    case noDownloadsDirectory
    case missingChecksum
    case downloadedSize(expected: Int64, actual: Int64)
    case checksum(expected: String, actual: String)
    case unsafePackage(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an unreadable update response."
        case .serverStatus(let status):
            return "GitHub could not check for updates (HTTP \(status))."
        case .noDownloadsDirectory:
            return "The Downloads folder could not be found."
        case .missingChecksum:
            return "GitHub did not publish a SHA-256 safety checksum for this update."
        case .downloadedSize(let expected, let actual):
            return "The update download was incomplete (expected \(expected) bytes, received \(actual))."
        case .checksum(let expected, let actual):
            return "The update did not pass its safety check. Expected \(expected), received \(actual)."
        case .unsafePackage(let reason): return reason
        }
    }
}

/// GitHub release discovery and verification, shared by the app-wide updater.
final class AppUpdateService {
    static let releasesURL = URL(string: "https://api.github.com/repos/user1994g/videoediterNetVistaStudio.github.io/releases?per_page=30")!

    let currentTag: String
    private let session: URLSession

    init(
        currentTag: String = Bundle.main.object(forInfoDictionaryKey: "NetVistaReleaseTag") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0",
        session: URLSession = .shared
    ) {
        self.currentTag = currentTag
        self.session = session
    }

    func checkForUpdate(completion: @escaping (Result<NetVistaAvailableUpdate?, Error>) -> Void) {
        var request = URLRequest(url: Self.releasesURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NetVistaStudio/\(currentTag)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(NetVistaUpdateError.invalidResponse)); return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(NetVistaUpdateError.serverStatus(http.statusCode))); return
            }
            do {
                let releases = try JSONDecoder().decode([NetVistaRelease].self, from: data)
                completion(.success(Self.bestUpdate(in: releases, currentTag: self.currentTag, platform: "macOS")))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func download(
        _ update: NetVistaAvailableUpdate,
        to directory: URL,
        progress: @escaping (Double) -> Void = { _ in },
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> NetVistaUpdateDownload? {
        guard Self.isTrustedDownload(update.asset.downloadURL), update.asset.size > 0,
              update.asset.size <= 2_000_000_000 else {
            completion(.failure(NetVistaUpdateError.unsafePackage("The release has an invalid download address or package size."))); return nil
        }
        guard let expected = Self.expectedSHA256(update.asset.digest) else {
            completion(.failure(NetVistaUpdateError.missingChecksum)); return nil
        }
        var request = URLRequest(url: update.asset.downloadURL)
        request.timeoutInterval = 120
        request.setValue("NetVistaStudio/\(currentTag)", forHTTPHeaderField: "User-Agent")
        let transfer = NetVistaUpdateDownload(expectedSize:update.asset.size,progress:progress) { result in
            do {
                let temporaryURL = try result.get()
                defer { try? FileManager.default.removeItem(at:temporaryURL) }
                try Self.verifyDownload(temporaryURL,size:update.asset.size,expected:expected)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
        transfer.start(request); return transfer
    }

    static func bestUpdate(
        in releases: [NetVistaRelease],
        currentTag: String,
        platform: String
    ) -> NetVistaAvailableUpdate? {
        let current = NetVistaVersion(currentTag)
        return releases
            .filter { !$0.draft && NetVistaVersion($0.tag) > current }
            .compactMap { release -> NetVistaAvailableUpdate? in
                guard let asset = release.assets.first(where: { assetMatches($0.name, platform: platform) && architectureMatches($0.name, platform:platform) }) else { return nil }
                return NetVistaAvailableUpdate(release: release, asset: asset)
            }
            .max { NetVistaVersion($0.release.tag) < NetVistaVersion($1.release.tag) }
    }

    static func assetMatches(_ name: String, platform: String) -> Bool {
        let lower = name.lowercased()
        switch platform.lowercased() {
        case "macos", "darwin": return lower.contains("-macos-") && lower.hasSuffix(".zip")
        case "windows": return lower.contains("-windows-") && lower.hasSuffix(".zip")
        case "linux": return lower.contains("-linux-") && (lower.hasSuffix(".tar.gz") || lower.hasSuffix(".zip"))
        default: return false
        }
    }

    static func architectureMatches(_ name: String, platform: String) -> Bool {
        guard ["macos","darwin"].contains(platform.lowercased()) else { return true }
        let lower = name.lowercased()
        #if arch(arm64)
        return !lower.contains("x86_64") && !lower.contains("x64") && !lower.contains("intel")
        #else
        return !lower.contains("arm64") && !lower.contains("aarch64")
        #endif
    }
    static func isTrustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.port == nil && url.path.hasPrefix("/user1994g/videoediterNetVistaStudio.github.io/releases/download/")
    }
    static func expectedSHA256(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "sha256", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return parts[1]
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verifyDownload(_ url: URL, size: Int64, expected: String) throws {
        let actualSize = Int64(try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
        guard actualSize == size else { throw NetVistaUpdateError.downloadedSize(expected:size,actual:actualSize) }
        let actual = try sha256(of:url)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else { throw NetVistaUpdateError.checksum(expected:expected,actual:actual) }
    }

}

struct NetVistaVersion: Comparable {
    let core: [Int]
    let prerelease: [String]?

    init(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "v" || $0 == "V" }).split(separator:"+",maxSplits:1).first ?? ""
        let halves = cleaned.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        core = halves.first?.split(separator: ".").map { Int($0) ?? 0 } ?? [0]
        prerelease = halves.count > 1 ? halves[1].split(separator: ".").map(String.init) : nil
    }

    static func < (lhs: NetVistaVersion, rhs: NetVistaVersion) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (.some(let left), .some(let right)):
            for index in 0..<max(left.count, right.count) {
                if index >= left.count { return true }
                if index >= right.count { return false }
                let l = left[index], r = right[index]
                if l == r { continue }
                if let li = Int(l), let ri = Int(r) { return li < ri }
                if Int(l) != nil { return true }
                if Int(r) != nil { return false }
                return l.localizedStandardCompare(r) == .orderedAscending
            }
            return false
        }
    }
    static func == (lhs: NetVistaVersion, rhs: NetVistaVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A serial delegate queue owns completion/cancellation and byte progress.
final class NetVistaUpdateDownload: NSObject, URLSessionDownloadDelegate {
    private let expectedSize: Int64
    private let progress: (Double) -> Void
    private var completion: ((Result<URL, Error>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    init(expectedSize: Int64, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.expectedSize = expectedSize; self.progress = progress; self.completion = completion
    }
    func start(_ request: URLRequest) {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 1800
        let session = URLSession(configuration:config,delegate:self,delegateQueue:queue)
        self.session = session; task = session.downloadTask(with:request); task?.resume()
    }
    func cancel() { task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedSize { downloadTask.cancel(); return }
        progress(min(1,Double(totalBytesWritten)/Double(expectedSize)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts = ["github.com","release-assets.githubusercontent.com","objects.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", hosts.contains(url.host ?? ""), url.user == nil, url.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            finish(.failure(NetVistaUpdateError.invalidResponse)); return
        }
        // Verification completes synchronously while URLSession's temporary file exists.
        finish(.success(location))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate(); self.session = nil; self.task = nil
    }
    private func finish(_ result: Result<URL, Error>) {
        let callback = completion; completion = nil; callback?(result)
    }
}
