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
        }
    }
}

/// Manual, user-controlled updater backed by the public GitHub Releases feed.
/// It downloads a verified package to Downloads; it never replaces a running
/// application or touches an open project.
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
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        var request = URLRequest(url: update.asset.downloadURL)
        request.timeoutInterval = 120
        request.setValue("NetVistaStudio/\(currentTag)", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request) { temporaryURL, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let temporaryURL else {
                completion(.failure(NetVistaUpdateError.invalidResponse)); return
            }
            do {
                let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
                let actualSize = Int64(values.fileSize ?? 0)
                if update.asset.size > 0, actualSize != update.asset.size {
                    throw NetVistaUpdateError.downloadedSize(expected: update.asset.size, actual: actualSize)
                }
                guard let expected = Self.expectedSHA256(update.asset.digest) else {
                    throw NetVistaUpdateError.missingChecksum
                }
                let actual = try Self.sha256(of: temporaryURL)
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw NetVistaUpdateError.checksum(expected: expected, actual: actual)
                }
                guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                    throw NetVistaUpdateError.noDownloadsDirectory
                }
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                let destination = Self.uniqueDestination(in: downloads, named: update.asset.name)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }.resume()
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
                guard let asset = release.assets.first(where: { assetMatches($0.name, platform: platform) }) else { return nil }
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

    private static func expectedSHA256(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "sha256", parts[1].count == 64 else { return nil }
        return parts[1]
    }

    private static func sha256(of url: URL) throws -> String {
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

    private static func uniqueDestination(in directory: URL, named name: String) -> URL {
        let original = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        for number in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}

private struct NetVistaVersion: Comparable {
    let core: [Int]
    let prerelease: [String]?

    init(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "v" || $0 == "V" })
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
}
