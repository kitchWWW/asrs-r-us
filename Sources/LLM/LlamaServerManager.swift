import Foundation
import Combine
import os

/// Owns the `llama-server` child process that serves the local model.
///
/// The app manages the server itself so the user never has to run a terminal
/// command. If a healthy server is already listening on the port -- because the
/// user runs their own, or a previous launch left one up -- we adopt it instead
/// of starting a second one.
@MainActor
final class LlamaServerManager: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        /// First run pulls the model (~1 GB); llama-server does the download.
        case preparingModel
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    @Published private(set) var state: State = .stopped

    private var process: Process?
    private var adoptedExisting = false
    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "llama")
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var endpoint: URL {
        URL(string: "http://127.0.0.1:\(settings.localPort)")!
    }

    var client: LocalLLMClient {
        LocalLLMClient(endpoint: endpoint, modelName: "local")
    }

    /// Common install locations. A GUI app inherits a minimal PATH, so `which`
    /// alone is not enough.
    private static let candidatePaths = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
        "/opt/homebrew/opt/llama.cpp/bin/llama-server",
    ]

    static func locateBinary(override: String) -> String? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Lifecycle

    func start() async {
        guard state != .ready, state != .starting, state != .preparingModel else { return }

        // Adopt an already-healthy server rather than fighting it for the port.
        if await isHealthy() {
            adoptedExisting = true
            state = .ready
            log.info("adopted existing llama-server on port \(self.settings.localPort)")
            return
        }

        guard let binary = Self.locateBinary(override: settings.llamaServerPath) else {
            state = .failed(
                "llama-server not found. Install it with:  brew install llama.cpp"
            )
            return
        }

        state = .starting

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = [
            "-hf", settings.localModelRepo,
            "--port", String(settings.localPort),
            "--ctx-size", "4096",
            "--n-gpu-layers", "999",   // full Metal offload
            "--no-webui",
        ]
        // Inherit HOME so the model cache is shared with the CLI, and give the
        // child a sane PATH since the GUI app's is minimal.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        task.environment = environment
        task.standardOutput = FileHandle.nullDevice

        // llama-server writes progress and errors to stderr; watch it so we can
        // tell "downloading a 1 GB model" apart from "wedged".
        let pipe = Pipe()
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in self?.observe(stderr: text) }
        }

        do {
            try task.run()
            process = task
            log.info("spawned llama-server (\(binary))")
        } catch {
            state = .failed("Could not start llama-server: \(error.localizedDescription)")
            return
        }

        // First run downloads the model, so allow a generous window.
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while ContinuousClock.now < deadline {
            if !task.isRunning {
                state = .failed("llama-server exited unexpectedly (status \(task.terminationStatus)).")
                return
            }
            if await isHealthy() {
                state = .ready
                log.info("llama-server ready")
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        state = .failed("llama-server did not become ready in time.")
    }

    private func observe(stderr text: String) {
        if state == .starting, text.contains("%") || text.lowercased().contains("download") {
            state = .preparingModel
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        // Leave a server we did not start running.
        if !adoptedExisting { state = .stopped }
    }

    func restart() async {
        stop()
        adoptedExisting = false
        state = .stopped
        await start()
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["status"] as? String) == "ok"
    }
}
