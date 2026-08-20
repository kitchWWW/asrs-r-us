import AVFoundation
import Foundation
import os

/// A recogniser running in the sidecar, reached over a websocket.
///
/// `asr_server.py` presents one protocol and adapts the engine behind it, so
/// what this class owns is the socket, the conversion to 16-bit PCM, and the
/// back-pressure policy.
///
/// The audio thread must never block, so `sink` does no I/O: it converts the
/// buffer and hands the bytes to a lock-guarded queue that a separate task
/// drains onto the socket.
///
/// That task runs **off** the main actor, which is the whole reason
/// `pumpLoop` and `receiveLoop` are `nonisolated` and started with
/// `Task.detached`. They were originally plain methods on this `@MainActor`
/// class, so `Task {}` inherited the main actor and the audio pump ran on the
/// main thread -- competing with SwiftUI redrawing the waveform and with the
/// rewrite streaming text into the panel. Whenever the main actor saturated,
/// the pump's tick slipped, the backlog grew, and the queue discarded the
/// oldest audio it held: the *beginning* of what was just said. Nothing
/// logged it, which is why it read as the recogniser mysteriously missing the
/// first word after a pause.
@MainActor
final class SocketRecognizerBackend: RecognizerBackend {

    private let choice: RecognizerChoice
    private let manager: RecognizerServerManager
    private nonisolated let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "recognizer.socket")

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pump: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var finished = false

    /// 16 kHz mono is what both sidecar models are built for.
    ///
    /// When this backend runs alone, `AudioFeeder` converts the microphone
    /// straight to it. When it runs alongside Apple's recogniser they cannot
    /// both be fed their first choice, so `prepareToReceive` may hand over a
    /// different format and `resampler` closes the gap in software. That is a
    /// pure DSP step -- it never touches the audio device, which is the whole
    /// reason the fan-out is safe.
    private(set) var inputFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )

    /// Built once, before the tap exists, when incoming buffers are not
    /// already 16 kHz mono.
    nonisolated let resampler = Resampler()

    /// Shared with the audio thread. A plain class with a lock rather than an
    /// actor: the audio thread cannot await.
    private nonisolated let queue = AudioQueue()

    nonisolated var sink: @Sendable (AVAudioPCMBuffer) -> Void {
        let queue = self.queue
        let resampler = self.resampler
        return { buffer in
            guard let ready = resampler.convert(buffer),
                  let data = pcm16Data(from: ready) else { return }
            queue.push(data)
        }
    }

    func prepareToReceive(_ format: AVAudioFormat) {
        guard let target = inputFormat else { return }
        resampler.prepare(from: format, to: target)
    }

    init(choice: RecognizerChoice, manager: RecognizerServerManager) {
        self.choice = choice
        self.manager = manager
    }

    func prepare() async throws {
        await manager.start(for: choice)
        guard manager.state.isReady else {
            if case .failed(let message) = manager.state {
                throw DictationEngine.DictationError.recognizerUnavailable(message)
            }
            throw DictationEngine.DictationError.recognizerUnavailable("The recogniser did not start.")
        }
    }

    func start(onResult: @escaping (RecognizerResult) -> Void) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        self.session = session

        let socket = session.webSocketTask(with: manager.socketURL)
        self.socket = socket
        socket.resume()

        // The sample rate is validated rather than negotiated -- see the note
        // in asr_server.py. Sending it makes a client/server mismatch an
        // immediate, legible error instead of a quietly worse transcript.
        // Name the engine in the handshake: one sidecar now serves several,
        // and the app opens a connection per recogniser.
        let engine = choice.sidecarEngine ?? "sherpa"
        try await socket.send(.string(#"{"sample_rate": 16000, "engine": "\#(engine)"}"#))

        // Detached, not `Task {}`: this class is `@MainActor`, so an inherited
        // context would put the audio pump on the main thread. See the note at
        // the top of the file -- that is what lost the first word.
        receiver = Task.detached { [weak self] in
            await self?.receiveLoop(socket: socket, onResult: onResult)
        }
        pump = Task.detached { [weak self] in
            await self?.pumpLoop(socket: socket)
        }
    }

    /// Drains the audio queue onto the socket.
    ///
    /// Polls rather than being signalled: a 20 ms tick is far below the
    /// recogniser's own chunk size, costs nothing measurable, and avoids a
    /// condition variable that the audio thread would have to touch.
    nonisolated private func pumpLoop(socket: URLSessionWebSocketTask) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            for chunk in queue.drain() {
                do {
                    try await socket.send(.data(chunk))
                    consecutiveFailures = 0
                } catch {
                    if Task.isCancelled { return }
                    // One failed send is not a dead socket. Giving up on the
                    // first error meant a transient hiccup silently ended
                    // audio for the rest of the session, with the panel still
                    // showing a live recording.
                    consecutiveFailures += 1
                    log.error("audio send failed (\(consecutiveFailures)): \(error.localizedDescription)")
                    if consecutiveFailures >= 5 { return }
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    nonisolated private func receiveLoop(
        socket: URLSessionWebSocketTask,
        onResult: @escaping (RecognizerResult) -> Void
    ) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard case .string(let json) = message,
                      let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = object["text"] as? String
                else { continue }
                let isFinal = (object["final"] as? Bool) ?? false
                await MainActor.run { onResult((text, isFinal)) }
            } catch {
                if !Task.isCancelled {
                    log.error("recogniser socket closed: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    func finish() async {
        guard !finished else { return }
        finished = true

        // Push whatever is still queued before asking for the flush, or the
        // last words are transcribed from audio the server never received.
        if let socket {
            for chunk in queue.drain() {
                try? await socket.send(.data(chunk))
            }
            try? await socket.send(.string("DONE"))
            // Give the server a moment to answer with the final transcript.
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        pump?.cancel()
        receiver?.cancel()
        pump = nil
        receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        queue.reset()
    }
}

/// Audio waiting to go on the wire.
///
/// The ceiling is a backstop, not a working limit. With the pump off the main
/// actor the backlog should never exceed a few buffers; if it reaches a minute
/// of audio something is badly wrong and dropping is the least-bad option, so
/// memory does not grow without bound.
///
/// Two things changed after this silently ate the start of a dictation. The
/// ceiling went from 16 seconds to 60, because 16 was inside the range a
/// stalled pump could reach during an ordinary session. And a drop is now
/// **reported**: it discards the oldest audio, which is the words the speaker
/// has already finished saying and can never get back, and doing that without
/// telling anyone turned a bug into a mystery.
private final class AudioQueue: @unchecked Sendable {

    private let lock = NSLock()
    private var chunks: [Data] = []
    private var bytes = 0
    private let log = Logger(subsystem: "com.brianellis.ASRs-R-US", category: "recognizer.socket")

    /// 60 s * 16000 Hz * 2 bytes.
    private let ceiling = 60 * 16000 * 2

    func push(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(data)
        bytes += data.count
        var dropped = 0
        while bytes > ceiling, !chunks.isEmpty {
            let size = chunks.removeFirst().count
            dropped += size
            bytes -= size
        }
        if dropped > 0 {
            let seconds = Double(dropped) / (16000.0 * 2.0)
            log.error("""
                dropped \(String(format: "%.1f", seconds))s of the oldest audio: \
                the recogniser socket is more than 60s behind. The start of this \
                dictation will be missing.
                """)
        }
    }

    func drain() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let out = chunks
        chunks.removeAll(keepingCapacity: true)
        bytes = 0
        return out
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        chunks.removeAll()
        bytes = 0
    }
}
