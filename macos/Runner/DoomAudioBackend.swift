import AVFoundation
import FlutterMacOS
import os.log

final class DoomAudioBackend {
  static let channelName = "dev.castletaste.doompeller/audio"
  static let channelCount = 8
  private static let log = OSLog(
    subsystem: "dev.castletaste.doompeller",
    category: "audio"
  )

  private let engine = AVAudioEngine()
  private let methodChannel: FlutterMethodChannel
  private let players: [AVAudioPlayerNode]
  private var activePlaybackIds: [Int: Int] = [:]

  init(binaryMessenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: binaryMessenger
    )
    players = (0..<Self.channelCount).map { _ in AVAudioPlayerNode() }

    let mixer = engine.mainMixerNode
    let outputSampleRate = mixer.outputFormat(forBus: 0).sampleRate
    let initialSampleRate = outputSampleRate > 0 ? outputSampleRate : 44_100
    let initialFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: initialSampleRate,
      channels: 1,
      interleaved: false
    )!
    for (index, player) in players.enumerated() {
      engine.attach(player)
      engine.connect(
        player,
        to: mixer,
        fromBus: 0,
        toBus: AVAudioNodeBus(index),
        format: initialFormat
      )
    }
    engine.prepare()
    do {
      try engine.start()
      os_log(
        "AVAudioEngine initialized with 8 reusable channels",
        log: Self.log,
        type: .info
      )
    } catch {
      // A later play retries start, so missing output during early startup is
      // recoverable and still reported through the MethodChannel if it lasts.
      os_log(
        "AVAudioEngine deferred start: %{public}@",
        log: Self.log,
        type: .error,
        error.localizedDescription
      )
    }

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  deinit {
    for player in players {
      player.stop()
    }
    engine.stop()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "play":
        try play(arguments: call.arguments)
        result(nil)
      case "stop":
        try stop(arguments: call.arguments)
        result(nil)
      case "dispose":
        dispose()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(
        code: "doompeller_audio",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func play(arguments: Any?) throws {
    guard
      let arguments = arguments as? [String: Any],
      let channelId = (arguments["channelId"] as? NSNumber)?.intValue,
      let playbackId = (arguments["playbackId"] as? NSNumber)?.intValue,
      let typedData = arguments["wavBytes"] as? FlutterStandardTypedData,
      let volume = (arguments["volume"] as? NSNumber)?.doubleValue,
      let pan = (arguments["pan"] as? NSNumber)?.doubleValue
    else {
      throw DoomAudioError.invalidArguments
    }
    guard players.indices.contains(channelId) else {
      throw DoomAudioError.invalidChannel(channelId)
    }

    let levels = try DoomAudioLevels.validated(volume: volume, pan: pan)
    let wav = try CanonicalDoomWav.parse(typedData.data)
    let buffer = try wav.makeFloatBuffer()
    let player = players[channelId]

    // AVAudioPlayerNode requires scheduled buffers to match its output format.
    // Reconnecting this retained node upstream of the mixer is supported by
    // AVAudioEngine. The mixer then performs sample-rate conversion and mono
    // upmixing into its stereo output, so arbitrary valid DMX rates keep pitch.
    player.stop()
    activePlaybackIds.removeValue(forKey: channelId)
    engine.disconnectNodeOutput(player)
    engine.connect(
      player,
      to: engine.mainMixerNode,
      fromBus: 0,
      toBus: AVAudioNodeBus(channelId),
      format: buffer.format
    )
    player.volume = levels.volume
    player.pan = levels.pan
    activePlaybackIds[channelId] = playbackId

    player.scheduleBuffer(
      buffer,
      at: nil,
      options: .interrupts,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.complete(channelId: channelId, playbackId: playbackId)
      }
    }
    if !engine.isRunning {
      engine.prepare()
      try engine.start()
    }
    player.play()
    os_log(
      "play channel=%{public}d playback=%{public}d frames=%{public}d rate=%{public}d",
      log: Self.log,
      type: .debug,
      channelId,
      playbackId,
      Int(buffer.frameLength),
      wav.sampleRate
    )
  }

  private func stop(arguments: Any?) throws {
    guard
      let arguments = arguments as? [String: Any],
      let channelId = (arguments["channelId"] as? NSNumber)?.intValue
    else {
      throw DoomAudioError.invalidArguments
    }
    guard players.indices.contains(channelId) else {
      throw DoomAudioError.invalidChannel(channelId)
    }
    activePlaybackIds.removeValue(forKey: channelId)
    players[channelId].stop()
  }

  private func dispose() {
    activePlaybackIds.removeAll()
    for player in players {
      player.stop()
      player.reset()
    }
    engine.stop()
  }

  private func complete(channelId: Int, playbackId: Int) {
    guard activePlaybackIds[channelId] == playbackId else { return }
    activePlaybackIds.removeValue(forKey: channelId)
    methodChannel.invokeMethod("playbackComplete", arguments: [
      "channelId": channelId,
      "playbackId": playbackId,
    ])
  }
}
