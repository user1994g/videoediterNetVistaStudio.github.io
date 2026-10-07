import Foundation
import Darwin

// Deliberately not an inference engine. This compiled fixture checks exactly
// what NetVista passes across the process boundary, and tests stream handling.
@main struct ModelingAIRuntimeFixture {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let expected = ["--model", "--file", "--json-schema-file", "--n-predict", "--ctx-size", "--threads", "--temp", "--seed",
                        "--offline", "--simple-io", "--no-display-prompt", "--no-conversation", "--log-disable", "--no-perf"]
        let options = args.filter { $0.hasPrefix("--") }
        guard options == expected, !args.contains("--host"), !args.contains("--hf-repo"), !args.contains("--url") else { exit(4) }
        func value(_ key: String) -> String { args[args.firstIndex(of: key)! + 1] }
        let promptFile = value("--file"), schemaFile = value("--json-schema-file")
        let prompt = try String(contentsOfFile: promptFile, encoding: .utf8)
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: schemaFile))) as! [String: Any]
        guard schema["type"] as? String == "object", !promptFile.contains("--"), value("--n-predict") == "1600",
              value("--ctx-size") == "4096", value("--threads") == "4" else { exit(5) }
        if prompt == "timeout" || prompt == "cancel" { Thread.sleep(forTimeInterval: 20) }
        if prompt == "nonzero" { exit(8) }
        if prompt == "oversized" { FileHandle.standardOutput.write(Data(repeating: 65, count: 60_000)); return }
        // More than one pipe buffer of diagnostics must not block the output.
        FileHandle.standardError.write(Data(repeating: 66, count: 90_000))
        let output: [String: Any] = ["version": 1, "title": "Fixture", "explanation": prompt,
                                    "actions": [["kind": "dragonStarter"]], "promptPath": promptFile, "schemaPath": schemaFile]
        let bytes = try JSONSerialization.data(withJSONObject: output)
        for byte in bytes { FileHandle.standardOutput.write(Data([byte])) }
    }
}
