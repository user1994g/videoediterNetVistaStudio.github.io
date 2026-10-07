import Foundation
import CoreImage
import CoreML
import Vision
import CryptoKit

enum LocalAIMattePhase: String {
    case notInstalled, downloading, installing, ready, failed
}

struct LocalAIMatteStatus {
    var phase: LocalAIMattePhase
    var progress: Double = 0
    var message: String
    var isInstalled: Bool = false
    var isRemoving: Bool = false
    var isBusy: Bool { phase == .downloading || phase == .installing }
    var canCancel: Bool { isBusy && !isRemoving }
}

/// Optional, on-device *person segmentation*, not a language model or an online
/// service. A caller must explicitly invoke download(); construction, project
/// loading and inference never cause a network request. Keep conventional keying
/// when a mask is nil (missing model, unsupported frame or prediction failure).
final class LocalAIMatte: NSObject, URLSessionDataDelegate {
    static let shared = LocalAIMatte()
    static let statusDidChange = Notification.Name("NetVistaLocalAIMatteStatusDidChange")
    static let modelName = "DeepLabV3FP16"
    static let modelDownloadBytes: Int64 = 4_342_971
    static let modelInformationURL = URL(string: "https://developer.apple.com/machine-learning/models/")!
    static let modelLicenseURL = URL(string: "https://github.com/tensorflow/tensorflow/blob/master/LICENSE")!
    // Apple's 2020 Core ML model identifies TensorFlow's licence in its embedded
    // metadata. This is NOT the similarly named, research-only MobileViT model.
    static let licenseNotice = "DeepLabV3 by the TensorFlow authors; model distributed by Apple. Apache License 2.0. See the embedded model licence and TensorFlow licence."

    private let root: URL
    private let configuration: URLSessionConfiguration
    private let stateLock = NSLock()
    private let inference = DispatchQueue(label: "com.netvistastudio.ai-matte.inference", qos: .userInitiated)
    private let installer = DispatchQueue(label: "com.netvistastudio.ai-matte.install", qos: .utility)
    private let diskLock = NSLock()
    private var snapshot = LocalAIMatteStatus(phase: .notInstalled, message: "Optional person model is not downloaded.")
    private var operation = UUID()
    private var removing = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var downloadData = Data()
    private var acceptedResponse = false
    private var transferError: Error?
    // Accessed only on the inference queue; model and Vision request are not
    // shared across concurrent preview/export calls.
    private var loadedModel: VNCoreMLModel?
    private var lastLoadError: String?
    private let context = CIContext(options: [.cacheIntermediates: false])

    var status: LocalAIMatteStatus { locked { snapshot } }

