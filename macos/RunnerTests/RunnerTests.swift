import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {
  func testCanonicalWavParserAndPcmBoundaries() throws {
    let wav = canonicalWav(samples: [0, 128, 255], sampleRate: 11_025)
    let parsed = try CanonicalDoomWav.parse(wav)

    XCTAssertEqual(parsed.sampleRate, 11_025)
    XCTAssertEqual(parsed.samples, [0, 128, 255])
    XCTAssertEqual(CanonicalDoomWav.floatSample(0), -1, accuracy: 0.000_001)
    XCTAssertEqual(CanonicalDoomWav.floatSample(128), 0, accuracy: 0.000_001)
    XCTAssertEqual(
      CanonicalDoomWav.floatSample(255),
      0.992_187_5,
      accuracy: 0.000_001
    )
  }

  func testCanonicalWavParserRejectsInvalidLayout() {
    var wav = canonicalWav(samples: [128], sampleRate: 11_025)
    wav[22] = 2 // Two channels is outside the MethodChannel contract.

    XCTAssertThrowsError(try CanonicalDoomWav.parse(wav))
  }

  func testCanonicalWavParserRejectsNativeSoundLimits() {
    var oversized = canonicalWav(samples: [128], sampleRate: 11_025)
    overwrite32(
      UInt32(CanonicalDoomWav.maxSamples + 1),
      in: &oversized,
      at: 40
    )
    XCTAssertThrowsError(try CanonicalDoomWav.parse(oversized)) { error in
      XCTAssertTrue(error.localizedDescription.contains("maxSoundSamples"))
    }

    var highRate = canonicalWav(samples: [128], sampleRate: 11_025)
    let rejectedRate = UInt32(CanonicalDoomWav.maxSampleRate + 1)
    overwrite32(rejectedRate, in: &highRate, at: 24)
    overwrite32(rejectedRate, in: &highRate, at: 28)
    XCTAssertThrowsError(try CanonicalDoomWav.parse(highRate)) { error in
      XCTAssertTrue(error.localizedDescription.contains("maxSoundSampleRate"))
    }
  }

  func testAudioLevelsRejectNonFiniteValuesBeforeFloatConversion() throws {
    XCTAssertThrowsError(
      try DoomAudioLevels.validated(volume: .nan, pan: 0)
    )
    XCTAssertThrowsError(
      try DoomAudioLevels.validated(volume: 1, pan: .infinity)
    )
    let levels = try DoomAudioLevels.validated(volume: 2, pan: -2)
    XCTAssertEqual(levels.volume, 1)
    XCTAssertEqual(levels.pan, -1)
  }

  private func canonicalWav(samples: [UInt8], sampleRate: UInt32) -> Data {
    let padding = samples.count.isMultiple(of: 2) ? 0 : 1
    var bytes = [UInt8](repeating: 0, count: 44 + samples.count + padding)
    func writeAscii(_ value: String, at offset: Int) {
      for (index, byte) in value.utf8.enumerated() {
        bytes[offset + index] = byte
      }
    }
    func write16(_ value: UInt16, at offset: Int) {
      bytes[offset] = UInt8(truncatingIfNeeded: value)
      bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    func write32(_ value: UInt32, at offset: Int) {
      for index in 0..<4 {
        bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
      }
    }
    writeAscii("RIFF", at: 0)
    write32(UInt32(bytes.count - 8), at: 4)
    writeAscii("WAVE", at: 8)
    writeAscii("fmt ", at: 12)
    write32(16, at: 16)
    write16(1, at: 20)
    write16(1, at: 22)
    write32(sampleRate, at: 24)
    write32(sampleRate, at: 28)
    write16(1, at: 32)
    write16(8, at: 34)
    writeAscii("data", at: 36)
    write32(UInt32(samples.count), at: 40)
    bytes.replaceSubrange(44..<(44 + samples.count), with: samples)
    return Data(bytes)
  }

  private func overwrite32(_ value: UInt32, in data: inout Data, at offset: Int) {
    data.replaceSubrange(
      offset..<(offset + 4),
      with: (0..<4).map { index in
        UInt8(truncatingIfNeeded: value >> (index * 8))
      }
    )
  }
}
