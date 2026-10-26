import AVFoundation
import os

/// Loops one second of silence through AVAudioEngine. Its only purpose is the audio background
/// mode: while it plays, iOS keeps the process running (not suspended) behind Home, so whatever
/// the app's main run loop still does there costs CPU and wakeups.
final class SilentAudio {
    static let shared = SilentAudio()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let log = Logger(subsystem: "CmpA11yRepro", category: "audio")

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
            else { return }
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData?[channel].update(repeating: 0, count: Int(buffer.frameLength))
            }

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            log.info("silent audio started")
        } catch {
            log.error("silent audio failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
