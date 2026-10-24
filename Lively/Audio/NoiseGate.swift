import Foundation

/// How far away Lively listens. Sound quieter than the range's threshold is
/// sent as silence, so a conversation across the room isn't translated.
enum PickupRange: String, CaseIterable, Identifiable, Sendable {
    case auto
    case close
    case nearby
    case room

    static let `default` = PickupRange.nearby

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .close: "Close"
        case .nearby: "Nearby"
        case .room: "Whole room"
        }
    }
    var summary: String {
        switch self {
        case .auto: "Follows how loud the room is, and only hears people noticeably louder than the background."
        case .close: "Only the people right by the phone. For loud places like restaurants and stations."
        case .nearby: "People around the table. Conversations across the room are ignored."
        case .room: "Everything the mic can hear, even far away."
        }
    }
}

/// Decides, chunk by chunk, whether the mic is hearing someone close enough
/// to translate. Sound gets about 6 dB quieter each time the distance
/// doubles, so a level threshold separates the person across the table from
/// a conversation 25 feet away.
///
/// Shared with Android (`audio/NoiseGate.kt`); keep the numbers in step.
struct NoiseGate {
    /// Nearby's threshold, in dBFS of an 80 ms chunk.
    static let nearbyThreshold: Float = -40
    /// Close's threshold.
    static let closeThreshold: Float = -32
    /// How far below the threshold sound can dip and keep an open gate open,
    /// so it doesn't flicker mid-word.
    static let hysteresis: Float = 6
    /// Chunks the gate stays open after the level drops (640 ms), so quiet
    /// word endings and short pauses aren't cut.
    static let holdChunks = 8
    /// In Auto, how much louder than the room's noise floor speech must be.
    static let autoMargin: Float = 12
    /// Auto's strictest threshold. Its laxest is Nearby's.
    static let autoCeiling: Float = -28
    /// How fast the noise floor estimate rises, in dB per chunk (1.5 dB a
    /// second), so speech doesn't count as background but a noisier room does.
    static let floorRise: Float = 0.12

    private(set) var isOpen = true
    /// The room's background level, in dBFS. Tracked in every range, so Auto
    /// is ready the moment it's chosen.
    private(set) var noiseFloor: Float = -60
    private var hold = 0

    /// The level speech must reach to open the gate, or nil to hear everything.
    func threshold(for range: PickupRange) -> Float? {
        switch range {
        case .room: nil
        case .nearby: Self.nearbyThreshold
        case .close: Self.closeThreshold
        case .auto: min(max(noiseFloor + Self.autoMargin, Self.nearbyThreshold), Self.autoCeiling)
        }
    }

    /// Takes one chunk's level and returns whether to send it as heard.
    mutating func process(_ decibels: Float, range: PickupRange) -> Bool {
        // Falls quickly into quiet gaps, rises slowly, and never above what's heard.
        if decibels < noiseFloor {
            noiseFloor += (decibels - noiseFloor) * 0.25
        } else {
            noiseFloor = min(noiseFloor + Self.floorRise, decibels)
        }
        noiseFloor = max(noiseFloor, -90)

        guard let threshold = threshold(for: range) else {
            isOpen = true
            hold = 0
            return true
        }
        if decibels >= threshold || (isOpen && decibels >= threshold - Self.hysteresis) {
            isOpen = true
            hold = Self.holdChunks
        } else {
            hold = max(0, hold - 1)
            isOpen = hold > 0
        }
        return isOpen
    }

    /// Closes the gate for a new session, keeping what it learned about the room.
    mutating func reset() {
        isOpen = false
        hold = 0
    }
}
