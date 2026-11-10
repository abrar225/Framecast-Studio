import AVFoundation
import VideoToolbox

/// Persisted values and encoder dictionaries have one owner; UI and output
/// consumers use these facts rather than reinterpreting quality labels.
enum RecordingCodec: String, Codable, CaseIterable {
    case h264, hevc
    var title: String { self == .h264 ? "H.264" : "HEVC" }
    var native: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}
enum RecordingContainer: String, Codable, CaseIterable {
    case mp4, mov
    var native: AVFileType { self == .mp4 ? .mp4 : .mov }
}
enum RateControlMode: String, Codable, CaseIterable {
    case vbr, cbr
    var title: String { self == .vbr ? "VBR" : "CBR" }
}
enum RecordingQuality: String, Codable, CaseIterable {
    case good, great, ultra, custom
    var title: String { rawValue.capitalized }
    var qualityFactor: Double {
        switch self {
        case .good: return 0.60
        case .great: return 0.80
        case .ultra: return 0.95
        case .custom: return 0.85
        }
    }
}
struct RecordingEncodingSettings: Codable, Equatable {
    var codec: RecordingCodec = .h264
    var container: RecordingContainer = .mp4
    var quality: RecordingQuality = .great
    var rateControl: RateControlMode = .vbr
    var bitrateMbps = 40.0
    var requireHardware = true
    var isValid: Bool { bitrateMbps.isFinite && (0.5...120).contains(bitrateMbps) }

    init(codec: RecordingCodec = .h264, container: RecordingContainer = .mp4, quality: RecordingQuality = .great, rateControl: RateControlMode = .vbr, bitrateMbps: Double = 40.0, requireHardware: Bool = true) {
        self.codec = codec
        self.container = container
        self.quality = quality
        self.rateControl = rateControl
        self.bitrateMbps = bitrateMbps
        self.requireHardware = requireHardware
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decodeIfPresent(RecordingCodec.self, forKey: .codec) ?? .h264
        self.container = try container.decodeIfPresent(RecordingContainer.self, forKey: .container) ?? .mp4
        quality = try container.decodeIfPresent(RecordingQuality.self, forKey: .quality) ?? .great
        rateControl = try container.decodeIfPresent(RateControlMode.self, forKey: .rateControl) ?? .vbr
        bitrateMbps = try container.decodeIfPresent(Double.self, forKey: .bitrateMbps) ?? 40.0
        requireHardware = try container.decodeIfPresent(Bool.self, forKey: .requireHardware) ?? true
    }

    func bitRate(width: Int, height: Int, fps: Int) -> Int {
        if quality == .custom { return Int(bitrateMbps * 1_000_000) }
        let bitsPerPixel = codec == .h264 ? 0.16 : 0.10
        let multiplier: Double
        switch quality {
        case .good: multiplier = 0.6
        case .great: multiplier = 1.0
        case .ultra: multiplier = 1.5
        case .custom: multiplier = 1.0
        }
        let rate = Double(width) * Double(height) * Double(fps) * bitsPerPixel * multiplier
        let floorRate = quality == .good ? 8_000_000 : (quality == .ultra ? 24_000_000 : 16_000_000)
        return Int(min(120_000_000, max(Double(floorRate), rate)))
    }
    func videoSettings(width: Int, height: Int, fps: Int) -> [String: Any] {
        let bps = bitRate(width: width, height: height, fps: fps)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bps,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            kVTCompressionPropertyKey_Quality as String: quality.qualityFactor
        ]
        if rateControl == .cbr {
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [bps / 8, 1.0] as CFArray
        }
        return [
            AVVideoCodecKey: codec.native,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: requireHardware
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: compression
        ]
    }
}
enum StreamEncoder: String, Codable, CaseIterable {
    case apple, software
    var title: String { self == .apple ? "Apple VideoToolbox" : "Software H.264" }
}
struct StreamEncodingSettings: Codable, Equatable {
    var encoder: StreamEncoder = .apple
    var automaticBitrate = true
    var bitrateMbps = 12.0
    var audioBitrateKbps = 192
    var isValid: Bool { bitrateMbps.isFinite && (0.5...80).contains(bitrateMbps) && MediaPreferences.audioBitrates.contains(audioBitrateKbps) }
    func bitRate(width: Int, height: Int, fps: Int) -> Int {
        automaticBitrate ? Int(min(50_000_000, max(2_000_000, Double(width) * Double(height) * Double(fps) * 0.10))) : Int(bitrateMbps * 1_000_000)
    }
}
struct MediaPreferences: Codable, Equatable {
    var horizontal = RecordingEncodingSettings()
    var vertical = RecordingEncodingSettings()
    var recordingAudioBitrateKbps = 256
    var streaming = StreamEncodingSettings()
    static let frameRates = [24, 25, 30, 50, 60]
    static let audioBitrates = [128, 160, 192, 256, 320]
    var isValid: Bool { horizontal.isValid && vertical.isValid && streaming.isValid && Self.audioBitrates.contains(recordingAudioBitrateKbps) }
    func recording(vertical: Bool) -> RecordingEncodingSettings { vertical ? self.vertical : horizontal }
    func recordingBitRate(width: Int, height: Int, fps: Int, vertical: Bool) -> Int {
        recording(vertical: vertical).bitRate(width: width, height: height, fps: fps) + recordingAudioBitrateKbps * 1000
    }
}

/// Resource bound for the supported SDR output path, shared by capture,
/// validation and both encoders. Codec/device availability is checked natively.
enum MediaLimits {
    static let maximumDimension = 3840
    static let maximumPixels = 3840 * 2160
    static func supports(width: Int, height: Int, fps: Int) -> Bool {
        (64...maximumDimension).contains(width) && (64...maximumDimension).contains(height) &&
        width % 2 == 0 && height % 2 == 0 && width * height <= maximumPixels && (1...60).contains(fps)
    }
}
