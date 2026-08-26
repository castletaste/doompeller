import AVFoundation

enum DoomAudioError: LocalizedError {
  case invalidArguments
  case invalidChannel(Int)
  case invalidWav(String)
  case allocationFailed

  var errorDescription: String? {
    switch self {
    case .invalidArguments:
      return "Invalid audio MethodChannel arguments."
    case .invalidChannel(let channel):
      return "Audio channel \(channel) is outside 0..<8."
    case .invalidWav(let reason):
      return "Invalid canonical Doom WAV: \(reason)."
    case .allocationFailed:
      return "Could not allocate the in-memory PCM buffer."
    }
  }
}

struct CanonicalDoomWav {
  // Keep these native trust-boundary limits aligned with DoomLimits.defaults.
  static let maxSamples = 16 * 1024 * 1024
  static let maxSampleRate = 48_000

  let sampleRate: Int
  let samples: [UInt8]

  static func parse(_ data: Data) throws -> CanonicalDoomWav {
    guard data.count >= 44 else {
      throw DoomAudioError.invalidWav("header is shorter than 44 bytes")
    }
    guard data.count <= 44 + maxSamples + 1 else {
      throw DoomAudioError.invalidWav("maxSoundSamples: payload is too large")
    }
    guard ascii(data, at: 0, equals: "RIFF"),
          ascii(data, at: 8, equals: "WAVE"),
          ascii(data, at: 12, equals: "fmt "),
          ascii(data, at: 36, equals: "data")
    else {
      throw DoomAudioError.invalidWav("required RIFF/WAVE chunks are missing")
    }
    let riffSizeValue = uint32(data, at: 4)
    let formatSize = uint32(data, at: 16)
    let encoding = uint16(data, at: 20)
    let channels = uint16(data, at: 22)
    let sampleRateValue = uint32(data, at: 24)
    let byteRate = uint32(data, at: 28)
    let blockAlign = uint16(data, at: 32)
    let bitsPerSample = uint16(data, at: 34)
    let sampleCountValue = uint32(data, at: 40)
    guard
      let riffSize = Int(exactly: riffSizeValue),
      let sampleRate = Int(exactly: sampleRateValue),
      let sampleCount = Int(exactly: sampleCountValue)
    else {
      throw DoomAudioError.invalidWav("header values do not fit native integers")
    }
    guard sampleRate > 0, sampleRate <= maxSampleRate else {
      throw DoomAudioError.invalidWav(
        "maxSoundSampleRate: \(sampleRate) exceeds \(maxSampleRate)"
      )
    }
    guard sampleCount > 0, sampleCount <= maxSamples else {
      throw DoomAudioError.invalidWav(
        "maxSoundSamples: \(sampleCount) exceeds \(maxSamples)"
      )
    }
    let padding = sampleCount.isMultiple(of: 2) ? 0 : 1
    let (payloadEnd, payloadOverflow) = 44.addingReportingOverflow(sampleCount)
    let (expectedCount, countOverflow) = payloadEnd.addingReportingOverflow(padding)

    guard !payloadOverflow,
          !countOverflow,
          riffSize == data.count - 8,
          formatSize == 16,
          encoding == 1,
          channels == 1,
          byteRate == sampleRateValue,
          blockAlign == 1,
          bitsPerSample == 8,
          data.count == expectedCount,
          padding == 0 || byte(data, at: payloadEnd) == 0
    else {
      throw DoomAudioError.invalidWav("layout is not canonical mono unsigned-8 PCM")
    }
    let samplesStart = data.index(data.startIndex, offsetBy: 44)
    let samplesEnd = data.index(samplesStart, offsetBy: sampleCount)
    return CanonicalDoomWav(
      sampleRate: sampleRate,
      samples: Array(data[samplesStart..<samplesEnd])
    )
  }

  func makeFloatBuffer() throws -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ),
      let channel = buffer.floatChannelData?[0]
    else {
      throw DoomAudioError.allocationFailed
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (index, sample) in samples.enumerated() {
      channel[index] = Self.floatSample(sample)
    }
    return buffer
  }

  static func floatSample(_ sample: UInt8) -> Float {
    (Float(sample) - 128) / 128
  }

  private static func byte(_ data: Data, at offset: Int) -> UInt8 {
    data[data.index(data.startIndex, offsetBy: offset)]
  }

  private static func ascii(_ data: Data, at offset: Int, equals value: String) -> Bool {
    let expected = value.utf8
    guard offset + expected.count <= data.count else { return false }
    for (index, expectedByte) in expected.enumerated() {
      if byte(data, at: offset + index) != expectedByte { return false }
    }
    return true
  }

  private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(byte(data, at: offset))
      | (UInt16(byte(data, at: offset + 1)) << 8)
  }

  private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(byte(data, at: offset))
      | (UInt32(byte(data, at: offset + 1)) << 8)
      | (UInt32(byte(data, at: offset + 2)) << 16)
      | (UInt32(byte(data, at: offset + 3)) << 24)
  }
}

struct DoomAudioLevels {
  let volume: Float
  let pan: Float

  static func validated(volume: Double, pan: Double) throws -> DoomAudioLevels {
    guard volume.isFinite, pan.isFinite else {
      throw DoomAudioError.invalidArguments
    }
    return DoomAudioLevels(
      volume: Float(max(0, min(1, volume))),
      pan: Float(max(-1, min(1, pan)))
    )
  }
}
