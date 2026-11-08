// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import GameController

final class RemotePlayEngine {
    let video = VideoPipeline()
    let audio = AudioPipeline()
    private let queue = DispatchQueue(label: "visionremote.protocol", qos: .userInteractive)
    private var client: OpaquePointer?
    private var observers: [NSObjectProtocol] = []
    private let audioLock = NSLock()
    private var audioChannels = 2
    var onStatus: ((Int, String) -> Void)?
    var onRegistered: ((Data, String) -> Void)?
    var onController: ((String?) -> Void)?
    private var controller: GCController?
    private var controllerEvents = 0
    private let statsLock = NSLock()

    init() {
        var callbacks = VRPCallbacks()
        callbacks.status = { user, code, message in
            guard let user else { return }
            let engine = Unmanaged<RemotePlayEngine>.fromOpaque(user).takeUnretainedValue()
            let text = message.map { String(cString: $0) } ?? "Unknown status"
            DispatchQueue.main.async { engine.onStatus?(Int(code), text) }
            if code == 3 || code == 5 {
                engine.queue.async {
                    vrp_finish_registration(engine.client)
                    vrp_disconnect(engine.client)
                    engine.audio.stop()
                }
            }
        }
        callbacks.registered = { user, bytes, size, name in
            guard let user, let bytes, size == VRP_PAIRING_SIZE else { return }
            let engine = Unmanaged<RemotePlayEngine>.fromOpaque(user).takeUnretainedValue()
            let data = Data(bytes: bytes, count: size)
            let nickname = name.map { String(cString: $0) } ?? "PS5"
            engine.queue.async { vrp_finish_registration(engine.client) }
            DispatchQueue.main.async { engine.onRegistered?(data, nickname) }
        }
        callbacks.video = { user, bytes, size, lost, _ in
            guard let user, let bytes, size > 0, size <= 16 * 1024 * 1024 else { return false }
            let engine = Unmanaged<RemotePlayEngine>.fromOpaque(user).takeUnretainedValue()
            return engine.video.consume(Data(bytes: bytes, count: size), lost: lost)
        }
        callbacks.audio_format = { user, channels, rate in
            guard let user else { return }
            let engine = Unmanaged<RemotePlayEngine>.fromOpaque(user).takeUnretainedValue()
            engine.audioLock.lock(); engine.audioChannels = Int(channels); engine.audioLock.unlock()
            engine.audio.configure(channels: channels, rate: rate)
        }
        callbacks.audio = { user, samples, count in
            guard let user, let samples else { return }
            let engine = Unmanaged<RemotePlayEngine>.fromOpaque(user).takeUnretainedValue()
            engine.audioLock.lock(); let channels = engine.audioChannels; engine.audioLock.unlock()
            engine.audio.consume(samples, frames: count, channels: channels)
        }
        client = vrp_create(callbacks, Unmanaged.passUnretained(self).toOpaque())
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.updateController() })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.updateController() })
        audio.onError = { [weak self] message in DispatchQueue.main.async { self?.onStatus?(6, message) } }
    }
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        controller?.extendedGamepad?.valueChangedHandler = nil
        vrp_destroy(client)
    }
    func updateController() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        onController?(controller?.vendorName)
        controller?.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, _ in self?.send(gamepad) }
    }
    private func send(_ g: GCExtendedGamepad) {
        var buttons: UInt32 = 0
        let mapping: [(GCControllerButtonInput?, Int)] = [
            (g.buttonA, 0), (g.buttonB, 1), (g.buttonX, 2), (g.buttonY, 3),
            (g.dpad.left, 4), (g.dpad.right, 5), (g.dpad.up, 6), (g.dpad.down, 7),
            (g.leftShoulder, 8), (g.rightShoulder, 9), (g.leftThumbstickButton, 10),
            (g.rightThumbstickButton, 11), (g.buttonMenu, 12), (g.buttonOptions, 13),
            ((g as? GCDualSenseGamepad)?.touchpadButton, 14)
        ]
        for (button, bit) in mapping where button?.isPressed == true { buttons |= 1 << bit }
        let l2 = UInt8(max(0, min(255, Int(g.leftTrigger.value * 255))))
        let r2 = UInt8(max(0, min(255, Int(g.rightTrigger.value * 255))))
        func axis(_ value: Float) -> Int16 { Int16(max(-32767, min(32767, Int(value * 32767)))) }
        let lx = axis(g.leftThumbstick.xAxis.value), ly = axis(-g.leftThumbstick.yAxis.value)
        let rx = axis(g.rightThumbstick.xAxis.value), ry = axis(-g.rightThumbstick.yAxis.value)
        statsLock.lock(); controllerEvents += 1; statsLock.unlock()
        queue.async { [self] in vrp_controller(client, buttons, l2, r2, lx, ly, rx, ry) }
    }
    func controllerEventCount() -> Int { statsLock.lock(); defer { statsLock.unlock() }; return controllerEvents }
    func pair(host: String, account: Data, pin: UInt32) {
        queue.async { [self] in
            let code = account.withUnsafeBytes { raw in
                host.withCString { vrp_register(client, $0, raw.bindMemory(to: UInt8.self).baseAddress, account.count, pin) }
            }
            report(code)
        }
    }
    func connect(host: String, pairing: Data, resolution: Int) {
        video.reset()
        queue.async { [self] in
            let code = pairing.withUnsafeBytes { raw in
                host.withCString { vrp_connect(client, $0, raw.bindMemory(to: UInt8.self).baseAddress, pairing.count, Int32(resolution)) }
            }
            report(code)
        }
    }
    func disconnect() {
        queue.async { [self] in vrp_disconnect(client); audio.stop(); DispatchQueue.main.async { self.onStatus?(3, "Disconnected.") } }
    }
    func loginPIN(_ pin: String) { queue.async { [self] in pin.withCString { vrp_login_pin(client, $0) } } }
    func pressPS() {
        queue.async { [self] in vrp_controller(client, 1 << 15, 0, 0, 0, 0, 0, 0) }
        queue.asyncAfter(deadline: .now() + 0.12) { [self] in vrp_controller(client, 0, 0, 0, 0, 0, 0, 0) }
    }
    private func report(_ code: Int32) {
        guard code != 0 else { return }
        let message = String(cString: vrp_error(code))
        DispatchQueue.main.async { self.onStatus?(5, message) }
    }
}