    override convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(storageDirectory: support.appendingPathComponent("NetVistaStudio/AIModels", isDirectory: true))
    }

    /// An isolated location/session makes safety and cancellation testable
    /// without downloading a model or modifying a user's installed model.
    init(storageDirectory: URL, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        root = storageDirectory.standardizedFileURL
        configuration = sessionConfiguration
        super.init()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        // Do not compile/read large model files on the main thread at launch.
        if FileManager.default.fileExists(atPath: installedDirectory.path) {
            let token = locked { operation }
            installer.async { [weak self] in self?.checkExistingModel(token: token) }
        }
    }

    private var installedDirectory: URL { root.appendingPathComponent("DeepLabV3FP16-v1.3", isDirectory: true) }

    /// Call only after the user clicks Download and accepts the size/source.
    /// At most one bounded, fixed-URL transfer is active. No URLs come from a
    /// project, effect, model metadata or a server response.
    func download() {
        stateLock.lock()
        guard !snapshot.isBusy, !removing, !snapshot.isInstalled else { stateLock.unlock(); return }
        operation = UUID()
        downloadData = Data(); acceptedResponse = false; transferError = nil
        snapshot = LocalAIMatteStatus(phase: .downloading, message: "Downloading the 4.4 MB model from Apple…")
        let delegates = OperationQueue(); delegates.maxConcurrentOperationCount = 1
        let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
        var request = URLRequest(url: LocalAIMatteDownloadPolicy.url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let newTask = newSession.dataTask(with: request)
        session = newSession; task = newTask
        stateLock.unlock()
        notify(); newTask.resume()
    }

    /// Cancels downloading OR installation. The generation guard stops a late
    /// network/compile callback from installing after Cancel or Remove.
    func cancelDownload() {
        let cancelled: (URLSessionDataTask?, URLSession?) = locked {
            // Removal is an exact user-requested disk operation, not a model
            // installation that Cancel Download should invalidate.
            guard snapshot.isBusy, !removing else { return (nil, nil) }
            operation = UUID()
            let previous = (task, session)
            task = nil; session = nil; downloadData = Data(); transferError = nil
            snapshot = LocalAIMatteStatus(phase: .notInstalled, message: "Model download cancelled. Standard green-screen keying is still available.")
            return previous
        }
        cancelled.0?.cancel(); cancelled.1?.invalidateAndCancel(); notify()
    }

    /// Only NetVista's exact, fixed model directory is removed. No user media,
    /// other models, Application Support root or system ML files are touched.
    func removeModel() {
        let removal: (UUID, URLSessionDataTask?, URLSession?)? = locked {
            guard !removing else { return nil }
            operation = UUID()
            removing = true
            let result = (operation, task, session)
            task = nil; session = nil; downloadData = Data()
            snapshot = LocalAIMatteStatus(phase: .installing, message: "Removing the optional model…", isRemoving: true)
            return result
        }
        guard let removed = removal else { return }
        removed.1?.cancel(); removed.2?.invalidateAndCancel(); notify()
        inference.async { [weak self] in
            guard let self = self else { return }
            self.loadedModel = nil; self.lastLoadError = nil
            self.diskLock.lock(); defer { self.diskLock.unlock() }
            guard self.isCurrent(removed.0) else { return }
            do {
                try self.validateStorageRoot()
                if FileManager.default.fileExists(atPath: self.installedDirectory.path) {
                    try FileManager.default.removeItem(at: self.installedDirectory)
                }
                self.finish(removed.0, status: LocalAIMatteStatus(phase: .notInstalled, message: "Optional model removed. Standard green-screen keying remains available."))
            } catch { self.fail(removed.0, error: error) }
        }
    }

    /// The same deterministic model/mask path is used by preview and export.
    /// Vision uses scaleFill, so a full frame maps back to its entire original
    /// extent (never center-cropping portrait or ultrawide media). Model output
    /// is low-resolution semantic labels: not fine hair matting or every object.
    func foregroundMask(for image: CIImage) -> CIImage? {
        guard LocalAIMatteMask.validExtent(image.extent),
              let token = locked({ snapshot.isInstalled && !removing ? operation : nil }) else { return nil }
        return inference.sync {
            guard locked({ operation == token && snapshot.isInstalled && !removing }) else { return nil }
            if loadedModel == nil {
                do {
                    diskLock.lock(); defer { diskLock.unlock() }
                    try validateInstalledFiles()
                    let model = try MLModel(contentsOf: installedDirectory.appendingPathComponent("model.mlmodelc"), configuration: MLModelConfiguration())
                    try LocalAIMatteDownloadPolicy.validate(model: model)
                    loadedModel = try VNCoreMLModel(for: model)
                } catch {
                    // An invalid installation/device cannot become a "ready"
                    // model simply because the renderer catches its error.
                    fail(token, error: error)
                    return nil
                }
            }
            do {
                guard let model = loadedModel else { return nil }
                let request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFill
                // Explicitly bound preprocessing even for 16K source media.
                let e = image.extent
                let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: 513 / e.width, y: 513 / e.height))
                    .cropped(to: CGRect(x: 0, y: 0, width: 513, height: 513))
                guard let input = context.createCGImage(normalized, from: normalized.extent) else { return nil }
                try VNImageRequestHandler(cgImage: input, orientation: .up, options: [:]).perform([request])
                guard let feature = request.results?.first as? VNCoreMLFeatureValueObservation,
                      let labels = feature.featureValue.multiArrayValue else { throw LocalAIMatteError.invalidPrediction("The model returned no segmentation map.") }
                let mask = try LocalAIMatteMask.image(labels: labels, extent: e)
                let hadDiagnostic = lastLoadError != nil
                lastLoadError = nil
                if hadDiagnostic {
                    finish(token, status: LocalAIMatteStatus(phase: .ready, progress: 1, message: "Person AI model ready. All frames are processed on this Mac.", isInstalled: true))
                }
                // A Remove or replacement request can happen during prediction.
                // Neither its old mask nor its old diagnostic may resurrect the
                // model's ready state under the new operation generation.
                guard locked({ operation == token && snapshot.isInstalled && !removing }) else { return nil }
                return mask
            } catch {
                let message = error.localizedDescription
                // Avoid flooding notifications if a particular frame/device
                // repeatedly fails. Falling back never starts a download.
                if message != lastLoadError {
                    lastLoadError = message
                    finish(token, status: LocalAIMatteStatus(phase: .ready, progress: 1, message: "AI could not process this frame; using standard keying. \(message)", isInstalled: true))
                }
                return nil
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // No redirect can send the download (or credentials) to another host.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        stateLock.lock()
        guard task === dataTask else { stateLock.unlock(); completionHandler(.cancel); return }
        do {
            try LocalAIMatteDownloadPolicy.validate(response: response)
            acceptedResponse = true
            stateLock.unlock(); completionHandler(.allow)
        } catch {
            transferError = error
            stateLock.unlock(); completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateLock.lock()
        guard task === dataTask, acceptedResponse else { stateLock.unlock(); return }
        guard data.count <= Int(Self.modelDownloadBytes) - downloadData.count else {
            transferError = LocalAIMatteError.invalidDownload("The model exceeded its advertised size.")
            stateLock.unlock(); dataTask.cancel(); return
        }
        downloadData.append(data)
        snapshot.progress = Double(downloadData.count) / Double(Self.modelDownloadBytes)
        stateLock.unlock(); notify()
    }

    func urlSession(_ session: URLSession, task completedTask: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        guard task === completedTask else { stateLock.unlock(); return }
        let token = operation, data = downloadData
        let problem = transferError ?? error
        let responseWasAccepted = acceptedResponse
        task = nil; self.session = nil; downloadData = Data()
        stateLock.unlock(); session.finishTasksAndInvalidate()
        if let problem = problem { fail(token, error: problem); return }
        guard responseWasAccepted else { fail(token, error: LocalAIMatteError.invalidDownload("The model server response was not accepted.")); return }
        finish(token, status: LocalAIMatteStatus(phase: .installing, progress: 1, message: "Checking and preparing the local model…"))
        installer.async { [weak self] in self?.install(data: data, token: token) }
    }

    private func install(data: Data, token: UUID) {
        let fileManager = FileManager.default
        let pending = root.appendingPathComponent(".install-\(token.uuidString)", isDirectory: true)
        var compilerOutput: URL?
        defer {
            try? fileManager.removeItem(at: pending)
            if let output = compilerOutput { try? fileManager.removeItem(at: output) }
        }
        do {
            try LocalAIMatteDownloadPolicy.validate(data: data)
            guard isCurrent(token) else { return }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try validateStorageRoot()
            try fileManager.createDirectory(at: pending, withIntermediateDirectories: false)
            let source = pending.appendingPathComponent("model.mlmodel")
            try data.write(to: source, options: .atomic)
            let compiled = try MLModel.compileModel(at: source); compilerOutput = compiled
            guard isCurrent(token) else { return }
            let compiledCopy = pending.appendingPathComponent("model.mlmodelc", isDirectory: true)
            try fileManager.copyItem(at: compiled, to: compiledCopy)
            let model = try MLModel(contentsOf: compiledCopy, configuration: MLModelConfiguration())
            try LocalAIMatteDownloadPolicy.validate(model: model)
            let receipt = try LocalAIMatteReceipt.create(in: pending, source: data)
            try JSONEncoder().encode(receipt).write(to: pending.appendingPathComponent("receipt.json"), options: .atomic)
            try Self.licenseNotice.data(using: .utf8)!.write(to: pending.appendingPathComponent("MODEL-LICENSE.txt"), options: .atomic)

            diskLock.lock(); defer { diskLock.unlock() }
            // Installation is a same-volume atomic rename. Re-check under the
            // state lock so Cancel/Remove cannot interleave with this commit.
            stateLock.lock()
            guard operation == token else { stateLock.unlock(); return }
            do {
                let backup = root.appendingPathComponent(".previous-\(token.uuidString)", isDirectory: true)
                let hadPrevious = fileManager.fileExists(atPath: installedDirectory.path)
                if hadPrevious { try fileManager.moveItem(at: installedDirectory, to: backup) }
                do { try fileManager.moveItem(at: pending, to: installedDirectory) }
                catch {
                    if hadPrevious { try? fileManager.moveItem(at: backup, to: installedDirectory) }
                    throw error
                }
                if hadPrevious { try? fileManager.removeItem(at: backup) }
                snapshot = LocalAIMatteStatus(phase: .ready, progress: 1, message: "Person AI model ready. All frames are processed on this Mac.", isInstalled: true)
                stateLock.unlock(); notify()
            } catch { stateLock.unlock(); throw error }
        } catch { fail(token, error: error) }
    }

    private func checkExistingModel(token: UUID) {
        diskLock.lock(); defer { diskLock.unlock() }
        do {
            try validateInstalledFiles()
            guard isCurrent(token) else { return }
            finish(token, status: LocalAIMatteStatus(phase: .ready, progress: 1, message: "Local person model installed. No frame uploads.", isInstalled: true))
        } catch { fail(token, error: error) }
    }

    private func validateInstalledFiles() throws {
        try validateStorageRoot()
        let directoryValues = try installedDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw LocalAIMatteError.invalidDownload("The model installation is not a regular directory.")
        }
        let receiptURL = installedDirectory.appendingPathComponent("receipt.json")
        let receiptSize = try receiptURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard receiptSize.isRegularFile == true, receiptSize.isSymbolicLink != true,
              let size = receiptSize.fileSize, size <= 65_536 else { throw LocalAIMatteError.invalidDownload("Invalid model receipt.") }
        let receipt = try JSONDecoder().decode(LocalAIMatteReceipt.self, from: Data(contentsOf: receiptURL))
        try receipt.validate(in: installedDirectory)
    }

    private func validateStorageRoot() throws {
        // AIModels must not be a user/mod-created symbolic link to unrelated
        // files. Parent system aliases (/var -> /private/var) are harmless.
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LocalAIMatteError.invalidDownload("AI model storage must be a regular directory, not a link.")
            }
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { locked { operation == token } }
    private func fail(_ token: UUID, error: Error) {
        finish(token, status: LocalAIMatteStatus(phase: .failed, message: "AI model unavailable: \(error.localizedDescription) Standard keying is still available."))
    }
    private func finish(_ token: UUID, status: LocalAIMatteStatus) {
        let changed = locked { () -> Bool in
            guard operation == token else { return false }
            snapshot = status
            if !status.isBusy { removing = false }
            return true
        }
        if changed { notify() }
    }
    private func notify() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(name: Self.statusDidChange, object: self)
        }
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }; return try work()
    }

