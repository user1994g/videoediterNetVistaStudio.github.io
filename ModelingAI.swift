import Foundation
import CryptoKit

enum ModelingAIPhase: String {
    case notChecked, checking, notDownloaded, downloading, installing, ready, generating, failed
}

struct ModelingAIStatus {
    var phase: ModelingAIPhase
    var progress: Double? = nil
    var message: String
    var isInstalled = false
    var isBusy: Bool { phase == .checking || phase == .downloading || phase == .installing || phase == .generating }
    var canGenerate: Bool { isInstalled && !isBusy }
    var canDownload: Bool { !isBusy && !isInstalled }
    var canRemove: Bool { !isBusy && (isInstalled || phase == .failed) }
}

struct ModelingAIContext: Codable, Equatable {
    var objectCount: Int = 0
    var selectedName: String? = nil
    var selectedVertices: Int = 0
    var selectedFaces: Int = 0

    func validate() throws {
        guard (0...256).contains(objectCount), (0...1_000_000).contains(selectedVertices),
              (0...1_000_000).contains(selectedFaces), (selectedName?.count ?? 0) <= 128 else {
            throw ModelingAIError.invalidPlan("The scene summary is outside the modeling helper's limits.")
        }
    }
}

enum ModelingAIActionKind: String, Codable {
    case addPrimitive, dragonStarter, subdivideSelected, smoothSelected
}

/// These are data-only requests, never generated Swift, Python, shell scripts,
/// URLs, paths or arbitrary tools. The editor previews and separately confirms
/// a complete validated plan before applying it as one undoable transaction.
struct ModelingAIAction: Codable, Equatable {
    var kind: ModelingAIActionKind
    var primitive: String? = nil
    var name: String? = nil
    var position: ModelPoint? = nil
    var rotation: ModelPoint? = nil
    var scale: ModelPoint? = nil
    var colour: String? = nil
    var levels: Int? = nil
    var iterations: Int? = nil

    var summary: String {
        switch kind {
        case .addPrimitive: return "Add \(name ?? primitive ?? "primitive")"
        case .dragonStarter: return "Add a sculptable dragon starter"
        case .subdivideSelected: return "Add \(levels ?? 1) detail level(s) to the selected mesh"
        case .smoothSelected: return "Smooth the selected mesh (\(iterations ?? 1) pass(es))"
        }
    }
}

struct ModelingAIPlan: Codable, Equatable {
    var version: Int = 1
    var title: String
    var explanation: String
    var actions: [ModelingAIAction]

    static let allowedPrimitives = ["Cube", "Sphere", "Cylinder", "Plane", "Sculpt Sphere"]

