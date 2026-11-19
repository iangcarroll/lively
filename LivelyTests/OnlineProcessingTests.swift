import Foundation
import Testing
@testable import Lively

@MainActor
struct OnlineProcessingTests {
    @Test func upgradeAndWithdrawalKeepCloudFeaturesBehindAnExplicitChoice() throws {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(SpeechProvider.voxtralMistral.id, forKey: "speechProvider")
        defaults.set(true, forKey: "onboardingDone")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.onlineProcessing == nil)
        #expect(settings.provider.id == SpeechProvider.onDevice.id)
        #expect(settings.speechSource == .downloaded)
        settings.chooseOnlineProcessing(true)
        #expect(settings.provider.id == SpeechProvider.voxtralMistral.id)
        #expect(settings.speechSource == .original)
        settings.chooseOnlineProcessing(false)
        settings.providerID = SpeechProvider.soniox.id
        settings.speechSource = .original
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.onlineProcessing == false)
        #expect(reopened.provider.id == SpeechProvider.onDevice.id)
        #expect(!reopened.usesAutomaticLanguageDetection)
        #expect(reopened.speechSource == .downloaded)
        #expect(ConversationStore(settings: reopened).translatesTypedTextOnDevice)
    }
}