#if LOCAL_AI_MATTE_TESTING
    /// Deterministic queue/generation exercise without downloading or inventing
    /// model weights. Excluded from the distributed app's build.
    func testingHoldStalePrediction(started: DispatchSemaphore, continuePrediction: DispatchSemaphore, reported: DispatchSemaphore, releaseQueue: DispatchSemaphore) {
        let token = locked { operation }
        inference.async {
            started.signal()
            _ = continuePrediction.wait(timeout: .now() + 5)
            self.finish(token, status: LocalAIMatteStatus(phase: .ready, progress: 1, message: "Stale test prediction", isInstalled: true))
            reported.signal()
            _ = releaseQueue.wait(timeout: .now() + 5)
        }
    }
#endif
}

enum LocalAIMatteError: LocalizedError {
    case invalidDownload(String), invalidPrediction(String), noPersonDetected
    var errorDescription: String? {
        switch self {
        case .invalidDownload(let text), .invalidPrediction(let text): return text
        case .noPersonDetected: return "No person detected in this frame."
        }
    }
}

/// Fixed vendor transport/content policy, independently testable with no model.
enum LocalAIMatteDownloadPolicy {
    static let url = URL(string: "https://ml-assets.apple.com/coreml/models/Image/ImageSegmentation/DeepLabV3/DeepLabV3FP16.mlmodel")!
    // This is the single-part object ETag Apple publishes, used as an MD5
    // corruption/version check alongside HTTPS. It is NOT a published SHA-256
    // signature and must not be described to users as one.
    static let publishedMD5 = "6d977568dcce6bc93cf4a5197ac8e172"
    static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.url == url,
              http.statusCode == 200, http.expectedContentLength == LocalAIMatte.modelDownloadBytes,
              http.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == publishedMD5,
              http.mimeType == "application/octet-stream" else {
            throw LocalAIMatteError.invalidDownload("Apple's model response did not match the expected URL, version or size. Try again later.")
        }
    }
    static func validate(data: Data) throws {
        guard data.count == LocalAIMatte.modelDownloadBytes,
              digest(Insecure.MD5.hash(data: data)) == publishedMD5 else {
            throw LocalAIMatteError.invalidDownload("The downloaded model was incomplete, corrupt or a different version.")
        }
    }
    static func validate(model: MLModel) throws {
        let description = model.modelDescription
        let image = description.inputDescriptionsByName["image"]?.imageConstraint
        let output = description.outputDescriptionsByName["semanticPredictions"]?.multiArrayConstraint
        guard description.inputDescriptionsByName.count == 1,
              image?.pixelsWide == 513, image?.pixelsHigh == 513,
              output?.dataType == .int32, output?.shape.map(\.intValue) == [513, 513],
              let values = description.metadata[.creatorDefinedKey] as? [String: String],
              values["com.apple.developer.machine-learning.models.name"] == "DeepLabV3FP16.mlmodel",
              values["com.apple.developer.machine-learning.models.version"] == "1.3",
              let json = values["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
              let preview = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let labels = preview["labels"] as? [String], labels.count == 21,
              labels[0] == "background", labels[15] == "person",
              let license = description.metadata[.license] as? String,
              license.contains("https://github.com/tensorflow/tensorflow") else {
            throw LocalAIMatteError.invalidDownload("The model's image input, person labels or licence metadata were invalid.")
        }
    }
    static func digest<T: Sequence>(_ hash: T) -> String where T.Element == UInt8 { hash.map { String(format: "%02x", $0) }.joined() }
}

