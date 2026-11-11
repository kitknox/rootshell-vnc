import SwiftUI
import RFBProtocol
import os

private enum AppConnectionMode: CaseIterable, Identifiable {
    case highPerformance
    case standard

    var id: Self { self }

    var title: String {
        switch self {
        case .highPerformance:
            String(localized: "High Performance", bundle: .module, comment: "VNC connection mode")
        case .standard:
            String(localized: "Standard", bundle: .module, comment: "VNC connection mode")
        }
    }
}

private enum StandardQuality: CaseIterable, Identifiable {
    case adaptive
    case fullQuality

    var id: Self { self }

    var title: String {
        switch self {
        case .adaptive:
            String(localized: "Adaptive", bundle: .module, comment: "VNC standard-mode quality")
        case .fullQuality:
            String(localized: "Full Quality", bundle: .module, comment: "VNC standard-mode quality")
        }
    }
}

/// A form view for entering VNC server connection details and initiating a connection.
///
/// On successful connection, the view navigates to a ``RemoteDesktopView``
/// displaying the remote desktop.
///
/// Usage:
/// ```swift
/// ConnectionView(session: vncSession)
/// ```
public struct ConnectionView: View {

    // MARK: - Properties

    @Bindable var session: VNCSession
    @Environment(\.displayScale) private var displayScale

    @State private var host: String = ""
    @State private var port: String = "5900"
    @State private var password: String = ""
    @State private var username: String = ""
    @State private var isConnecting: Bool = false
    @State private var errorMessage: String?
    @State private var showRemoteDesktop: Bool = false
    @State private var restoredSavedConnection: Bool = false

    private let logger = Logger(
        subsystem: "com.rootshell.vnc",
        category: "Credentials")

    // MARK: - Init

