// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI

@MainActor final class AppModel: ObservableObject {
    let engine = RemotePlayEngine()
    let lighting: AmbientLighting
    enum PlaybackSpace: String { case window, opening, immersive, closing }
    @Published var playbackSpace = PlaybackSpace.window
    var prefersWindow = false
    var windowPresented = false
    var spaceRequest = UUID()
    @Published var host = UserDefaults.standard.string(forKey: "consoleHost") ?? ProcessInfo.processInfo.environment["VRP_CONSOLE_HOST"] ?? ""
    @Published var accountID = ""
    @Published var pairingPIN = ""
    @Published var consoleLoginPIN = ""
    @Published var accountReady = false
    @Published var paired = false
    @Published var consoleName = UserDefaults.standard.string(forKey: "consoleName") ?? "PS5"
    @Published var status = "Connect your PlayStation account, then pair your console."
    @Published var busy = false
    @Published var connected = false
    @Published var showingVideo = false
    @Published var needsLoginPIN = false
    @Published var controllerName: String?
    @Published var error: String?
    @Published var resolution = 1080
    @Published var videoFrames = 0
    @Published var lostFrames = 0
    @Published var audioFrames = 0
    @Published var controllerEvents = 0
    private var account: Data?
    private var pairing: Data?
    private var timer: Timer?
    private var sceneActive = false
    private var windowActive = false
    private var immersiveActive = false
#if DEBUG
    private var ambientProof: AmbientProofFeed?
#endif
    init() {
        lighting = AmbientLighting(video: engine.video)
        account = KeychainStore.load(account: "psn-account-id")
        pairing = KeychainStore.load(account: "console-pairing")
        accountReady = account?.count == 8
        paired = pairing?.count == VRP_PAIRING_SIZE
        if paired { status = "Your console is paired. Ready to play." }
        engine.onStatus = { [weak self] code, message in
            guard let self else { return }
            self.status = message
            switch code {
            case 1: self.busy = true
            case 2: self.connected = true; self.busy = false
            case 3: self.connected = false; self.busy = false; self.showingVideo = false; self.lighting.setPlaying(false)
            case 4: self.needsLoginPIN = true; self.busy = false
            case 5: self.error = message; self.busy = false; self.connected = false; self.showingVideo = false; self.lighting.setPlaying(false)
            case 6: self.error = message
            default: break
            }
            self.writeDiagnostics()
        }
        engine.onRegistered = { [weak self] data, nickname in
            guard let self else { return }
            do {
                try KeychainStore.save(data, account: "console-pairing")
                self.pairing = data; self.paired = true; self.busy = false
                self.consoleName = nickname; self.pairingPIN = ""
                UserDefaults.standard.set(nickname, forKey: "consoleName")
                UserDefaults.standard.set(self.host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "consoleHost")
                self.status = "Paired with \(nickname). Ready to play."
            } catch { self.error = "Could not save pairing securely: \(error.localizedDescription)"; self.busy = false }
            self.writeDiagnostics()
        }
        engine.onController = { [weak self] name in self?.controllerName = name }
        engine.updateController()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        writeDiagnostics()
#if DEBUG
        if ProcessInfo.processInfo.environment["VRP_AMBIENT_PROOF"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, !self.connected else { return }
                let feed = AmbientProofFeed()
                if feed.start(video: self.engine.video) {
                    self.ambientProof = feed
                    self.showingVideo = true
                    self.lighting.setPlaying(true)
                }
            }
        }
        // Uses synthetic data against an explicitly supplied local fixture.
        // Does not read, replace or save the user's account or console pairing.
        if let fixtureHost = ProcessInfo.processInfo.environment["VRP_DIAGNOSTIC_PAIR_HOST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.engine.pair(host: fixtureHost, account: Data(repeating: 0, count: 8), pin: 0)
            }
        }
#endif
    }
    func setSceneActive(_ active: Bool, immersive: Bool = false, background: Bool = false) {
        if immersive { immersiveActive = active } else { windowActive = active }
        sceneActive = windowActive || immersiveActive
        lighting.setSceneActive(sceneActive)
        writeDiagnostics()
        if background {
            // A window closing as the immersive player opens is not the app backgrounding.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self, !self.sceneActive, self.playbackSpace != .opening,
                      self.connected else { return }
                self.disconnect()
            }
        }
    }
    func saveAccount(_ data: Data) {
        guard data.count == 8 else { error = "The account ID must contain eight bytes."; return }
        do {
            try KeychainStore.save(data, account: "psn-account-id")
            account = data; accountReady = true; accountID = ""; error = nil
            status = "PlayStation account linked. Pair your console next."
        } catch { self.error = "Could not save the account ID securely." }
    }
    func saveManualAccount() {
        let text = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = UInt64(text) {
            var little = value.littleEndian
            saveAccount(withUnsafeBytes(of: &little) { Data($0) })
        } else if let data = Data(base64Encoded: text), data.count == 8 { saveAccount(data) }
        else { error = "Enter the numeric PSN account ID or its eight-byte Base64 representation." }
    }
    func pair() {
        guard let account, account.count == 8 else { error = "Link your PlayStation account first."; return }
        let code = pairingPIN.filter(\.isNumber)
        guard code.count == 8, let pin = UInt32(code), !host.isEmpty else { error = "Enter the console IP address and its eight-digit Link Device code."; return }
        error = nil; busy = true
        engine.pair(host: host.trimmingCharacters(in: .whitespacesAndNewlines), account: account, pin: pin)
    }
    func connect() {
        guard let pairing, !host.isEmpty else { return }
#if DEBUG
        ambientProof?.stop(); ambientProof = nil
#endif
        error = nil; busy = true; showingVideo = true
        prefersWindow = false
        lighting.setPlaying(true)
        UserDefaults.standard.set(host, forKey: "consoleHost")
        engine.connect(host: host.trimmingCharacters(in: .whitespacesAndNewlines), pairing: pairing, resolution: resolution)
    }
    func disconnect() {
#if DEBUG
        ambientProof?.stop(); ambientProof = nil
#endif
        lighting.setPlaying(false); engine.disconnect()
    }
    func forget() {
        engine.disconnect(); KeychainStore.remove(account: "console-pairing")
        pairing = nil; paired = false; status = "Pair your console with a new Link Device code."
    }
    private func refreshStats() {
        let video = engine.video.snapshot()
        videoFrames = video.frames; lostFrames = video.lost
        audioFrames = engine.audio.frameCount(); controllerEvents = engine.controllerEventCount()
        if connected && videoFrames > 0 { status = "Playing \(consoleName)" }
        if let message = video.error { error = message }
        writeDiagnostics()
    }
    private func writeDiagnostics() {
        // Never write account identifiers, codes, pairing keys or OAuth tokens here.
        var data: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
            "sceneActive": sceneActive, "paired": paired, "connected": connected,
            "status": status, "videoFramesEnqueued": videoFrames, "audioFramesScheduled": audioFrames,
            "controllerInputEvents": controllerEvents, "lostFramesReported": lostFrames,
            "controllerConnected": controllerName != nil,
            "ambientLighting": lighting.diagnostics(), "playbackSpace": playbackSpace.rawValue,
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "PrototypeSourceSHA") as? String ?? "unknown",
            "sourceDigest": Bundle.main.object(forInfoDictionaryKey: "PrototypeSourceDigest") as? String ?? "unknown"]
#if DEBUG
        if let ambientProof { data["ambientProofFrames"] = ambientProof.framesSent }
#endif
        guard let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("diagnostics.json"),
              let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? encoded.write(to: file, options: .atomic)
    }
}
