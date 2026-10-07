import Foundation
import CryptoKit
import Darwin

/// A pinned, data-only model. Production never accepts a URL from a project,
/// prompt, plugin or server response. Test fixtures use isolated storage.
struct ModelingAIModelSpec {
    let url: URL
    let bytes: Int64
    let sha256: String

    // Filled from Qwen's official, revision-pinned GGUF LFS metadata.
    static let production = ModelingAIModelSpec(
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        bytes: 491_400_032, sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db")

    static func allowedDownloadURL(_ url: URL) -> Bool {
        let hosts: Set<String> = ["huggingface.co", "hf.co", "cdn-lfs.huggingface.co", "cdn-lfs.hf.co", "cas-bridge.xethub.hf.co", "us.aws.cdn.hf.co"]
        return url.scheme == "https" && hosts.contains(url.host?.lowercased() ?? "") &&
            (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && url.fragment == nil
    }

    func validate() throws {
        guard Self.allowedDownloadURL(url), (8...650_000_000).contains(bytes),
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ModelingAIError.invalidResponse("The optional model's fixed download manifest is invalid.")
        }
    }
}

/// Streams to a unique pending file rather than keeping a ~500 MB Data buffer
/// in RAM. Only a complete, exact SHA-256 match may be installed by the owner.
final class ModelingAIModelDownload: NSObject, URLSessionDataDelegate {
    private let spec: ModelingAIModelSpec, destination: URL
    private let progress: (Double) -> Void
    private let completion: (Result<Void, Error>) -> Void
    private var session: URLSession?, task: URLSessionDataTask?, file: FileHandle?
    private var hasher = SHA256(), received: Int64 = 0, header = Data()
    private var accepted = false, redirects = 0, failure: Error?
    private var lastProgress: Double = -1

