// SPDX-License-Identifier: AGPL-3.0-only
import GameController
import SwiftUI

@main struct VisionRemotePlayApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup(id: "remote-play") { RemotePlayView(model: model, lighting: model.lighting) }
            .defaultSize(width: 1180, height: 760)
        ImmersiveSpace(id: "ambient-playback") { AmbientPlaybackSpace(model: model, lighting: model.lighting) }
            .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
struct RemotePlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var lighting: AmbientLighting
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var signIn = false
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Play").font(.largeTitle.bold())
                    Text("Your PS5, in your space").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.controllerName ?? "Pair a controller in Settings", systemImage: "gamecontroller")
                    .font(.callout).foregroundStyle(model.controllerName == nil ? .secondary : .primary)
            }
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        GroupBox("Console") {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("PS5 IP address", text: $model.host).textInputAutocapitalization(.never)
                                    .autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                                Text("Use the PS5’s local IP address from Settings → Network → View Connection Status.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Picker("Picture quality", selection: $model.resolution) {
                                    Text("1080p · 60 fps").tag(1080)
                                    Text("720p · 60 fps").tag(720)
                                }.disabled(model.connected || model.busy)
                                Toggle("Ambient lighting", isOn: $lighting.enabled)
                                Picker("Lighting mode", selection: $lighting.mode) {
                                    ForEach(AmbientLightingMode.allCases) { mode in Text(mode.title).tag(mode) }
                                }.pickerStyle(.segmented).disabled(!lighting.enabled)
                            }.padding(.top, 8)
                        }
                        GroupBox("PlayStation account") {
                            VStack(alignment: .leading, spacing: 12) {
                                if model.accountReady {
                                    Label("Account linked on this device", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                                Button(model.accountReady ? "Change PlayStation account" : "Sign in to PlayStation") { signIn = true }
                                    .disabled(model.busy || model.connected)
                                DisclosureGroup("Advanced: enter an account ID", isExpanded: $advanced) {
                                    TextField("Numeric or Base64 account ID", text: $model.accountID)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    Button("Use account ID") { model.saveManualAccount() }
                                }.font(.callout)
                            }.padding(.top, 8)
                        }
                        GroupBox(model.paired ? model.consoleName : "Pair this console") {
                            VStack(alignment: .leading, spacing: 12) {
                                if model.paired {
                                    Label("Console paired", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                                    Button("Play") { model.connect() }.buttonStyle(.borderedProminent)
                                        .disabled(model.connected || model.busy || model.host.isEmpty)
                                    Button("Forget this console", role: .destructive) { model.forget() }
                                        .disabled(model.busy || model.connected).font(.caption)
                                } else {
                                    Text("On PS5, open Settings → System → Remote Play → Link Device, then enter the code below.")
                                        .font(.callout).foregroundStyle(.secondary)
                                    SecureField("Eight-digit Link Device code", text: $model.pairingPIN).keyboardType(.numberPad)
                                    Button("Pair PS5") { model.pair() }.buttonStyle(.borderedProminent)
                                        .disabled(!model.accountReady || model.busy || model.host.isEmpty)
                                }
                            }.padding(.top, 8)
                        }
                        if model.needsLoginPIN {
                            GroupBox("Console user login") {
                                SecureField("Console login PIN", text: $model.consoleLoginPIN)
                                Button("Unlock console user") { model.engine.loginPIN(model.consoleLoginPIN); model.consoleLoginPIN = ""; model.needsLoginPIN = false }
                            }
                        }
                        Text("Built with Chiaki-ng · GNU AGPLv3\nIndependent prototype; not affiliated with Sony.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(width: 350)
                VStack(spacing: 14) {
                    ZStack {
                        if model.playbackSpace == .immersive || model.playbackSpace == .closing {
                            Color.clear
                            Button("Show player") {
                                model.prefersWindow = true
                                model.playbackSpace = .closing
                                Task { await dismissImmersiveSpace() }
                            }
                        } else {
                            StreamView(pipeline: model.engine.video)
                        }
                        if !model.showingVideo {
                            ContentUnavailableView("Ready when you are", systemImage: "play.rectangle",
                                description: Text("Pair your console, then play on your virtual screen."))
                        } else if model.videoFrames == 0 {
                            ProgressView("Waiting for your PS5’s picture…")
                        }
                    }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
                    .background {
                        if lighting.enabled { AmbientHalo(palette: lighting.palette).padding(-38) }
                    }
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.status).font(.callout)
                        Spacer()
                        if model.connected || model.busy {
                            Button("PS button") { model.engine.pressPS() }.disabled(!model.connected)
                            Button("Disconnect") { model.disconnect() }
                        }
                    }
                    if let error = model.error {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(error).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Dismiss", systemImage: "xmark") { model.error = nil }.labelStyle(.iconOnly)
                        }.font(.callout).foregroundStyle(.red).padding().background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.videoFrames > 0 {
                        HStack(spacing: 20) {
                            Label("\(model.videoFrames) video frames", systemImage: "film")
                            Label("Audio \(model.audioFrames > 0 ? "active" : "waiting")", systemImage: "speaker.wave.2")
                            Text("Lost frames: \(model.lostFrames)")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity)
            }
        }.padding(28)
        .handlesGameControllerEvents(matching: .gamepad)
        .sheet(isPresented: $signIn) { PlayStationSignIn { model.saveAccount($0) } }
        .onAppear { model.windowPresented = true; model.setSceneActive(true); model.engine.updateController(); presentAmbientPlayer() }
        .onDisappear { model.windowPresented = false; model.setSceneActive(false) }
        .onChange(of: model.showingVideo) { _, playing in if playing { presentAmbientPlayer() } }
        .onChange(of: lighting.enabled) { _, enabled in
            if enabled { model.prefersWindow = false; presentAmbientPlayer() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setSceneActive(phase == .active, background: phase == .background)
        }
    }
    private func presentAmbientPlayer() {
        guard model.showingVideo, lighting.enabled, !model.prefersWindow,
              model.playbackSpace == .window else { return }
        model.playbackSpace = .opening
        let request = UUID()
        model.spaceRequest = request
        Task { @MainActor in
            let result = await openImmersiveSpace(id: "ambient-playback")
            guard model.spaceRequest == request else { return }
            switch result {
            case .opened:
                guard model.showingVideo else {
                    model.playbackSpace = .closing
                    await dismissImmersiveSpace()
                    return
                }
                model.playbackSpace = .immersive
                dismissWindow(id: "remote-play")
            case .userCancelled, .error:
                model.playbackSpace = .window
                model.prefersWindow = true
            @unknown default:
                model.playbackSpace = .window
                model.prefersWindow = true
            }
        }
    }
}