    func validate(context: ModelingAIContext? = nil) throws {
        try context?.validate()
        guard version == 1, (1...80).contains(title.count), explanation.count <= 1200,
              (1...12).contains(actions.count), Self.safeText(title), Self.safeText(explanation) else {
            throw ModelingAIError.invalidPlan("The helper returned an invalid or oversized plan.")
        }
        var addedObjects = 0, primitives = 0, dragons = 0, detailLevels = 0, smoothingPasses = 0
        for action in actions {
            switch action.kind {
            case .addPrimitive:
                guard let primitive = action.primitive, Self.allowedPrimitives.contains(primitive),
                      action.levels == nil, action.iterations == nil,
                      action.name.map({ (1...80).contains($0.count) && Self.safeText($0) }) ?? true else {
                    throw ModelingAIError.invalidPlan("The helper can add only the listed native primitives.")
                }
                for (point, range) in [(action.position, -25.0...25.0), (action.rotation, -360.0...360.0), (action.scale, 0.02...20.0)] {
                    guard point.map({ [$0.x, $0.y, $0.z].allSatisfy { $0.isFinite && range.contains($0) } }) ?? true else {
                        throw ModelingAIError.invalidPlan("A proposed shape's transform is outside the safe bounds.")
                    }
                }
                if let colour = action.colour {
                    guard colour.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                        throw ModelingAIError.invalidPlan("A proposed shape's color must be a six-digit hex color.")
                    }
                }
                addedObjects += 1; primitives += 1
            case .dragonStarter:
                try Self.requireOnly(action, fields: [])
                dragons += 1; addedObjects += 49 // Conservative reserve for the native dragon recipe's parts.
            case .subdivideSelected:
                try Self.requireOnly(action, fields: ["levels"])
                guard let levels = action.levels, (1...2).contains(levels) else {
                    throw ModelingAIError.invalidPlan("A plan can request one or two detail levels.")
                }
                detailLevels += levels
            case .smoothSelected:
                try Self.requireOnly(action, fields: ["iterations"])
                guard let iterations = action.iterations, (1...5).contains(iterations) else {
                    throw ModelingAIError.invalidPlan("A plan can request one to five smoothing passes.")
                }
                smoothingPasses += iterations
            }
        }
        guard addedObjects <= 57, primitives <= 8, dragons <= 1, detailLevels <= 2, smoothingPasses <= 5 else {
            throw ModelingAIError.invalidPlan("The proposed plan exceeds the per-operation modeling limits.")
        }
        if let context {
            guard context.objectCount + addedObjects <= 256 else {
                throw ModelingAIError.invalidPlan("This plan would add too many scene objects.")
            }
            guard (detailLevels == 0 && smoothingPasses == 0) || (context.selectedVertices > 0 && context.selectedFaces > 0) else {
                throw ModelingAIError.invalidPlan("Select a mesh before asking for smoothing or more detail.")
            }
        }
    }

    /// Codable ordinarily ignores unknown fields. Reject them explicitly so a
    /// model cannot sneak a command, URL, external asset or unsupported action
    /// into a plan that appears otherwise valid. No markdown recovery/fallback.
    static func decode(_ data: Data, context: ModelingAIContext? = nil) throws -> Self {
        guard data.count <= 32_768,
              let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(dictionary.keys).isSubset(of: ["version", "title", "explanation", "actions"]),
              let actions = dictionary["actions"] as? [[String: Any]], actions.count <= 12 else {
            throw ModelingAIError.invalidPlan("The helper must return a bounded JSON modeling plan, not code.")
        }
        let fields: Set<String> = ["kind", "primitive", "name", "position", "rotation", "scale", "colour", "levels", "iterations"]
        for action in actions {
            guard Set(action.keys).isSubset(of: fields) else {
                throw ModelingAIError.invalidPlan("The plan includes an unsupported action or field.")
            }
            for field in ["position", "rotation", "scale"] where action[field] != nil && !(action[field] is NSNull) {
                guard let vector = action[field] as? [String: Any], Set(vector.keys) == Set(["x", "y", "z"]) else {
                    throw ModelingAIError.invalidPlan("Use exactly x, y and z for each proposed transform.")
                }
            }
        }
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validate(context: context)
        return plan
    }

    private static func requireOnly(_ action: ModelingAIAction, fields: Set<String>) throws {
        guard action.primitive == nil, action.name == nil, action.position == nil,
              action.rotation == nil, action.scale == nil, action.colour == nil,
              fields.contains("levels") || action.levels == nil,
              fields.contains("iterations") || action.iterations == nil else {
            throw ModelingAIError.invalidPlan("This modeling action contains unexpected settings.")
        }
    }

    private static func safeText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) &&
            !["://", "javascript:", "data:", "file:", "<script", "#!/", "```", "`", "rm -rf"].contains(where: lower.contains)
    }

    static var jsonSchema: [String: Any] {
        let vector: [String: Any] = ["type": "object", "additionalProperties": false,
            "required": ["x", "y", "z"], "properties": ["x": ["type": "number"], "y": ["type": "number"], "z": ["type": "number"]]]
        func action(_ kind: ModelingAIActionKind, fields: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var properties = fields
            properties["kind"] = ["type": "string", "const": kind.rawValue]
            return ["type": "object", "additionalProperties": false,
                    "required": ["kind"] + required, "properties": properties]
        }
        let options = [
            action(.addPrimitive, fields: ["primitive": ["type": "string", "enum": allowedPrimitives],
                "name": ["type": "string", "maxLength": 80],
                "position": vector, "rotation": vector, "scale": vector,
                "colour": ["type": "string", "pattern": "^#[0-9a-fA-F]{6}$"]], required: ["primitive"]),
            action(.dragonStarter),
            action(.subdivideSelected, fields: ["levels": ["type": "integer", "minimum": 1, "maximum": 2]], required: ["levels"]),
            action(.smoothSelected, fields: ["iterations": ["type": "integer", "minimum": 1, "maximum": 5]], required: ["iterations"])
        ]
        return ["type": "object", "additionalProperties": false,
                "required": ["version", "title", "explanation", "actions"],
                "properties": ["version": ["type": "integer", "const": 1],
                    "title": ["type": "string", "maxLength": 80],
                    "explanation": ["type": "string", "maxLength": 1200],
                    "actions": ["type": "array", "minItems": 1, "maxItems": 12,
                        "items": ["anyOf": options]]]]
    }
}

