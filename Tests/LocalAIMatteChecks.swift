import Foundation
import CoreImage
import CoreML

/// No real model is downloaded or installed by these checks. URLProtocol owns
/// every request, and all storage is in one disposable temporary directory.
private final class FakeModelProtocol: URLProtocol {
    enum Fixture { case short, oversized, invalidResponse, delayed }
    static var fixture: Fixture = .short
    private static let lock = NSLock()
    private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        let fixture = Self.fixture
        var headers = ["Content-Length": String(LocalAIMatte.modelDownloadBytes), "Content-Type": "application/octet-stream", "ETag": "\"\(LocalAIMatteDownloadPolicy.publishedMD5)\""]
        if fixture == .invalidResponse { headers["Content-Type"] = "text/html" }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture == .delayed { return }
        let bytes = fixture == .oversized ? Int(LocalAIMatte.modelDownloadBytes) + 1 : 4096
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: bytes))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct LocalAIMatteChecks {
    static func rejected(_ work: () throws -> Void) {
        do { try work(); preconditionFailure("Invalid input was accepted") } catch {}
    }
    static func awaitStatus(_ service: LocalAIMatte, _ predicate: (LocalAIMatteStatus) -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(service.status) && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        precondition(predicate(service.status), "Timed out: \(service.status.message)")
    }
    static func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes[0]
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("netvista-ai-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeModelProtocol.self]
        let service = LocalAIMatte(storageDirectory: root, sessionConfiguration: configuration)
        let unrelatedFile = root.appendingPathComponent("user-owned-file.txt")
        try Data("preserve".utf8).write(to: unrelatedFile)
        precondition(service.status.phase == .notInstalled && !service.status.isInstalled)
        precondition(FakeModelProtocol.requests == 0, "Startup must never download the optional model")
        let frame = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        precondition(service.foregroundMask(for: frame) == nil)
        precondition(FakeModelProtocol.requests == 0, "Inference must never start a download")

        let validHeaders = ["Content-Length": String(LocalAIMatte.modelDownloadBytes), "Content-Type": "application/octet-stream", "ETag": "\"\(LocalAIMatteDownloadPolicy.publishedMD5)\""]
        try LocalAIMatteDownloadPolicy.validate(response: HTTPURLResponse(url: LocalAIMatteDownloadPolicy.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: validHeaders)!)
        for url in [URL(string: "http://ml-assets.apple.com/model.mlmodel")!, URL(string: "https://example.com/model.mlmodel")!, URL(string: "https://ml-assets.apple.com/other.mlmodel")!] {
            rejected { try LocalAIMatteDownloadPolicy.validate(response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: validHeaders)!) }
        }
        for status in [206, 301, 404, 500] {
            rejected { try LocalAIMatteDownloadPolicy.validate(response: HTTPURLResponse(url: LocalAIMatteDownloadPolicy.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: validHeaders)!) }
        }
        for header in ["Content-Length", "Content-Type", "ETag"] {
            var changed = validHeaders; changed[header] = "wrong"
            rejected { try LocalAIMatteDownloadPolicy.validate(response: HTTPURLResponse(url: LocalAIMatteDownloadPolicy.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: changed)!) }
        }
        for length in [0, 32, Int(LocalAIMatte.modelDownloadBytes) - 1, Int(LocalAIMatte.modelDownloadBytes), Int(LocalAIMatte.modelDownloadBytes) + 1] {
            rejected { try LocalAIMatteDownloadPolicy.validate(data: Data(repeating: 0, count: length)) }
        }

        for fixture in [FakeModelProtocol.Fixture.short, .oversized, .invalidResponse] {
            FakeModelProtocol.fixture = fixture
            service.download()
            awaitStatus(service) { $0.phase == .failed }
            precondition(!service.status.isInstalled && service.foregroundMask(for: frame) == nil)
            precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("DeepLabV3FP16-v1.3").path), "Invalid download must never be installed")
        }
        FakeModelProtocol.fixture = .delayed
        let before = FakeModelProtocol.requests
        service.download(); service.download()
        awaitStatus(service) { _ in FakeModelProtocol.requests == before + 1 }
        precondition(service.status.phase == .downloading && service.status.isBusy)
        service.cancelDownload()
        precondition(service.status.phase == .notInstalled && !service.status.isBusy)
        service.download()
        awaitStatus(service) { _ in FakeModelProtocol.requests == before + 2 }
        service.removeModel()
        awaitStatus(service) { $0.phase == .notInstalled && $0.message.contains("removed") }
        precondition(!service.status.isInstalled)
        precondition(FileManager.default.fileExists(atPath: unrelatedFile.path), "Remove must preserve unrelated files")

        let invalidInstall = root.appendingPathComponent("DeepLabV3FP16-v1.3", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidInstall, withIntermediateDirectories: false)
        try Data("{\"version\":1}".utf8).write(to: invalidInstall.appendingPathComponent("receipt.json"))
        let requestsBeforeLoad = FakeModelProtocol.requests
        let badInstallService = LocalAIMatte(storageDirectory: root, sessionConfiguration: configuration)
        awaitStatus(badInstallService) { $0.phase == .failed }
        precondition(!badInstallService.status.isInstalled && FakeModelProtocol.requests == requestsBeforeLoad, "A broken installation cannot become ready or download a repair without consent")
        badInstallService.removeModel()
        awaitStatus(badInstallService) { $0.phase == .notInstalled && $0.message.contains("removed") }
        precondition(!FileManager.default.fileExists(atPath: invalidInstall.path) && FileManager.default.fileExists(atPath: unrelatedFile.path))

