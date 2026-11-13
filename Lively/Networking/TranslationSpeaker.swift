import Foundation

/// A sentence queue whose audio follows the same output rules online and offline.
protocol TranslationSpeaker: AnyObject {
    var player: SpeechPlayer { get }
    var onError: (String) -> Void { get set }
    func speak(_ text: String, in language: Language, output: SpeechPlayer.Output)
    func stop()
}

extension SonioxSpeaker: TranslationSpeaker {}
extension OfflineSpeaker: TranslationSpeaker {}
