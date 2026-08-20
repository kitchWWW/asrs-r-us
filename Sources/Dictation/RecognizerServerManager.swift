import Combine
import Foundation
import os

/// Owns the `asr_server.py` child process that serves a sidecar recogniser.
///
/// Deliberately the same shape as `LlamaServerManager`, down to adopting a
/// healthy server it did not start: the two problems are the same problem, and
/// someone debugging one should recognise the other. The differences are that
/// this one switches models when the recogniser setting changes, and that a
/// server it adopted is left running on quit.
///
/// Why a sidecar at all: the app runs with the hardened runtime on and is
/// signed, so loading ONNX Runtime and Kaldi in-process would mean signing
/// third-party dylibs or disabling library validation. A child process costs a
/// localhost round trip measured in microseconds and avoids that entirely.
@MainActor
final class RecognizerServerManager: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        /// Vosk's model is 1.8 GB and takes a few seconds to page in.
        case loadingModel
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    @Published private(set) var state: State = .stopped

    /// Which sidecar engines the running server has loaded.
    ///
    /// A set, not a single recogniser. One server hosts every model now, and
    /// tracking a single "current" choice was actively harmful: with several
    /// recognisers cross-checking, each one asked to start and each saw a
    /// different choice than the last, so the manager read it as "the
    /// recogniser changed" and killed and respawned the server for every
    /// backend in turn -- reloading gigabytes of models and opening a health
    /// connection every 300 ms until the machine ran out of ephemeral ports.
    private(set) var servingEngines: Set<String> = []

    private var process: Process?
    private var adoptedExisting = false
    /// The start currently in flight, so a second caller joins it rather than
    /// racing it. See `start(for:)`.
    private var startTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "asr-server")
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var port: Int { settings.recognizerServerPort }

    var socketURL: URL { URL(string: "ws://127.0.0.1:\(port)")! }
    private var healthURL: URL { URL(string: "http://127.0.0.1:\(port)/health")! }

    /// `~/Library/Application Support/ASRs-R-US/asr/`
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASRs-R-US", isDirectory: true)
            .appendingPathComponent("asr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var modelsDirectory: URL { supportDirectory.appendingPathComponent("models", isDirectory: true) }
    static var pythonURL: URL { supportDirectory.appendingPathComponent("venv/bin/python") }

    /// The sidecar script, from the app bundle, falling back to the source tree
    /// so a debug build run straight out of DerivedData still works.
    static func scriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "asr_server", withExtension: "py") {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Dictation
            .deletingLastPathComponent()      // Sources
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Sidecar/asr_server.py")
        return FileManager.default.isReadableFile(atPath: source.path) ? source : nil
    }

    func modelDirectory(for choice: RecognizerChoice) -> URL? {
        guard let name = choice.modelDirectoryName else { return nil }
        return Self.modelsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// Whether everything the sidecar needs is on disk. Surfaced in Settings so
    /// a missing 1.8 GB model reads as a setup step rather than a crash.
    func installationProblem(for choice: RecognizerChoice) -> String? {
        guard choice.isSidecar else { return nil }
        if !FileManager.default.isExecutableFile(atPath: Self.pythonURL.path) {
            return "The recogniser environment is not installed. Run:  make asr-setup"
        }
        guard let model = modelDirectory(for: choice) else { return nil }
        if !FileManager.default.fileExists(atPath: model.path) {
            return "The \(choice.displayName) model is not downloaded. Run:  make asr-setup"
        }
        if Self.scriptURL() == nil {
            return "asr_server.py is missing from the app bundle."
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Brings up a server for `choice`, restarting if one is up for a different
    /// recogniser.
    ///
    /// Awaits a start already in flight rather than declining to duplicate it.
    /// Returning early there looks harmless and is not: selecting a recogniser
    /// kicks off a start, and opening the panel a few hundred milliseconds
    /// later asks for one again -- so the second caller would see `.starting`,
    /// give up, and report "the recogniser did not start" about a tenth of a
    /// second before it did. Measured, from the log, on the first press of F7
    /// after launch.
    func start(for choice: RecognizerChoice) async {
        guard choice.isSidecar else { return }
        guard let needed = choice.sidecarEngine else { return }

        // Already serving this engine: nothing to do, whichever other
        // recognisers happen to share the process.
        if state.isReady, servingEngines.contains(needed) { return }

        // Join a start already running. It loads every installed engine, so it
        // will satisfy this caller too.
        if let inFlight = startTask {
            await inFlight.value
            return
        }

        let task = Task { await performStart(for: choice) }
        startTask = task
        await task.value
        startTask = nil
    }

    private func performStart(for choice: RecognizerChoice) async {
        if let problem = installationProblem(for: choice) {
            state = .failed(problem)
            return
        }

        // Adopt an already-healthy server rather than fighting it for the port.
        // Unlike llama-server this cannot confirm *which* model it is serving,
        // so adoption only happens when we have not been asked for a different
        // recogniser than the one already running.
        if servingEngines.isEmpty, await isHealthy() {
            adoptedExisting = true
            // An adopted server's engine list is unknown; assume it was
            // started the same way this one would have been. A wrong guess
            // surfaces as a clear "unknown engine" close from the server
            // rather than a silent wrong transcript.
            servingEngines = Set(RecognizerChoice.allCases.compactMap {
                $0.isSidecar ? $0.sidecarEngine : nil
            })
            state = .ready
            log.info("adopted an existing asr_server on port \(self.port)")
            return
        }

        guard let script = Self.scriptURL() else {
            state = .failed("The recogniser sidecar is not installed.")
            return
        }
        // Load every sidecar recogniser whose model is present, not just the
        // selected one. Cross-checking needs them all live at once, and a
        // second process per model would double the Python and the ports for
        // nothing -- one server serves them side by side.
        var engineArguments: [String] = []
        for candidate in RecognizerChoice.allCases where candidate.isSidecar {
            guard let name = candidate.sidecarEngine,
                  let directory = modelDirectory(for: candidate),
                  FileManager.default.fileExists(atPath: directory.path)
            else { continue }
            // Load the selected recogniser, plus the cross-check pair when it
            // is on. Anything else stays off disk and out of memory: Vosk's
            // model alone is 2.7 GB resident.
            let wanted = candidate == choice
                || (settings.crossCheckRecognizers
                    && RecognizerChoice.crossCheckSet.contains(candidate))
            guard wanted else { continue }
            engineArguments += ["--engine", "\(name)=\(directory.path)"]
        }
        guard !engineArguments.isEmpty else {
            state = .failed("No recogniser model is installed. Run:  make asr-setup")
            return
        }

        state = .starting

        let task = Process()
        task.executableURL = Self.pythonURL
        task.arguments = [script.path, "--port", String(port)] + engineArguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // Unbuffered, so the readiness line arrives when it happens rather than
        // when the pipe fills.
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor in self?.observe(output: text) }
        }

        do {
            try task.run()
            process = task
            servingEngines = Set(stride(from: 1, to: engineArguments.count, by: 2).map {
                String(engineArguments[$0].prefix(while: { $0 != "=" }))
            })
            adoptedExisting = false
            log.info("spawned asr_server with \(engineArguments.count / 2) engine(s)")
        } catch {
            state = .failed("Could not start the recogniser: \(error.localizedDescription)")
            return
        }

        // Vosk's model is the slow one; 60s is generous for both.
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if !task.isRunning {
                state = .failed("The recogniser exited unexpectedly (status \(task.terminationStatus)).")
                servingEngines = []
                return
            }
            if await isHealthy() {
                state = .ready
                log.info("asr_server ready")
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        state = .failed("The recogniser did not become ready in time.")
    }

    private func observe(output text: String) {
        if state == .starting, !text.contains("ready") {
            state = .loadingModel
        }
        if text.contains("Traceback") || text.lowercased().contains("error") {
            log.error("asr_server: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        process?.terminate()
        process = nil
        servingEngines = []
        // Leave a server we did not start running.
        if !adoptedExisting { state = .stopped }
        adoptedExisting = false
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }
}
