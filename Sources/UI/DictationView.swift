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

    init(session: SessionController) {
        self.session = session
        self.dictation = session.dictation
        self.rewriter = session.rewriter
    }

    var body: some View {
        VStack(spacing: 0) {
            header

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
        .background {
            // One glass slab for the whole panel. Inner surfaces stay plain so
            // text keeps its contrast -- stacking glass on glass turns muddy.
            //
            // The scrim underneath is what makes it readable: glass alone is
            // transparent enough that whatever is behind the window competes
            // with the transcript.
            // Deliberately thin: the chrome is where the transparency should
            // live. Legibility is bought back on the text panes instead, which
            // are near-opaque -- rather than by fogging the whole window, which
            // costs the glass everywhere and still leaves text on a busy field.
            ZStack {
                panelShape.glassEffect(.regular, in: panelShape)
                // A light veil, not a fog. The panes cover the middle of the
                // window, so this is only really visible behind the header and
                // footer -- exactly where controls need to out-read whatever is
                // on screen behind them.
                panelShape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.22))
            }
        }
        .overlay {
            // Bright inner rim, the way a real pane of glass catches light at
            // its edge.
            panelShape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .clipShape(panelShape)
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

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    micPicker

                    Button {
                        session.clearAndRestart()
                    } label: {
                        Label("Clear", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                    .help("Clear everything and start listening again")
                }
            }
        }
        .padding(.leading, 32)      // just clears the traffic-light close button
        .padding(.trailing, 14)
        .frame(height: 34)
    }

    /// Shows which microphone is in use, not just that one can be chosen.
    ///
    /// Built from `Menu` rather than `Picker`: a picker draws its own opaque
    /// popup-button chrome, which reads as a stock control sitting on top of
    /// the glass instead of part of it.
    private var micPicker: some View {
        Menu {
            Picker("Microphone", selection: micBinding) {
                ForEach(deviceStore.devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            pillLabel(currentMicName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
        .help("Microphone")
    }

    private var currentMicName: String {
        let uid = deviceStore.resolvedUID(for: session.settings.inputDeviceUID)
        return deviceStore.devices.first { $0.uid == uid }?.name ?? "Microphone"
    }

    /// Shared pill content so every glass control lines up on the same metrics.
    ///
    /// Sized to match the adjacent `.glass` buttons: a menu that is visibly
    /// shorter than the button beside it reads as a different class of control.
    /// The disclosure chevron is drawn by the borderless menu style itself --
    /// `.menuIndicator(.hidden)` is not honoured here, so adding one of our own
    /// only produced a second, redundant glyph.
    private func pillLabel(_ title: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 22)
    }

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
            // Highlighted rather than greyed: dimming the newest words makes the
            // part you are actively speaking the hardest part to read.
            volatilePart.foregroundColor = .primary
            volatilePart.backgroundColor = Color.accentColor.opacity(0.16)
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
                Button {
                    Task { await useTranscriptAction?() }
                } label: {
                    if session.isInserting {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Text("Use transcript")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.glass)
                .disabled(!session.canInsertTranscript || session.isInserting)
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

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    /// Near-opaque reading surface. Text is the one thing in the window that
    /// should not have to compete with whatever is behind it, so the panes stay
    /// solid while everything around them stays glass.
    private var boxBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return shape
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.93))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 0.5
                )
            )
            .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
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
                // Matches the section labels rather than sitting a step lighter:
                // the destination app is worth reading, not a footnote.
                Label(target.localizedName ?? "target app", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Text will be pasted into \(target.localizedName ?? "the previous app")")
            }

            Spacer(minLength: 8)

            Text("esc to close")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    profilePicker
                    useButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var useButton: some View {
        Button {
            Task { await useAction?() }
        } label: {
                Group {
                    if session.isInserting {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Text("Use")
                    }
                }
                // Keeps the button from resizing as the label swaps for the
                // spinner.
                .frame(minWidth: 26)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.glassProminent)
            .disabled(!session.canInsert || session.isInserting)
            .help(useHelpText)
    }

    /// Switching profile re-runs the rewrite so the change is visible
    /// immediately rather than only affecting the next sentence.
    private var profilePicker: some View {
        Menu {
            Picker("Profile", selection: profileBinding) {
                ForEach(session.profiles.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            pillLabel(session.profiles.active.name)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
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