enum ModelingAIError: LocalizedError {
    case unavailable, busy, cancelled, http(Int), invalidPlan(String), invalidResponse(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Download the optional local model first. Manual modeling is always available."
        case .busy: return "A modeling helper request is already running. Cancel it or wait for it to finish."
        case .cancelled: return "The modeling helper request was cancelled."
        case .http(let code): return "The model download server returned HTTP \(code). Try again later."
        case .invalidPlan(let message), .invalidResponse(let message): return message
        }
    }
}

/// Optional, app-managed local planning. Download is the only network action.
/// No Ollama installation, account, background server or automatic download.
/// Model processing happens in a signed helper which exits after each proposal.
final class ModelingAI {
    static let shared = ModelingAI()
    static let statusDidChange = Notification.Name("NetVistaModelingAIStatusDidChange")
    static let modelName = "Qwen2.5 0.5B Instruct"
    static var modelDownloadBytes: Int64 { ModelingAIModelSpec.production.bytes }
    static let informationURL = URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF")!
    static let licenseNotice = "Qwen2.5 0.5B Instruct by Alibaba/Qwen, Apache License 2.0. Bundled llama.cpp CPU runtime, MIT License. Model download is optional."
    private let worker = DispatchQueue(label: "com.netvistastudio.modeling-ai", qos: .userInitiated)
    private let stateLock = NSLock()
    private let root: URL, spec: ModelingAIModelSpec
    private let configuration: URLSessionConfiguration
    private let runtime: ModelingAIPlanRunning
    private var snapshot = ModelingAIStatus(phase: .notChecked, message: "Optional AI is not downloaded. Choose Download model or keep modeling without AI.")
    private var token = UUID()
    private var transfer: ModelingAIModelDownload?
    private var pendingPlan: ((Result<ModelingAIPlan, Error>) -> Void)?

    var installedDirectory: URL { root.appendingPathComponent("Qwen2.5-0.5B-Q4_K_M-v1", isDirectory: true) }
    var modelFile: URL { installedDirectory.appendingPathComponent("model.gguf") }
    var status: ModelingAIStatus { locked { snapshot } }

