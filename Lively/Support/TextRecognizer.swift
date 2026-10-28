import Foundation
import ImageIO
import Vision

/// Reads the text in a photo on the device, so signs, menus and documents
/// can be translated like typed lines. Uses Vision; ML Kit's text
/// recognition on Android.
enum TextRecognizer {
    /// The photo's text, one line per line of text found, or "" when there's none.
    static func text(in image: Data, languages: LanguagePair) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let wanted = recognitionLanguages(for: languages, supported: request.supportedRecognitionLanguages)
        if wanted.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = wanted
        }
        let observations = try await request.perform(on: image, orientation: orientation(of: image))
        return observations
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The pair's languages that Vision reads, such as zh-Hans and zh-Hant
    /// for Chinese. Vision favours the first, and its models for other
    /// scripts also read Latin letters, so Latin-script languages go last.
    private static func recognitionLanguages(for languages: LanguagePair, supported: [Locale.Language]) -> [Locale.Language] {
        languages.all
            .sorted { !$0.usesLatinScript && $1.usesLatinScript }
            .flatMap { language in supported.filter { $0.languageCode?.identifier == language.rawValue } }
    }

    /// Camera photos are stored sideways with an EXIF orientation; Vision
    /// needs it to read the lines the right way up.
    private static func orientation(of image: Data) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = properties[kCGImagePropertyOrientation] as? UInt32 else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }
}
