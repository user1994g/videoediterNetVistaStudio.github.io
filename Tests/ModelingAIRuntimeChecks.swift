import Foundation

@main struct ModelingAIRuntimeChecks {
    static func wait(_ label: String, _ complete: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !complete() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(complete(), "Timeout: \(label)")
    }
    static func main() throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = URL(fileURLWithPath: "/private/tmp/not-a-real-model.gguf")
        let schema: [String: Any] = ["type": "object"]
        let literalPrompt = "Keep this literal: $(touch bad); --hf-repo malicious; 'quote'\nnext line"
        let runtime = ModelingAIProcessRuntime(testHelper: helper)
        var response: Result<Data, Error>?
        runtime.generate(model: model, prompt: literalPrompt, schema: schema) { response = $0 }
        wait("complete output plus stderr", { response != nil })
        let object = try JSONSerialization.jsonObject(with: response!.get()) as! [String: Any]
        precondition(object["explanation"] as? String == literalPrompt, "Prompts must be literal data in a file, not process options/shell input")
        for key in ["promptPath", "schemaPath"] { precondition(!FileManager.default.fileExists(atPath: object[key] as! String), "Inference scratch files must be removed") }
        for mode in ["nonzero", "oversized", "timeout", "cancel"] {
            let runtime = ModelingAIProcessRuntime(testHelper: helper, timeout: mode == "timeout" ? 0.2 : 4)
            var result: Result<Data, Error>?
            runtime.generate(model: model, prompt: mode, schema: schema) { result = $0 }
            if mode == "cancel" { DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runtime.cancel() } }
            wait(mode, { result != nil })
            if case .success = result! { preconditionFailure("\(mode) must not succeed") }
        }
        print("PASS: native CPU-helper arguments, literal prompt/schema files, bounded output, pipe draining, scratch cleanup, exit failure, timeout and cancellation without real weights")
    }
}