    /// Create a connection view bound to the given VNC session.
    ///
    /// - Parameter session: The VNC session to use for the connection.
    public init(session: VNCSession) {
        self.session = session
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Form {
                serverSection
                authenticationSection
                qualitySection
                displaySizingSection
                if session.configuration.supportsRemoteAudio {
                    audioSection
                }
                statusSection
                connectSection
            }
            .background {
                // Capture the window/phone viewport before Connect is tapped.
                // Match Client can then be negotiated before the first Apple
                // media stream instead of after navigation to the desktop.
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            prepareRemoteDisplaySize(geometry.size)
                        }
                        .onChange(of: geometry.size) { _, newSize in
                            prepareRemoteDisplaySize(newSize)
                        }
                        .onChange(of: displayScale) { _, _ in
                            prepareRemoteDisplaySize(geometry.size)
                        }
                        .onChange(of: session.configuration.displaySizingMode) { _, mode in
                            if mode == .matchClient {
                                prepareRemoteDisplaySize(geometry.size)
                            }
                        }
                        .onChange(of: session.configuration.videoQualityMode) { _, _ in
                            prepareRemoteDisplaySize(geometry.size)
                        }
                        .onChange(of: session.configuration.displayMode) { _, _ in
                            prepareRemoteDisplaySize(geometry.size)
                        }
                }
            }
            .navigationTitle(String(localized: "Connect to VNC Server", bundle: .module))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .navigationDestination(isPresented: $showRemoteDesktop) {
                RemoteDesktopView(session: session)
                    #if os(iOS)
                    .navigationBarBackButtonHidden()
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .destructiveAction) {
                            Button(String(localized: "Disconnect", bundle: .module)) {
                                session.disconnect()
                                showRemoteDesktop = false
                            }
                        }
                    }
            }
            .onChange(of: session.connectionState) { _, newValue in
                switch newValue {
                case .connected:
                    isConnecting = false
                    errorMessage = nil
                    showRemoteDesktop = true
                case .failed(let reason):
                    isConnecting = false
                    errorMessage = reason
                case .disconnected:
                    isConnecting = false
                    showRemoteDesktop = false
                default:
                    break
                }
            }
            .task {
                restoreLastConnectionIfNeeded()
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section(String(localized: "Server", bundle: .module)) {
            HStack {
                Text(String(localized: "Host", bundle: .module))
                    .frame(width: 80, alignment: .leading)
                TextField(String(localized: "hostname or IP address", bundle: .module), text: $host)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                    .submitLabel(.next)
            }

            HStack {
                Text(String(localized: "Port", bundle: .module))
                    .frame(width: 80, alignment: .leading)
                TextField("5900", text: $port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .submitLabel(.next)
            }
        }
    }

    private var authenticationSection: some View {
        Section(String(localized: "Authentication", bundle: .module)) {
            HStack {
                Text(String(localized: "Username", bundle: .module))
                    .frame(width: 80, alignment: .leading)
                TextField(String(localized: "optional", bundle: .module), text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                    .disableAutocorrection(true)
                    .submitLabel(.next)
            }

            HStack {
                Text(String(localized: "Password", bundle: .module))
                    .frame(width: 80, alignment: .leading)
                SecureField(String(localized: "required", bundle: .module), text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(initiateConnection)
            }

            Toggle(
                String(localized: "Prompt at Mac Login", bundle: .module),
                isOn: $session.configuration.promptForLoginPasswordAtLoginWindow)
            Text(String(
                localized: "When an Apple Login Window or lock screen is detected, offer to type the saved password.",
                bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioSection: some View {
        Section(String(localized: "Audio", bundle: .module)) {
            Toggle(String(localized: "Play Remote Audio", bundle: .module), isOn: $session.configuration.enableRemoteAudio)
            Text(String(localized: "Play the remote Mac's system audio when the server offers it.", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var qualitySection: some View {
        Section(String(localized: "Display Quality", bundle: .module)) {
            Picker(String(localized: "Connection Mode", bundle: .module), selection: connectionMode) {
                ForEach(AppConnectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)

            if connectionMode.wrappedValue == .standard {
                Picker(String(localized: "Quality", bundle: .module), selection: standardQuality) {
                    ForEach(StandardQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.menu)
            }

            Text(session.configuration.videoQualityMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionMode: Binding<AppConnectionMode> {
        Binding {
            session.configuration.videoQualityMode == .adaptive
                ? .highPerformance
                : .standard
        } set: { mode in
            switch mode {
            case .highPerformance:
                session.configuration.videoQualityMode = .adaptive
            case .standard:
                if session.configuration.videoQualityMode == .adaptive {
                    session.configuration.videoQualityMode = .standard
                }
            }
        }
    }

    private var standardQuality: Binding<StandardQuality> {
        Binding {
            session.configuration.videoQualityMode == .fullQuality
                ? .fullQuality
                : .adaptive
        } set: { quality in
            session.configuration.videoQualityMode = switch quality {
            case .adaptive: .standard
            case .fullQuality: .fullQuality
            }
        }
    }

    private var displaySizingSection: some View {
        Section(String(localized: "Remote Display Size", bundle: .module)) {
            if session.configuration.displaySizingMode == .matchClient {
                LabeledContent(
                    String(localized: "Display Mode", bundle: .module),
                    value: String(localized: "One Virtual Display", bundle: .module))
                Text(String(localized: "Match Client currently creates one client-sized virtual display.", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker(String(localized: "Display Mode", bundle: .module), selection: $session.configuration.displayMode) {
                    Text(VNCConfiguration.DisplayMode.oneDisplay.title)
                        .tag(VNCConfiguration.DisplayMode.oneDisplay)
                    Text(VNCConfiguration.DisplayMode.allDisplaysCombined.title)
                        .tag(VNCConfiguration.DisplayMode.allDisplaysCombined)
                }
                .pickerStyle(.menu)

                Text(session.configuration.displayMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(String(localized: "Sizing", bundle: .module), selection: $session.configuration.displaySizingMode) {
                ForEach(VNCConfiguration.DisplaySizingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(session.configuration.displaySizingMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let errorMessage {
            Section {
                Label {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var connectSection: some View {
        Section {
            Button(action: initiateConnection) {
                HStack {
                    Spacer()
                    if isConnecting {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text(String(localized: "Connecting...", bundle: .module))
                    } else {
                        Text(String(localized: "Connect", bundle: .module))
                    }
                    Spacer()
                }
            }
            .disabled(!canConnect)
        }
    }

    // MARK: - Actions

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UInt16(port).map { $0 > 0 } == true
            && !isConnecting
            && session.connectionState.canConnect
    }

    private func initiateConnection() {
        guard canConnect else { return }

        errorMessage = nil
        isConnecting = true

        guard let portNumber = UInt16(port), portNumber > 0 else {
            errorMessage = String(
                localized: "Enter a valid port between 1 and 65535.",
                bundle: .module)
            isConnecting = false
            return
        }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = VNCCredentials(
            host: normalizedHost,
            port: portNumber,
            password: password,
            username: normalizedUsername.isEmpty ? nil : normalizedUsername
        )

        Task {
            do {
                try await session.connect(credentials: credentials)
                do {
                    try LastConnectionCredentialStore.save(credentials)
                } catch {
                    logger.error(
                        "Could not save last connection in Keychain: \(error.localizedDescription, privacy: .private)")
                }
            } catch is CancellationError {
                isConnecting = false
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func restoreLastConnectionIfNeeded() {
        guard !restoredSavedConnection else { return }
        restoredSavedConnection = true
        do {
            guard let credentials = try LastConnectionCredentialStore.load() else { return }
            host = credentials.host
            port = String(credentials.port)
            username = credentials.username ?? ""
            password = credentials.password
        } catch {
            logger.error(
                "Could not restore last connection from Keychain: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func prepareRemoteDisplaySize(_ size: CGSize) {
        session.updateRemoteDisplaySize(
            viewSize: size,
            displayScale: displayScale)
    }
}