#if LOCAL_AI_MATTE_TESTING
        // Hold a prediction on the serial renderer queue while Remove is
        // pending. Neither Cancel nor Download may cancel that exact deletion,
        // and its old result must not publish "ready" with a fresh token.
        try FileManager.default.createDirectory(at: invalidInstall, withIntermediateDirectories: false)
        try Data("placeholder".utf8).write(to: invalidInstall.appendingPathComponent("test-data"))
        let started = DispatchSemaphore(value: 0), continuePrediction = DispatchSemaphore(value: 0)
        let reported = DispatchSemaphore(value: 0), releaseQueue = DispatchSemaphore(value: 0)
        service.testingHoldStalePrediction(started: started, continuePrediction: continuePrediction, reported: reported, releaseQueue: releaseQueue)
        precondition(started.wait(timeout: .now() + 2) == .success)
        let requestsBeforeRemoval = FakeModelProtocol.requests
        service.removeModel()
        precondition(service.status.isBusy && service.status.phase == .installing && !service.status.isInstalled)
        service.cancelDownload(); service.download(); service.removeModel()
        precondition(service.status.isBusy && service.status.message.contains("Removing"), "Cancel/Download must not invalidate a queued removal")
        precondition(FakeModelProtocol.requests == requestsBeforeRemoval, "Download must stay disabled until removal completes")
        continuePrediction.signal()
        precondition(reported.wait(timeout: .now() + 2) == .success)
        precondition(service.status.isBusy && !service.status.isInstalled && service.status.message.contains("Removing"), "Stale prediction must not resurrect a removed model")
        releaseQueue.signal()
        awaitStatus(service) { $0.phase == .notInstalled && $0.message.contains("removed") }
        precondition(!FileManager.default.fileExists(atPath: invalidInstall.path) && FileManager.default.fileExists(atPath: unrelatedFile.path))
#endif

        let labels = try MLMultiArray(shape: [2, 3], dataType: .int32)
        for (index, value) in [15, 0, 7, 0, 15, 20].enumerated() { labels[index] = NSNumber(value: value) }
        let mask = try LocalAIMatteMask.image(labels: labels, extent: CGRect(x: 0, y: 0, width: 3, height: 2))
        let samples = [pixel(mask, 0, 1), pixel(mask, 1, 0), pixel(mask, 0, 0), pixel(mask, 1, 1)]
        precondition(samples[0] == 255 && samples[1] == 255, "Top-down model labels must map to upright CI frames: \(samples)")
        precondition(pixel(mask, 2, 1) == 0 && pixel(mask, 2, 0) == 0, "Only label15 is a person; car/monitor are not person confidence")
        let offset = CGRect(x: 17, y: -30, width: 960, height: 1920)
        let offsetMask = try LocalAIMatteMask.image(labels: labels, extent: offset)
        precondition(offsetMask.extent == offset, "Mask must cover the whole frame, not center crop")
        let floating = try MLMultiArray(shape: [2, 3], dataType: .float32)
        rejected { _ = try LocalAIMatteMask.image(labels: floating, extent: frame.extent) }
        let oversized = try MLMultiArray(shape: [514, 1], dataType: .int32)
        rejected { _ = try LocalAIMatteMask.image(labels: oversized, extent: frame.extent) }
        let noPerson = try MLMultiArray(shape: [2, 3], dataType: .int32)
        for index in 0..<noPerson.count { noPerson[index] = 7 }
        do {
            _ = try LocalAIMatteMask.image(labels: noPerson, extent: frame.extent)
            preconditionFailure("Missing person must fall back, not erase the frame with an all-black mask")
        } catch LocalAIMatteError.noPersonDetected {} catch { preconditionFailure("Missing person must have an actionable diagnostic") }
        for bad in [CGRect.zero, CGRect.infinite, CGRect(x: 0, y: 0, width: 65_536, height: 1)] {
            rejected { _ = try LocalAIMatteMask.image(labels: labels, extent: bad) }
        }
        precondition(service.foregroundMask(for: CIImage.empty()) == nil)
        print("PASS: no automatic downloads/uploads, fixed HTTPS/version policy, corrupt/truncated/oversized download rejection, bounded transfer, duplicate download guard, cancellation/removal, offline/no-person fallback, VOC person label and upright full-frame masks")
#if LOCAL_AI_MATTE_TESTING
        print("PASS: stale prediction cannot resurrect a removed model; Download/Cancel cannot invalidate pending removal; exact removal preserves unrelated files")
#endif
    }
}
