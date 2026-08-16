import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appProfiles = AppProfileMap.shared
    @ObservedObject private var profileStore = ProfileStore.shared
    @State private var bedrockTesting = false
    @State private var bedrockResult: (ok: Bool, message: String)?

    private func testBedrock() {
        bedrockTesting = true
        bedrockResult = nil
        let client = BedrockClient(
            modelID: settings.bedrockModelID,
            region: settings.bedrockRegion,
            credentials: AWSCredentialProvider(profile: settings.awsProfile)
        )
        Task {
            do {
                _ = try await client.ping()
                bedrockResult = (true, "Connected — \(settings.bedrockModelID) is reachable.")
            } catch {
                bedrockResult = (false, (error as? LocalizedError)?.errorDescription
                                 ?? error.localizedDescription)
            }
            bedrockTesting = false
        }
    }

    /// Bumped to recompute `logSummary` after the log is deleted.
    @State private var logRefresh = 0

    private var audioSummary: String {
        _ = logRefresh
        let count = SessionAudio.fileCount
        guard count > 0 else { return "No audio recorded yet" }
        return "\(count) recording\(count == 1 ? "" : "s") · \(SessionAudio.sizeDescription)"
    }

    private var annotatedSummary: String {
        _ = logRefresh
        let count = SessionAudio.annotatedCount
        guard count > 0 else { return "Nothing annotated yet" }
        return "\(count) protected recording\(count == 1 ? "" : "s") · \(SessionAudio.annotatedSizeDescription)"
    }

    private var logSummary: String {
        _ = logRefresh
        let count = SessionLog.shared.sessionCount
        guard count > 0 else { return "No sessions logged yet" }
        return "\(count) session\(count == 1 ? "" : "s") · \(SessionLog.shared.fileSizeDescription)"
    }

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
            StatisticsSettingsView().tabItem { Label("Statistics", systemImage: "chart.bar") }
        }
        // Resizable, and taller than it used to be: General grew a recogniser
        // section and the fixed height was silently clipping everything below
        // it, which is how the log and recording rows went missing.
        .frame(minWidth: 620, idealWidth: 620, minHeight: 460, idealHeight: 620)
        .onAppear { accessibilityGranted = HotKeyMonitor.hasAccessibilityPermission }
    }

    /// Says which engine the stepper above is editing, since the value follows
    /// the engine rather than being one global number.
    private var debounceExplanation: String {
        let engine = settings.backend
        let base = "Quiet time before a rewrite fires, kept per engine — this is "
            + "the setting for \(engine.displayName)."
        return settings.isDebounceDefault(for: engine)
            ? base
            : base + " Default is \(engine.defaultDebounceMilliseconds) ms."
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
                if settings.backend == .appleIntelligence {
                    appleIntelligenceRow
                }
            }

            if settings.backend == .bedrock {
            Section("Amazon Bedrock") {
                TextField("Model", text: $settings.bedrockModelID)
                    .textFieldStyle(.roundedBorder)
                TextField("Region", text: $settings.bedrockRegion)
                    .textFieldStyle(.roundedBorder)
                TextField("AWS profile", text: $settings.awsProfile)
                    .textFieldStyle(.roundedBorder)
                Text("Credentials come from the AWS CLI for this profile, so whichever account "
                     + "it resolves to is the one billed. Sessions expire; if rewrites start "
                     + "failing, run `aws login --profile \(settings.awsProfile)`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Test connection") { testBedrock() }
                        .controlSize(.small)
                        .disabled(bedrockTesting)
                    if bedrockTesting { ProgressView().controlSize(.small) }
                    if let result = bedrockResult {
                        Image(systemName: result.ok
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(result.ok ? .green : .orange)
                        Text(result.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
                HStack {
                    Text(debounceExplanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !settings.isDebounceDefault(for: settings.backend) {
                        Button("Reset") {
                            settings.resetDebounceToDefault(for: settings.backend)
                        }
                        .controlSize(.small)
                    }
                }
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

            Section("Profile by app") {
                if appProfiles.recentApps.isEmpty {
                    Text("Apps you dictate into appear here, each with the profile "
                         + "it should use. Nothing is listed until you have dictated "
                         + "somewhere at least once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(appProfiles.recentApps) { app in
                        Picker(selection: appProfiles.binding(
                            for: app.bundleID, fallback: profileStore.defaultProfileID
                        )) {
                            ForEach(profileStore.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if let icon = AppProfileMap.icon(for: app.bundleID) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                }
                                Text(app.name)
                            }
                        }
                        .contextMenu {
                            Button("Remove from list") { appProfiles.forget(app.bundleID) }
                        }
                    }
                    Text("The profile switches when dictation starts, so the panel's "
                         + "own profile menu still overrides it for that session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

            Section("Recognizer") {
                Picker("Speech recognizer", selection: $settings.recognizer) {
                    ForEach(RecognizerChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                Text(settings.recognizer.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show words as early as possible", isOn: $settings.fastRecognition)
                Text("Commits to text sooner so it appears while you are still speaking. "
                     + "Turning it off makes the recogniser wait until a phrase settles, which "
                     + "is slightly more accurate and noticeably less live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Takes effect on the next dictation.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

            Section("Session log") {
                // Every session's transcript is appended to a plain-text file on
                // this Mac, so the way the user actually speaks can be tested
                // against. Nothing is uploaded.
                Toggle("Keep a local log of my dictation", isOn: $settings.logSessions)
                HStack {
                    Text(logSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { SessionLog.shared.revealInFinder() }
                        .controlSize(.small)
                    Button("Delete log") {
                        SessionLog.shared.deleteLog()
                        logRefresh &+= 1
                    }
                    .controlSize(.small)
                }

                Divider()

                // Saves what the recogniser heard, linked to its transcript in
                // the log, so a session can be re-run through a different
                // recogniser instead of being said again. Recorded losslessly
                // and compressed to Opus once the session ends -- about 150 KB a
                // minute, a quarter of the original and measurably no worse to
                // transcribe from. It never leaves this Mac.
                Toggle("Keep a local audio transcript", isOn: $settings.recordSessionAudio)
                Picker("Keep recordings for", selection: $settings.audioRetentionDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("A year").tag(365)
                    Text("Forever").tag(0)
                }
                Picker("Stop at", selection: $settings.audioMaxMegabytes) {
                    Text("500 MB").tag(512)
                    Text("1 GB").tag(1024)
                    Text("5 GB").tag(5120)
                    Text("No limit").tag(0)
                }
                // Deliberately undescribed: the trade-offs between these are
                // long, and they live on `SessionAudio.prune` where the code
                // that acts on them is.
                Picker("Eviction policy", selection: $settings.audioEvictionPolicy) {
                    ForEach(AudioEvictionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                HStack {
                    Text(audioSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { SessionAudio.revealInFinder() }
                        .controlSize(.small)
                    Button("Delete recordings") {
                        SessionAudio.deleteAll()
                        logRefresh &+= 1
                    }
                    .controlSize(.small)
                }
            }


            Section("Annotated set") {
                HStack {
                    Text(annotatedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { SessionAudio.revealAnnotatedInFinder() }
                        .controlSize(.small)
                }
                Text("Recordings you have written a correct transcript for are moved here. "
                     + "That answer took your attention to produce and cannot be regenerated, "
                     + "so these are never deleted and never count toward the ceiling above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Where it all lives") {
                pathRow("Transcripts", url: SessionLog.shared.fileURL)
                pathRow("Annotated", url: SessionAudio.annotatedDirectory)
                pathRow("Recordings", url: SessionAudio.directory)
                pathRow("Statistics", url: StatsStore.shared.fileURL)
                Text("Click any path to show it in Finder. Nothing here is ever uploaded — "
                     + "every path is inside your own Application Support folder, and each "
                     + "one has a delete button above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { if settings.hasAPIKey, keyStatus == .untested { validateNow() } }
    }

    /// One row of "Where it all lives": a path that reveals itself in Finder.
    ///
    /// These used to be inert text. Clicking a path shown in a settings pane is
    /// the obvious thing to try, and doing nothing reads as broken -- so a click
    /// now does exactly what the "Show in Finder" buttons further up do, for the
    /// same locations.
    private func pathRow(_ label: String, url: URL) -> some View {
        LabeledContent(label) {
            Button {
                Self.reveal(url)
            } label: {
                Text(url.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("Show in Finder")
            // Wrapping the path in a button costs `.textSelection`, which was
            // how it got copied before. Hand that back rather than quietly
            // taking it away.
            .contextMenu {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        url.path(percentEncoded: false), forType: .string
                    )
                }
                Button("Show in Finder") { Self.reveal(url) }
            }
        }
    }

    /// Reveals `url` in Finder, falling back to the nearest ancestor that exists.
    ///
    /// `activateFileViewerSelecting` silently does nothing for a path that is
    /// not there, and some of these are only created on first use -- the
    /// recordings folder does not exist until something has been recorded. A
    /// click that appears to do nothing is the very thing this is fixing, so
    /// show the closest location that is actually on disk instead.
    private static func reveal(_ url: URL) {
        let fileManager = FileManager.default
        var target = url
        while !fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            let parent = target.deletingLastPathComponent()
            guard parent != target else { return }
            target = parent
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Apple Intelligence

    @ViewBuilder
    private var appleIntelligenceRow: some View {
        HStack(spacing: 6) {
            if let reason = AppleIntelligenceBackend.unavailableReason {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(reason)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.appleintelligence") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("On-device model ready").font(.caption).foregroundStyle(.green)
                Spacer()
            }
        }
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

                PromptEditor(text: binding.prompt)
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
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include built-in technical vocabulary", isOn: $settings.includeTechVocabulary)

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
        }
        .padding(14)
    }
}