    init(spec: ModelingAIModelSpec, destination: URL, configuration: URLSessionConfiguration,
         progress: @escaping (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) throws {
        try spec.validate()
        self.spec = spec; self.destination = destination; self.progress = progress; self.completion = completion
        super.init()
        // O_EXCL also rejects dangling links. Never follow or truncate a file
        // placed at the pending path between an existence check and open.
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw ModelingAIError.invalidResponse("Could not create the pending model download.")
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: spec.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        task = session!.dataTask(with: request)
    }
    func start() { task?.resume() }
    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, ModelingAIModelSpec.allowedDownloadURL(url) else {
            failure = ModelingAIError.invalidResponse("The model download redirected outside its approved HTTPS vendor hosts.")
            completionHandler(nil); return
        }
        var clean = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        clean.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            failure = ModelingAIError.invalidResponse("The public model download must not request account credentials.")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              ModelingAIModelSpec.allowedDownloadURL(url), http.statusCode == 200 else {
            failure = failure ?? (response as? HTTPURLResponse).map { ModelingAIError.http($0.statusCode) } ??
                ModelingAIError.invalidResponse("The model server returned an unexpected response.")
            completionHandler(.cancel); return
        }
        let mime = http.mimeType?.lowercased() ?? ""
        guard ["application/octet-stream", "binary/octet-stream", "application/x-gguf"].contains(mime),
              http.expectedContentLength == -1 || http.expectedContentLength == spec.bytes else {
            failure = ModelingAIError.invalidResponse("The model server returned an unexpected file type or size.")
            completionHandler(.cancel); return
        }
        accepted = true; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accepted, failure == nil, Int64(data.count) <= spec.bytes - received else {
            failure = failure ?? ModelingAIError.invalidResponse("The model download exceeded its advertised size.")
            dataTask.cancel(); return
        }
        do {
            try file?.write(contentsOf: data); hasher.update(data: data); received += Int64(data.count)
            if header.count < 8 { header.append(data.prefix(8 - header.count)) }
            let amount = Double(received) / Double(spec.bytes)
            if amount - lastProgress >= 0.005 || received == spec.bytes { lastProgress = amount; progress(amount) }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.task = nil; self.session = nil; session.finishTasksAndInvalidate() }
        do {
            try file?.close(); file = nil
            if let error = failure ?? error { throw error }
            guard accepted, received == spec.bytes, header.prefix(4) == Data("GGUF".utf8),
                  hasher.finalize().map({ String(format: "%02x", $0) }).joined() == spec.sha256 else {
                throw ModelingAIError.invalidResponse("The model was incomplete, corrupt or a different version. Retry the download.")
            }
            completion(.success(()))
        } catch { completion(.failure(error)) }
    }
}

protocol ModelingAIPlanRunning: AnyObject {
    func generate(model: URL, prompt: String, schema: [String: Any], completion: @escaping (Result<Data, Error>) -> Void)
    func cancel()
}

/// Runs only the signed, app-bundled CPU completion helper with fixed arguments.
/// No shell, server, remote API, plugin executable or model-supplied code. The
/// helper uses a fixed offline invocation/config, no GPU backend, and releases
/// all model RAM when it exits. No prompt goes to a network API.
final class ModelingAIProcessRuntime: ModelingAIPlanRunning {
    private let worker = DispatchQueue(label: "com.netvistastudio.modeling-ai.cpu", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let helperURL: URL
    private let requestTimeout: TimeInterval

    init() {
        helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/modeling-runtime/llama-completion")
        requestTimeout = 180
    }
#if MODELING_AI_RUNTIME_TESTING
    // Not present in release builds: a tiny native fixture tests process
    // transport/cancellation without downloading or inventing real weights.
    init(testHelper: URL, timeout: TimeInterval = 180) {
        helperURL = testHelper; requestTimeout = timeout
    }
#endif

    func generate(model: URL, prompt: String, schema: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        lock.lock(); cancelled = false; lock.unlock()
        worker.async {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NetVistaModelingAI-\(UUID().uuidString)", isDirectory: true)
            let finish: (Result<Data, Error>) -> Void = { result in
                try? FileManager.default.removeItem(at: directory)
                completion(result)
            }
            do {
                let helper = self.helperURL
                guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                    throw ModelingAIError.invalidResponse("The bundled local AI runtime is missing. Reinstall this NetVista build; no Ollama setup is needed.")
                }
                let helperValues = try helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard helperValues.isRegularFile == true, helperValues.isSymbolicLink != true else {
                    throw ModelingAIError.invalidResponse("The bundled AI runtime is not a regular executable.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let input = directory.appendingPathComponent("prompt.txt"), format = directory.appendingPathComponent("schema.json")
                try Data(prompt.utf8).write(to: input, options: .atomic)
                try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]).write(to: format, options: .atomic)
                let task = Process(); task.executableURL = helper
                task.arguments = ["--model", model.path, "--file", input.path, "--json-schema-file", format.path,
                    "--n-predict", "1600", "--ctx-size", "4096", "--threads", "4", "--temp", "0.15", "--seed", "42",
                    "--offline", "--simple-io", "--no-display-prompt", "--no-conversation", "--log-disable", "--no-perf"]
                task.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
                task.standardInput = FileHandle.nullDevice
                let output = Pipe(), errors = Pipe(); task.standardOutput = output; task.standardError = errors
                let capture = ModelingAIProcessCapture()
                self.lock.lock()
                guard !self.cancelled else { self.lock.unlock(); throw ModelingAIError.cancelled }
                self.process = task
                do { try task.run() } catch { self.process = nil; self.lock.unlock(); throw error }
                self.lock.unlock()
                // Drain both streams concurrently. Waiting for their EOF before
                // decoding avoids losing a final token to a late readability
                // callback, and avoids deadlock if the helper writes diagnostics.
                let readers = DispatchGroup()
                for (pipe, isError) in [(output, false), (errors, true)] {
                    try pipe.fileHandleForWriting.close()
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { readers.leave(); try? pipe.fileHandleForReading.close() }
                        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                            capture.append(chunk, error: isError, process: task)
                        }
                    }
                }
                let timeout = DispatchWorkItem { capture.timeout(); self.stop(task) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.requestTimeout, execute: timeout)
                task.waitUntilExit(); timeout.cancel()
                readers.wait()
                self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                if wasCancelled { throw ModelingAIError.cancelled }
                finish(try capture.result(exit: task.terminationStatus))
            } catch { finish(.failure(error)) }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        if let current { stop(current) }
    }
    private func stop(_ task: Process) {
        if task.isRunning { task.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
        }
    }
}

private final class ModelingAIProcessCapture {
    private let lock = NSLock()
    private var data = Data(), diagnostics = Data(), failed: Error?
    func append(_ chunk: Data, error: Bool, process: Process) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        if !error {
            if chunk.count > 32_768 - data.count { failed = ModelingAIError.invalidResponse("The local model's output exceeded the plan limit.") }
            else { data.append(chunk) }
        } else { diagnostics.append(chunk.prefix(max(0, 4096 - diagnostics.count))) }
        let stop = failed != nil; lock.unlock()
        if stop && process.isRunning { process.terminate() }
    }
    func timeout() { lock.lock(); failed = ModelingAIError.invalidResponse("Local AI took too long. Try a shorter request; your scene is unchanged."); lock.unlock() }
    func result(exit: Int32) throws -> Result<Data, Error> {
        lock.lock(); defer { lock.unlock() }
        if let failed { throw failed }
        guard exit == 0 else {
            throw ModelingAIError.invalidResponse("The local AI runtime could not generate a plan (code \(exit)). Your scene is unchanged.")
        }
        return .success(data)
    }
}