    init(storageDirectory: URL? = nil, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         modelSpec: ModelingAIModelSpec = .production, runtime: ModelingAIPlanRunning = ModelingAIProcessRuntime()) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = (storageDirectory ?? support.appendingPathComponent("NetVistaStudio/AIModels", isDirectory: true)).standardizedFileURL
        spec = modelSpec; self.runtime = runtime
        configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 3600
        // Checking a previously installed file is local/background-only. No model
        // is fetched or runtime started by init, opening a project or a window.
        if FileManager.default.fileExists(atPath: installedDirectory.path) { checkAvailability() }
    }

    func checkAvailability() {
        guard let operation = begin(.checking, message: "Checking the model saved on this computer…") else { return }
        worker.async {
            guard self.isCurrent(operation) else { return }
            do {
                try self.spec.validate(); try self.validateRoot()
                guard FileManager.default.fileExists(atPath: self.installedDirectory.path) else { self.ready(operation, installed: false); return }
                try self.verifyInstalled(operation)
                self.ready(operation, installed: true)
            } catch { self.fail(operation, error) }
        }
    }

    /// UI confirms the size/source first. Pressing Download works immediately;
    /// there is no preliminary Check or separate runtime installation.
    func downloadModel() {
        guard status.canDownload,
              let operation = begin(.downloading, message: "Downloading the optional local model…", progress: 0) else { return }
        worker.async {
            guard self.isCurrent(operation) else { return }
            let pending = self.root.appendingPathComponent(".download-\(operation.uuidString)", isDirectory: true)
            do {
                try self.spec.validate(); try self.validateRoot()
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
                try self.validateRoot()
                let disk = try self.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
                if let disk, Int64(disk) < self.spec.bytes + 32_000_000 {
                    throw ModelingAIError.invalidResponse("Not enough disk space for this optional model. Free about \(self.spec.bytes / 1_000_000 + 32) MB and retry.")
                }
                try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let download = try ModelingAIModelDownload(spec: self.spec, destination: pending.appendingPathComponent("model.gguf"),
                    configuration: self.configuration, progress: { value in
                        self.update(operation, ModelingAIStatus(phase: .downloading, progress: value,
                            message: String(format: "Downloading model · %.0f%% (%.1f / %.1f MB)", value * 100,
                                value * Double(self.spec.bytes) / 1_000_000, Double(self.spec.bytes) / 1_000_000)))
                    }, completion: { result in
                        self.worker.async {
                            defer { self.cleanPending(pending) }
                            guard self.isCurrent(operation) else { return }
                            self.transfer = nil
                            do {
                                try result.get()
                                self.update(operation, ModelingAIStatus(phase: .installing, progress: 1, message: "Download verified. Installing the local model…"))
                                try self.install(pending, operation)
                            } catch { self.fail(operation, error) }
                        }
                    })
                guard self.isCurrent(operation) else { download.cancel(); self.cleanPending(pending); return }
                self.transfer = download; download.start()
            } catch { self.cleanPending(pending); self.fail(operation, error) }
        }
    }

    func removeModel() {
        guard let operation = begin(.installing, message: "Removing only NetVista's optional modeling model…") else { return }
        worker.async {
            guard self.isCurrent(operation) else { return }
            do {
                try self.validateRoot()
                if FileManager.default.fileExists(atPath: self.installedDirectory.path) {
                    try self.regularDirectory(self.installedDirectory)
                    try self.locked {
                        guard self.token == operation else { throw ModelingAIError.cancelled }
                        try FileManager.default.removeItem(at: self.installedDirectory)
                    }
                }
                self.ready(operation, installed: false, message: "Optional model removed. Manual modeling is still available.")
            } catch { self.fail(operation, error) }
        }
    }

    func propose(prompt: String, context: ModelingAIContext, completion: @escaping (Result<ModelingAIPlan, Error>) -> Void) {
        do {
            try context.validate()
            guard (1...1600).contains(prompt.trimmingCharacters(in: .whitespacesAndNewlines).count), prompt.utf8.count <= 6400 else {
                throw ModelingAIError.invalidPlan("Describe the model in 1–1,600 characters.")
            }
        } catch { deliver(completion, .failure(error)); return }
        guard let operation = begin(.generating, message: "Preparing the downloaded local helper…") else {
            deliver(completion, .failure(ModelingAIError.busy)); return
        }
        worker.async {
            guard self.isCurrent(operation) else { self.deliver(completion, .failure(ModelingAIError.cancelled)); return }
            self.pendingPlan = completion
            do {
                guard FileManager.default.fileExists(atPath: self.modelFile.path) else { throw ModelingAIError.unavailable }
                try self.verifyInstalled(operation)
                guard self.isCurrent(operation) else { throw ModelingAIError.cancelled }
                let summary = String(data: try JSONEncoder().encode(context), encoding: .utf8)!
                let text = "<|im_start|>system\n" + Self.systemPrompt + "<|im_end|>\n<|im_start|>user\nScene summary: " + summary +
                    "\nUser request: " + prompt + "<|im_end|>\n<|im_start|>assistant\n"
                self.update(operation, ModelingAIStatus(phase: .generating, message: "Thinking on this computer… your scene is unchanged.", isInstalled: true))
                self.runtime.generate(model: self.modelFile, prompt: text, schema: ModelingAIPlan.jsonSchema) { result in
                    self.worker.async {
                        guard self.isCurrent(operation) else { return }
                        do {
                            let plan = try ModelingAIPlan.decode(result.get(), context: context)
                            self.ready(operation, installed: true); self.completePlan(.success(plan))
                        } catch { self.fail(operation, error, installed: true) }
                    }
                }
            } catch { self.fail(operation, error) }
        }
    }

    /// Invalidate immediately, even while a worker is hashing a large file.
    /// A cancelled or late transfer can never commit an installed model.
    func cancel() {
        let wasCancelled = locked { () -> Bool in
            guard snapshot.isBusy else { return false }
            token = UUID()
            snapshot = ModelingAIStatus(phase: snapshot.isInstalled ? .ready : .notDownloaded,
                message: "Cancelled. Your scene is unchanged; download again whenever you want.", isInstalled: snapshot.isInstalled)
            return true
        }
        guard wasCancelled else { return }
        notify()
        worker.async {
            self.transfer?.cancel(); self.transfer = nil; self.runtime.cancel()
            self.completePlan(.failure(ModelingAIError.cancelled))
        }
    }

    private struct Receipt: Codable {
        let version: Int, bytes: Int64
        let sha256: String
    }
    private func verifyInstalled(_ operation: UUID) throws {
        try spec.validate(); try validateRoot(); try regularDirectory(installedDirectory)
        let receiptURL = installedDirectory.appendingPathComponent("receipt.json")
        let receiptValues = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard receiptValues.isRegularFile == true, receiptValues.isSymbolicLink != true,
              let size = receiptValues.fileSize, size <= 65_536 else { throw ModelingAIError.invalidResponse("Invalid local model receipt. Remove this model and download again.") }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.version == 1, receipt.bytes == spec.bytes, receipt.sha256 == spec.sha256 else {
            throw ModelingAIError.invalidResponse("The saved model does not match this supported version.")
        }
        let fileValues = try modelFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard fileValues.isRegularFile == true, fileValues.isSymbolicLink != true, Int64(fileValues.fileSize ?? -1) == spec.bytes else {
            throw ModelingAIError.invalidResponse("The saved model file is incomplete or is a link.")
        }
        let file = try FileHandle(forReadingFrom: modelFile); defer { try? file.close() }
        var hasher = SHA256(), total: Int64 = 0, header = Data()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            guard isCurrent(operation) else { throw ModelingAIError.cancelled }
            if header.isEmpty { header = Data(data.prefix(8)) }
            hasher.update(data: data); total += Int64(data.count)
            guard total <= spec.bytes else { throw ModelingAIError.invalidResponse("The saved model changed during verification.") }
        }
        guard total == spec.bytes, header.prefix(4) == Data("GGUF".utf8),
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == spec.sha256 else {
            throw ModelingAIError.invalidResponse("The saved model is corrupt. Remove it and download again.")
        }
    }

    private func install(_ pending: URL, _ operation: UUID) throws {
        try validateRoot(); try regularDirectory(pending)
        let receipt = Receipt(version: 1, bytes: spec.bytes, sha256: spec.sha256)
        try JSONEncoder().encode(receipt).write(to: pending.appendingPathComponent("receipt.json"), options: .atomic)
        let licenseURL = Bundle.main.url(forResource: "QWEN-LICENSE", withExtension: "txt", subdirectory: "modeling-ai/licenses")
        let fullLicense = licenseURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        try Data((Self.licenseNotice + "\n\n" + fullLicense).utf8).write(to: pending.appendingPathComponent("MODEL-LICENSE.txt"), options: .atomic)
        try locked {
            guard token == operation else { throw ModelingAIError.cancelled }
            // Existing model may be corrupt, but never follow a link or touch
            // other users' models. Keep it recoverable until commit succeeds.
            let backup = root.appendingPathComponent(".previous-\(operation.uuidString)", isDirectory: true)
            let previous = FileManager.default.fileExists(atPath: installedDirectory.path)
            if previous { try regularDirectory(installedDirectory); try FileManager.default.moveItem(at: installedDirectory, to: backup) }
            do { try FileManager.default.moveItem(at: pending, to: installedDirectory) }
            catch { if previous { try? FileManager.default.moveItem(at: backup, to: installedDirectory) }; throw error }
            if previous { try? FileManager.default.removeItem(at: backup) }
            token = UUID()
            snapshot = ModelingAIStatus(phase: .ready, progress: 1, message: "Model downloaded and ready. AI proposals stay on this computer.", isInstalled: true)
        }
        notify()
    }

    private func validateRoot() throws {
        // Reject user/mod-created directory links; /var and /tmp themselves are
        // normal macOS aliases. No model path is supplied by scene contents.
        var directory = root
        while directory.path != "/" {
            if let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true,
               !["/var", "/tmp", "/private/var"].contains(directory.path) {
                throw ModelingAIError.invalidResponse("AI model storage cannot be a symbolic link.")
            }
            directory.deleteLastPathComponent()
        }
        if FileManager.default.fileExists(atPath: root.path) { try regularDirectory(root) }
    }
    private func regularDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ModelingAIError.invalidResponse("AI model storage must be a regular directory, not a link.")
        }
    }
    private func cleanPending(_ pending: URL) {
        guard pending.deletingLastPathComponent() == root, pending.lastPathComponent.hasPrefix(".download-"),
              (try? validateRoot()) != nil, (try? regularDirectory(pending)) != nil else { return }
        try? FileManager.default.removeItem(at: pending)
    }
    private func begin(_ phase: ModelingAIPhase, message: String, progress: Double? = nil) -> UUID? {
        let value = locked { () -> UUID? in
            guard !snapshot.isBusy else { return nil }
            token = UUID(); snapshot = ModelingAIStatus(phase: phase, progress: progress, message: message, isInstalled: snapshot.isInstalled)
            return token
        }
        if value != nil { notify() }; return value
    }
    private func isCurrent(_ operation: UUID) -> Bool { locked { token == operation } }
    private func update(_ operation: UUID, _ status: ModelingAIStatus) {
        let changed = locked { () -> Bool in guard token == operation else { return false }; snapshot = status; return true }
        if changed { notify() }
    }
    private func ready(_ operation: UUID, installed: Bool, message: String? = nil) {
        let changed = locked { () -> Bool in
            guard token == operation else { return false }; token = UUID()
            snapshot = ModelingAIStatus(phase: installed ? .ready : .notDownloaded, progress: installed ? 1 : nil,
                message: message ?? (installed ? "Local AI ready. Review every proposal before applying." : "Optional AI is not downloaded. Click Download model, or keep using manual modeling."), isInstalled: installed)
            return true
        }
        if changed { notify() }
    }
    private func fail(_ operation: UUID, _ error: Error, installed: Bool = false) {
        let changed = locked { () -> Bool in
            guard token == operation else { return false }; token = UUID()
            snapshot = ModelingAIStatus(phase: .failed, message: error.localizedDescription + " Manual modeling still works.", isInstalled: installed)
            return true
        }
        guard changed else { return }; notify()
        completePlan(.failure(error))
    }
    private func completePlan(_ result: Result<ModelingAIPlan, Error>) {
        guard let completion = pendingPlan else { return }
        pendingPlan = nil; deliver(completion, result)
    }
    private func deliver(_ completion: @escaping (Result<ModelingAIPlan, Error>) -> Void, _ result: Result<ModelingAIPlan, Error>) {
        DispatchQueue.main.async { completion(result) }
    }
    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.statusDidChange, object: self) }
    }
    private func locked<T>(_ action: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }; return try action()
    }

    private static let systemPrompt = """
    You are a small offline 3D modeling planning helper inside NetVista Studio.
    Return only the JSON object matching the supplied schema, with version 1, a short title, a short explanation, and 1 to 12 safe actions.
    You cannot create arbitrary meshes, images, materials, rigs, scripts, URLs or files. Never output code or commands.
    Native primitives: Cube, Sphere, Cylinder, Plane, Sculpt Sphere. addPrimitive may use name, position, rotation (degrees), scale, colour (#RRGGBB).
    Positions must be within +/-25, rotations +/-360, and scales 0.02 to 20. Use Y as up. Omitted transforms use origin, zero rotation and unit scale.
    dragonStarter adds one native sculptable dragon starting recipe; it takes no additional fields. This is only a starter, not a finished character.
    subdivideSelected takes only levels (1 or 2, maximum 2 total). smoothSelected takes only iterations (1 to 5, maximum 5 total). Use these only when a mesh is selected.
    At most one dragonStarter and eight addPrimitive actions. Prefer a few useful shapes over many parts. Explain that the user can continue sculpting the shapes.
    All actions are suggestions. The app previews the plan and the user decides whether to apply it.
    """
}