private struct LocalAIMatteReceipt: Codable {
    var version: Int
    var sourceSHA256: String
    var compiledHashes: [String: String]
    static func create(in directory: URL, source: Data) throws -> Self {
        Self(version: 1, sourceSHA256: LocalAIMatteDownloadPolicy.digest(SHA256.hash(data: source)), compiledHashes: try hashes(in: directory.appendingPathComponent("model.mlmodelc")))
    }
    func validate(in directory: URL) throws {
        guard version == 1 else { throw LocalAIMatteError.invalidDownload("Unsupported model receipt.") }
        let sourceURL = directory.appendingPathComponent("model.mlmodel")
        let sourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true,
              sourceValues.fileSize == Int(LocalAIMatte.modelDownloadBytes) else { throw LocalAIMatteError.invalidDownload("Installed source model is incomplete.") }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        try LocalAIMatteDownloadPolicy.validate(data: data)
        guard LocalAIMatteDownloadPolicy.digest(SHA256.hash(data: data)) == sourceSHA256,
              try Self.hashes(in: directory.appendingPathComponent("model.mlmodelc")) == compiledHashes else {
            throw LocalAIMatteError.invalidDownload("Installed model files changed. Remove the model and download it again.")
        }
    }
    private static func hashes(in root: URL) throws -> [String: String] {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else { throw LocalAIMatteError.invalidDownload("Compiled model is missing.") }
        var result: [String: String] = [:], total = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw LocalAIMatteError.invalidDownload("Model contains an unexpected link.") }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, size >= 0, size <= 64 * 1024 * 1024,
                  total <= 96 * 1024 * 1024 - size, result.count < 256 else { throw LocalAIMatteError.invalidDownload("Compiled model files exceeded their limits.") }
            total += size
            let name = String(file.path.dropFirst(root.path.count + 1))
            result[name] = LocalAIMatteDownloadPolicy.digest(SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)))
        }
        guard !result.isEmpty else { throw LocalAIMatteError.invalidDownload("Compiled model is empty.") }
        return result
    }
}

