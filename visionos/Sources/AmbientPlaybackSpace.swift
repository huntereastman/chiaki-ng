// SPDX-License-Identifier: AGPL-3.0-only
import GameController
import RealityKit
import SwiftUI

private struct PlayerFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue(); if !next.isEmpty { value = next }
    }
}

@MainActor private final class AmbientRoomRig {
    let root = Entity()
    private let left = Entity(), right = Entity()

    init() {
        root.position = [0, 1.3, -2.1]
        root.addChild(left); root.addChild(right)
        left.look(at: [-2.5, -0.2, -1.3], from: [-0.55, 0, -0.12], relativeTo: root)
        right.look(at: [2.5, -0.2, -1.3], from: [0.55, 0, -0.12], relativeTo: root)
    }
    func attachPlayer(_ player: ViewAttachmentEntity) {
        if player.parent == nil { root.addChild(player) }
        let width = player.visualBounds(relativeTo: root).extents.x
        if width > 0, abs(width - 2.3) > 0.005 {
            player.scale *= SIMD3(repeating: 2.3 / width)
        }
    }
    func update(_ palette: AmbientPalette, enabled: Bool) {
        for (entity, color) in [(left, palette.left), (right, palette.right)] {
            let active = enabled && color.luminance > 0.0005
            entity.components.set(SpotLightComponent(color: color.uiColor,
                intensity: active ? 650 : 0, innerAngleInDegrees: 35,
                outerAngleInDegrees: 80, attenuationRadius: 3.2))
            if #available(visionOS 27.0, *) {
                if active { entity.components.set(SpotLightComponent.SurroundingsLight()) }
                else { entity.components.remove(SpotLightComponent.SurroundingsLight.self) }
            }
        }
    }
}

@MainActor struct AmbientPlaybackSpace: View {
    @ObservedObject var model: AppModel
    @ObservedObject var lighting: AmbientLighting
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rig = AmbientRoomRig()
    @State private var extreme: ExtremeLightRig?
    @State private var playerFrame = CGRect(x: 200, y: 146, width: 1180, height: 663.75)
    @State private var controlsVisible = true
    @State private var controlInteraction = 0

    var body: some View {
        RealityView { content, attachments in
            content.add(rig.root)
            if let player = attachments.entity(for: "player") {
                rig.attachPlayer(player)
            }
            rig.update(lighting.palette, enabled: lighting.enabled && lighting.mode == .simple && lighting.roomLightAllowed)
            do {
                let effect = try await ExtremeLightRig()
                guard !Task.isCancelled, model.showingVideo, model.playbackSpace != .closing else { effect.stop(); return }
                rig.root.addChild(effect.root)
                extreme = effect
                lighting.extremeError = nil
                effect.subscribe(to: content) { lighting.extremeDiagnostics = $0 }
                updateExtreme(attachments.entity(for: "player"))
            } catch {
                lighting.extremeError = "Extreme could not start. Simple is available."
                lighting.extremeDiagnostics = ["loadError": error.localizedDescription]
            }
        } update: { _, attachments in
            if let player = attachments.entity(for: "player") { rig.attachPlayer(player) }
            rig.update(lighting.palette, enabled: lighting.enabled && lighting.mode == .simple && lighting.roomLightAllowed)
            updateExtreme(attachments.entity(for: "player"))
        } attachments: {
            Attachment(id: "player") {
                VStack(spacing: 28) {
                    ZStack {
                        if lighting.enabled && lighting.mode == .simple {
                            AmbientHalo(palette: lighting.palette).padding(-140)
                        }
                        StreamView(pipeline: model.engine.video)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                            .shadow(color: .black.opacity(0.65), radius: 28, y: 18)
                        if model.videoFrames == 0 { ProgressView().controlSize(.large) }
                    }.frame(width: 1180, height: 663.75)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: PlayerFrameKey.self, value: geometry.frame(in: .named("ambient-player")))
                        })
                    HStack(spacing: 24) {
                        Toggle(isOn: $lighting.enabled) {
                            Label("Ambient lighting", systemImage: "lightbulb.max.fill")
                        }.toggleStyle(.button)
                        Picker("Lighting mode", selection: $lighting.mode) {
                            ForEach(AmbientLightingMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.segmented).frame(width: 260).disabled(!lighting.enabled)
                        Button("PS button", systemImage: "gamecontroller") { model.engine.pressPS() }
                            .labelStyle(.iconOnly).disabled(!model.connected)
                        Button("Window", systemImage: "rectangle.on.rectangle") { returnToWindow() }
                            .labelStyle(.iconOnly)
                        Button("Disconnect", systemImage: "xmark") { model.disconnect() }
                            .labelStyle(.iconOnly)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .glassBackgroundEffect(in: Capsule())
                    .controlSize(.large)
                    .opacity(controlsVisible || voiceOverEnabled ? 1 : 0)
                    .allowsHitTesting(controlsVisible || voiceOverEnabled)
                    .accessibilityHidden(!controlsVisible && !voiceOverEnabled)
                    if let message = lighting.extremeError, lighting.mode == .extreme {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 200).padding(.vertical, 140)
                .frame(width: 1580, height: 1060)
                .coordinateSpace(name: "ambient-player")
                .onPreferenceChange(PlayerFrameKey.self) { if !$0.isEmpty { playerFrame = $0 } }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    controlsVisible = true; controlInteraction += 1
                })
                .animation(.easeOut(duration: 0.25), value: controlsVisible)
                .task(id: controlInteraction) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    controlsVisible = false
                }
                .handlesGameControllerEvents(matching: .gamepad)
            }
        }
        .onAppear {
            model.playbackSpace = .immersive
            model.setSceneActive(true, immersive: true)
            if !model.showingVideo { returnToWindow() }
        }
        .onDisappear {
            rig.update(.black, enabled: false)
            extreme?.stop()
            model.spaceRequest = UUID()
            model.prefersWindow = true
            model.playbackSpace = .window
            model.setSceneActive(false, immersive: true)
            if !model.windowPresented { openWindow(id: "remote-play") }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setSceneActive(phase == .active, immersive: true, background: phase == .background)
        }
        .onChange(of: model.showingVideo) { _, playing in if !playing { returnToWindow() } }
    }
    private func updateExtreme(_ player: ViewAttachmentEntity?) {
        guard let extreme else { return }
        if let player {
            let metersPerPoint = player.visualBounds(relativeTo: rig.root).extents.x / 1580
            extreme.setScreen(width: Float(playerFrame.width)*metersPerPoint,
                center: [(Float(playerFrame.midX)-790)*metersPerPoint,
                         (530-Float(playerFrame.midY))*metersPerPoint, -0.015])
        }
        extreme.update(palette: lighting.palette,
            enabled: lighting.enabled && lighting.mode == .extreme && scenePhase == .active,
            roomAllowed: lighting.roomLightAllowed, reduceMotion: reduceMotion)
    }
    private func returnToWindow() {
        guard model.playbackSpace != .closing else { return }
        model.prefersWindow = true
        model.playbackSpace = .closing
        Task { await dismissImmersiveSpace() }
    }
}
