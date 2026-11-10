import Foundation
import Translation
import Speech
import AVKit
import UIKit

struct CapabilityReport: Codable {
    let testedAt: Date
    let systemVersion: String
    let pictureInPictureSupported: Bool
    let languages: [String: String]
    let onDeviceSpeech: [String: Bool]
    let translationSamples: [String: String]
    let pipelineProbe: [String: String]
}

@MainActor enum DeviceDiagnostics {
    static func run() async -> CapabilityReport {
        var languages: [String: String] = [:]
        var translationSamples: [String: String] = [:]
        for code in ["en", "ja", "ko"] {
            #if targetEnvironment(simulator)
            languages[code] = "simulator-unavailable"
            #else
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: code),
                                                             to: Locale.Language(identifier: "zh-Hans"))
            switch status {
            case .installed: languages[code] = "installed"
            case .supported: languages[code] = "download-required"
            case .unsupported: languages[code] = "unsupported"
            @unknown default: languages[code] = "unknown"
            }
            #if DEBUG
            if status == .installed {
                let example: String
                switch code {
                case "ja": example = "こんにちは"
                case "ko": example = "안녕하세요"
                default: example = "Airport train"
                }
                do {
                    let session = TranslationSession(installedSource: Locale.Language(identifier: code),
                                                     target: Locale.Language(identifier: "zh-Hans"))
                    translationSamples[code] = try await session.translate(example).targetText
                } catch { translationSamples[code] = "ERROR: \(error.localizedDescription)" }
            }
            #endif
            #endif
        }
        let speech = ["en-US", "ja-JP", "ko-KR"].reduce(into: [String: Bool]()) { result, locale in
            result[locale] = SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false
        }
        var pipelineProbe: [String: String] = [:]
        #if DEBUG
        let fixture = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 300)).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 800, height: 300))
            ("Airport train" as NSString).draw(at: CGPoint(x: 60, y: 95), withAttributes: [
                .font: UIFont.systemFont(ofSize: 78, weight: .bold), .foregroundColor: UIColor.black
            ])
        }
        do {
            let blocks = try RecognitionService.recognize(fixture)
            pipelineProbe["ocr"] = blocks.map(\.original).joined(separator: " | ")
            if let first = blocks.first {
                pipelineProbe["box"] = "\(first.box)"
                pipelineProbe["translation"] = try await LocalTranslator().translate(first.original, source: .english)
            }
        } catch { pipelineProbe["error"] = error.localizedDescription }
        #endif
        let report = CapabilityReport(testedAt: Date(), systemVersion: UIDevice.current.systemVersion,
                                      pictureInPictureSupported: AVPictureInPictureController.isPictureInPictureSupported(),
                                      languages: languages, onDeviceSpeech: speech,
                                      translationSamples: translationSamples, pipelineProbe: pipelineProbe)
        if let data = try? JSONEncoder().encode(report) {
            if let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroup) {
                try? data.write(to: folder.appendingPathComponent("capabilities.json"), options: .atomic)
            }
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: folder.appendingPathComponent("capabilities.json"), options: .atomic)
            }
        }
        return report
    }
}