enum LocalAIMatteMask {
    static func validExtent(_ extent: CGRect) -> Bool {
        !extent.isEmpty && !extent.isInfinite && !extent.isNull &&
        [extent.minX, extent.minY, extent.width, extent.height].allSatisfy(\.isFinite) &&
        extent.width <= 32_768 && extent.height <= 32_768
    }
    /// A DeepLab label is not a probability. Preserve the person label only;
    /// never infer confidence or interpret the other VOC labels as people.
    static func image(labels: MLMultiArray, extent: CGRect) throws -> CIImage {
        guard validExtent(extent), labels.dataType == .int32,
              labels.shape.count == 2, labels.shape.allSatisfy({ $0.intValue > 0 && $0.intValue <= 513 }) else {
            throw LocalAIMatteError.invalidPrediction("Unexpected segmentation output.")
        }
        let height = labels.shape[0].intValue, width = labels.shape[1].intValue
        let rowStride = labels.strides[0].intValue, columnStride = labels.strides[1].intValue
        guard rowStride > 0, columnStride > 0, rowStride <= 513 * 513,
              columnStride <= 513 * 513,
              (height - 1) * rowStride + (width - 1) * columnStride < labels.count else {
            throw LocalAIMatteError.invalidPrediction("Unexpected segmentation strides.")
        }
        let pointer = labels.dataPointer.assumingMemoryBound(to: Int32.self)
        var pixels = Data(count: width * height)
        var personCount = 0
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for y in 0..<height {
                for x in 0..<width {
                    // Both the model and bitmap initializer use top-down rows;
                    // Core Image performs the bitmap-to-CI-coordinate mapping.
                    let person = pointer[y * rowStride + x * columnStride] == 15
                    bytes[y * width + x] = person ? 255 : 0
                    if person { personCount += 1 }
                }
            }
        }
        // A failed recognition is not proof that the entire clip should be
        // transparent. Let the renderer fall back to normal chroma keying.
        guard personCount > 0 else { throw LocalAIMatteError.noPersonDetected }
        return CIImage(bitmapData: pixels, bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
