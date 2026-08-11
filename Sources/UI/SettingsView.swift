import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var server: LlamaServerManager
    @State private var accessibilityGranted = HotKeyMonitor.hasAccessibilityPermission
    @State private var keyStatus: KeyStatus = .untested
    @State private var validationTask: Task<Void, Never>?

    /// Result of a live hello-world call, so the user gets a definite answer
    /// instead of discovering a bad key mid-dictation.
    enum KeyStatus: Equatable {
        case untested
        case checking
        case working
        case failed(String)
    }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettingsView().tabItem { Label("Profiles", systemImage: "person.2") }
            DictionarySettingsView().tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .frame(width: 620, height: 460)
        .onAppear { accessibilityGranted = HotKeyMonitor.hasAccessibilityPermission }
    }

    private var general: some View {
        Form {
            Section("Rewrite engine") {
                Picker("Engine", selection: $settings.backend) {
                    ForEach(RewriteBackendKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                if settings.backend == .local {
                    localEngineRows
                }
            }

            if settings.backend == .anthropic {
            Section("Anthropic") {
                SecureField("API key", text: $settings.apiKey, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: settings.apiKey) { scheduleValidation() }

                keyStatusRow

                Picker("Model", selection: $settings.model) {
                    Text("Claude Haiku 4.5 (fastest)").tag("claude-haiku-4-5")
                    Text("Claude Sonnet 5").tag("claude-sonnet-5")
                    Text("Claude Opus 5").tag("claude-opus-5")
                }
                .onChange(of: settings.model) { scheduleValidation() }
            }
            }

            Section("Rewrite timing") {
                Stepper(
                    "Debounce: \(settings.debounceMilliseconds) ms",
                    value: $settings.debounceMilliseconds,
                    in: 120...2000,
                    step: 50
                )
            }

            Section("Insertion") {
                Picker("Method", selection: $settings.insertionMethod) {
                    Text("Paste (fast)").tag(TextInserter.Method.paste)
                    Text("Type (never touches clipboard)").tag(TextInserter.Method.type)
                }
                if settings.insertionMethod == .paste {
                    Toggle("Restore my clipboard afterwards", isOn: $settings.restorePasteboard)
                }
            }

            Section("Hotkey") {
                HStack {
                    Text("Open dictation")
                    Spacer()
                    ShortcutRecorder(binding: $settings.hotKey)
                    Button("Reset") { settings.hotKey = .f7 }
                        .controlSize(.small)
                        .disabled(settings.hotKey == .f7)
                }
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: accessibilityGranted
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(accessibilityGranted ? .green : .orange)
                    Text(accessibilityGranted
                         ? "Accessibility access granted"
                         : "Accessibility access required for the F7 hotkey and pasting")
                        .font(.callout)
                    Spacer()
                    if !accessibilityGranted {
                        Button("Open Settings") { HotKeyMonitor.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if settings.hasAPIKey, keyStatus == .untested { validateNow() } }
    }

    // MARK: - Local engine

    @ViewBuilder
    private var localEngineRows: some View {
        HStack(spacing: 6) {
            switch server.state {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Local model running")
                    .font(.caption).foregroundStyle(.green)
            case .starting:
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Starting local model…").font(.caption).foregroundStyle(.secondary)
            case .preparingModel:
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Downloading model…")
                    .font(.caption).foregroundStyle(.secondary)
            case .stopped:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Not running").font(.caption).foregroundStyle(.secondary)
            case let .failed(message):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Restart") { Task { await server.restart() } }
                .controlSize(.small)
        }

        TextField("Model repo", text: $settings.localModelRepo)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
    }

    // MARK: - API key validation

    @ViewBuilder
    private var keyStatusRow: some View {
        HStack(spacing: 6) {
            switch keyStatus {
            case .untested:
                if settings.hasAPIKey {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("Not tested yet").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("No API key set").font(.caption).foregroundStyle(.secondary)
                }
            case .checking:
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                Text("Testing key…").font(.caption).foregroundStyle(.secondary)
            case .working:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("API key is stored and working properly")
                    .font(.caption).foregroundStyle(.green)
            case let .failed(message):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message)
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Test") { validateNow() }
                .controlSize(.small)
                .disabled(!settings.hasAPIKey || keyStatus == .checking)
        }
    }

    /// Debounced so we do not fire a request on every keystroke while a key is
    /// being pasted or typed.
    private func scheduleValidation() {
        validationTask?.cancel()
        guard settings.hasAPIKey else {
            keyStatus = .untested
            return
        }
        keyStatus = .checking
        validationTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await runValidation()
        }
    }

    private func validateNow() {
        validationTask?.cancel()
        keyStatus = .checking
        validationTask = Task { await runValidation() }
    }

    private func runValidation() async {
        let client = AnthropicClient(apiKey: settings.apiKey)
        do {
            _ = try await client.ping(model: settings.model)
            guard !Task.isCancelled else { return }
            keyStatus = .working
        } catch {
            guard !Task.isCancelled else { return }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            keyStatus = .failed(message)
        }
    }

}


/// Master-detail editor: profiles on the left, that profile's prompt on the right.
struct ProfilesSettingsView: View {
    @ObservedObject private var store = ProfileStore.shared
    @State private var renaming: Profile.ID?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 160, idealWidth: 180, maxWidth: 260)
            detail
                .frame(minWidth: 320, maxWidth: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedID) {
                ForEach(store.profiles) { profile in
                    HStack(spacing: 6) {
                        Image(systemName: profile.id == store.selectedID
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(profile.id == store.selectedID ? Color.green : Color.secondary.opacity(0.5))
                        Text(profile.name).lineLimit(1)
                    }
                    .tag(profile.id)
                    .contextMenu {
                        Button("Duplicate") { store.duplicate(profile) }
                        Button("Delete", role: .destructive) { store.remove(profile.id) }
                            .disabled(store.profiles.count <= 1)
                    }
                }
                .onMove { indices, destination in
                    store.profiles.move(fromOffsets: indices, toOffset: destination)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 2) {
                Button {
                    store.addProfile()
                    renaming = store.selectedID
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a profile")

                Button {
                    store.remove(store.selectedID)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(store.profiles.count <= 1)
                .help("Delete the selected profile")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let binding = store.binding(for: store.selectedID) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Profile name", text: binding.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .semibold))
                    Button("Reset prompt") {
                        binding.wrappedValue.prompt = ProfileStore.template(styleFor: nil)
                    }
                    .controlSize(.small)
                }

                TextEditor(text: binding.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            )
                    )
            }
            .padding(14)
        } else {
            Text("Select a profile").foregroundStyle(.secondary)
        }
    }
}


/// Free-form vocabulary list, one entry per line.
struct DictionarySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let placeholder = """
    piece (music, not "peace")
    ASR
    TTS
    """

    var body: some View {
        TextEditor(text: $settings.dictionary)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.08))
                    )
            )
            .overlay(alignment: .topLeading) {
                if settings.dictionary.isEmpty {
                    Text(Self.placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .padding(14)
    }
}
