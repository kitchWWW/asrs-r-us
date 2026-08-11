import SwiftUI

/// The two-box dictation window: raw transcript on top, polished text below.
struct DictationView: View {
    @ObservedObject var session: SessionController
    @ObservedObject private var dictation: DictationEngine
    @ObservedObject private var rewriter: RewriteService
    @ObservedObject private var deviceStore = AudioDeviceStore.shared

    private var escapeAction: (() -> Void)?
    private var useAction: (() async -> Void)?
    private var useTranscriptAction: (() async -> Void)?

    @FocusState private var outputFocused: Bool
    @State private var isInserting = false

    init(session: SessionController) {
        self.session = session
        self.dictation = session.dictation
        self.rewriter = session.rewriter
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(spacing: 7) {
                transcriptBox
                outputBox
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if let error = session.lastError {
                errorBar(error)
            }

            footer
        }
        .frame(minWidth: 460, minHeight: 320)
        .background(.regularMaterial)
        .onExitCommand { escapeAction?() }
    }

    // MARK: - Header

    /// One compact row. The panel uses `fullSizeContentView`, so this sits
    /// level with the close button rather than below a reserved titlebar --
    /// the leading inset is what keeps it clear of that button.
    private var header: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()

            WaveformView(
                levels: dictation.levelHistory,
                isActive: dictation.isRecording
            )
            .opacity(dictation.isRecording ? 1 : 0.35)

            Spacer(minLength: 8)

            micPicker

            Button {
                session.clearAndRestart()
            } label: {
                Label("Clear", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
            .help("Clear everything and start listening again")
        }
        .padding(.leading, 32)      // just clears the traffic-light close button
        .padding(.trailing, 14)
        .frame(height: 34)
    }

    /// Shows which microphone is in use, not just that one can be chosen.
    private var micPicker: some View {
        Picker(selection: micBinding) {
            ForEach(deviceStore.devices) { device in
                Text(device.name).tag(device.uid)
            }
        } label: {
            Image(systemName: "mic")
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: 190)
        .help("Microphone")
    }

    /// Reads through to the resolved device so the built-in mic shows as the
    /// selection by default, rather than an empty "automatic" row.
    private var micBinding: Binding<String> {
        Binding(
            get: { deviceStore.resolvedUID(for: session.settings.inputDeviceUID) },
            // Deferred: switching device restarts the audio engine, which makes
            // CoreAudio republish its device list and SwiftUI rebuild this very
            // menu. Doing that synchronously frees the action mid-dispatch and
            // crashes with a null call.
            set: { uid in
                DispatchQueue.main.async { session.changeInputDevice(uid: uid) }
            }
        )
    }

    private var statusText: String {
        switch dictation.state {
        case .preparing: return "Starting microphone…"
        case .recording: return "Listening"
        case .failed:    return "Dictation stopped"
        case .idle:      return session.transcript.isEmpty ? "Press F7 to dictate" : "Stopped"
        }
    }

    // MARK: - Boxes

    private var transcriptBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            boxLabel("Transcript", systemImage: "waveform")
            ScrollView {
                Text(attributedTranscript)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 90)
            .background(boxBackground)
        }
    }

    /// Finalized text reads normally; the volatile tail is dimmed so it is
    /// obvious which words the recognizer may still revise.
    private var attributedTranscript: AttributedString {
        var result = AttributedString(dictation.finalizedText)
        result.foregroundColor = .primary
        if !dictation.volatileText.isEmpty {
            var volatilePart = AttributedString(
                (dictation.finalizedText.isEmpty ? "" : " ") + dictation.volatileText
            )
            volatilePart.foregroundColor = .secondary
            result.append(volatilePart)
        }
        if result.characters.isEmpty {
            var placeholder = AttributedString("Speak and your words appear here.")
            placeholder.foregroundColor = Color(nsColor: .tertiaryLabelColor)
            return placeholder
        }
        return result
    }

    private var outputBox: some View {
        // Matches the spacing above the row so the "Use transcript" button
        // sits centered between the two boxes rather than hugging the editor.
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                boxLabel("Rewritten", systemImage: "sparkles")
                Spacer()
                if !session.editTracker.edits.isEmpty {
                    Text("^[\(session.editTracker.edits.count) edit](inflect: true) tracked")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button("Use transcript") {
                    Task {
                        isInserting = true
                        await useTranscriptAction?()
                        isInserting = false
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(!session.canInsertTranscript || isInserting)
                .help("Paste the raw transcript instead of the rewrite")
            }

            RewrittenEditor(
                text: outputBinding,
                showsPendingCaret: rewriter.isPending,
                placeholder: "The polished version appears here. You can edit it directly."
            )
            .frame(minHeight: 120)
            .background(boxBackground)
            .focused($outputFocused)
        }
    }

    /// Reads from the rewriter, writes through the session so every keystroke
    /// is recorded as a tracked edit.
    private var outputBinding: Binding<String> {
        Binding(
            get: { rewriter.output },
            set: { session.userDidEdit($0) }
        )
    }

    private func boxLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var boxBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }

    // MARK: - Error + footer

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { session.clearError() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let target = session.targetApp {
                Label(target.localizedName ?? "target app", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Text will be pasted into \(target.localizedName ?? "the previous app")")
            }

            Spacer(minLength: 8)

            Text("esc to close")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)

            profilePicker

            Button {
                Task {
                    isInserting = true
                    await useAction?()
                    isInserting = false
                }
            } label: {
                if isInserting {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Text("Use")
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!session.canInsert || isInserting)
            .help(useHelpText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Switching profile re-runs the rewrite so the change is visible
    /// immediately rather than only affecting the next sentence.
    private var profilePicker: some View {
        Picker("", selection: profileBinding) {
            ForEach(session.profiles.profiles) { profile in
                Text(profile.name).tag(profile.id)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Rewrite style")
    }

    private var useHelpText: String {
        session.hasUserEdited
            ? "Paste the rewritten text at the cursor (Cmd-Return)"
            : "Paste the rewritten text at the cursor (Return)"
    }

    private var profileBinding: Binding<Profile.ID> {
        Binding(
            get: { session.profiles.selectedID },
            set: { session.switchProfile(to: $0) }
        )
    }
}

// MARK: - Action injection

extension DictationView {
    func onEscape(_ action: @escaping () -> Void) -> DictationView {
        var copy = self
        copy.escapeAction = action
        return copy
    }

    func onUse(_ action: @escaping () async -> Void) -> DictationView {
        var copy = self
        copy.useAction = action
        return copy
    }

    func onUseTranscript(_ action: @escaping () async -> Void) -> DictationView {
        var copy = self
        copy.useTranscriptAction = action
        return copy
    }
}
