import Foundation
import ReplayKit
import CoreImage
import UIKit
import ImageIO
import AVFoundation

/// ReplayKit extensions have a tight resource budget. Keep this process limited to
/// frame transfer; Vision and Translation run in the host app during the PiP session.
final class SampleHandler: RPBroadcastSampleHandler {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastPreview = Date.distantPast
    private var lastOCRFrame = Date.distantPast
    private let group = "group.com.liu.lingjing.translate"
    private var voiceMode = false
    private var lastModeCheck = Date.distantPast
    private var lastStateRefresh = Date.distantPast
    private var audioBytes = Data()
    private var audioFrames = 0
    private var audioRate: UInt32 = 0
    private var audioChannels: UInt8 = 0
    private var audioBigEndian = false
    private var audioSequence = 0
    // Settle detection: when the screen stops moving (scroll end, page change),
    // write an OCR frame right away instead of waiting for the 0.9 s cadence.
    private var lastSignature: [UInt8] = []
    private var lastChange = Date.distantPast
    private var pendingSettle = false
    /// The host app's own PiP window (top-left normalized), ignored by motion checks.
    private var pipMask: CGRect?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        lastPreview = .distantPast
        lastOCRFrame = .distantPast
        lastSignature = []
        lastChange = .distantPast
        pendingSettle = false
        voiceMode = false
        audioBytes.removeAll(keepingCapacity: true)
        audioFrames = 0
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("voice.stop"))
        for file in ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            where file.lastPathComponent.hasPrefix("voice-audio-") {
            try? FileManager.default.removeItem(at: file)
        }
        pipMask = nil
        for name in ["frame.jpg", "ocr-frame.jpg", "capture-result.json", "pip-region.txt"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        writeState("running", to: folder)
    }

    override func broadcastPaused() {
        if let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            writeState("paused", to: folder)
        }
    }

    override func broadcastResumed() {
        if let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            writeState("running", to: folder)
        }
    }

    override func broadcastFinished() {
        if let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            flushAudio(to: folder)
            writeState("stopped", to: folder)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("frame.jpg"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("ocr-frame.jpg"))
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("com.liu.lingjing.broadcastStopped" as CFString),
                                             nil, nil, true)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        if Date().timeIntervalSince(lastModeCheck) > 0.1 {
            if FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("voice.stop").path) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent("voice.stop"))
                finishBroadcastWithError(NSError(domain: "com.liu.lingjing.voice",
                    code: 0, userInfo: [NSLocalizedDescriptionKey: "语音字幕已关闭"]))
                return
            }
            let nextVoiceMode = FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("voice.mode").path)
            if (nextVoiceMode && !voiceMode) || Date().timeIntervalSince(lastStateRefresh) > 0.8 {
                writeState("running", to: folder)
                lastStateRefresh = Date()
            }
            voiceMode = nextVoiceMode
            let parts = ((try? String(contentsOf: folder.appendingPathComponent("pip-region.txt"),
                                      encoding: .utf8)) ?? "")
                .split(separator: ",").compactMap { Double($0) }
            pipMask = parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) : nil
            lastModeCheck = Date()
        }
        if sampleBufferType == .audioApp {
            if voiceMode { receiveAppAudio(sampleBuffer, folder: folder) }
            return
        }
        guard sampleBufferType == .video, !voiceMode,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        let shouldPreview = now.timeIntervalSince(lastPreview) >= 1.0 / 15.0
        // While the page is moving, feed OCR every 0.4 s so translations keep up
        // with scrolling (and fill the cache before the page stops); idle pages
        // keep the slower cadence.
        let moving = now.timeIntervalSince(lastChange) < 1.0
        var shouldOCRFrame = now.timeIntervalSince(lastOCRFrame) >= (moving ? 0.5 : 0.9)
        if shouldPreview, let signature = lumaSignature(buffer) {
            if !lastSignature.isEmpty, changedCells(signature, lastSignature) >= 3 {
                lastChange = now
                pendingSettle = true
            }
            lastSignature = signature
        }
        let settled = now.timeIntervalSince(lastChange) >= 0.1
        if pendingSettle && settled && now.timeIntervalSince(lastOCRFrame) >= 0.2 {
            shouldOCRFrame = true
        }
        guard shouldPreview || shouldOCRFrame else { return }
        let input = CIImage(cvPixelBuffer: buffer)
        if shouldPreview {
            lastPreview = now
            writeJPEG(input, longestSide: 780, quality: 0.5,
                      to: folder.appendingPathComponent("frame.jpg"))
        }
        if shouldOCRFrame {
            lastOCRFrame = now
            if settled { pendingSettle = false }
            writeJPEG(input, longestSide: 1800, quality: 0.78,
                      to: folder.appendingPathComponent("ocr-frame.jpg"))
        }
    }

    /// 24x40 point-sampled luma grid; costs microseconds and no allocation of images.
    private func lumaSignature(_ buffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let columns = 24, rows = 40
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var base: UnsafeMutableRawPointer?
        var width = 0, height = 0, stride = 0, step = 1, offset = 0
        if CVPixelBufferIsPlanar(buffer) {
            guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
            base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        } else if format == kCVPixelFormatType_32BGRA {
            base = CVPixelBufferGetBaseAddress(buffer)
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            stride = CVPixelBufferGetBytesPerRow(buffer)
            step = 4
            offset = 1
        } else { return nil }
        guard let base, width > columns, height > rows else { return nil }
        var output = [UInt8](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let y = (row * height + height / 2) / rows
            let line = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<columns {
                let x = (column * width + width / 2) / columns
                output[row * columns + column] = line[x * step + offset]
            }
        }
        return output
    }

    private func changedCells(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return a.count }
        let mask = pipMask?.insetBy(dx: -0.03, dy: -0.03)
        var count = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 12 {
            if let mask {
                let point = CGPoint(x: (CGFloat(index % 24) + 0.5) / 24,
                                    y: (CGFloat(index / 24) + 0.5) / 40)
                if mask.contains(point) { continue }
            }
            count += 1
        }
        return count
    }

    private func receiveAppAudio(_ sample: CMSampleBuffer, folder: URL) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mChannelsPerFrame >= 1, asbd.mChannelsPerFrame <= 2,
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let length = CMBlockBufferGetDataLength(block)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return }
        let rate = UInt32(asbd.mSampleRate)
        let channels = UInt8(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0

        if asbd.mBitsPerChannel == 16 && !isFloat && !nonInterleaved && asbd.mBytesPerFrame == asbd.mChannelsPerFrame * 2 {
            guard length >= frames * Int(asbd.mBytesPerFrame) else { return }
            if audioFrames > 0 && (rate != audioRate || channels != audioChannels || bigEndian != audioBigEndian) {
                flushAudio(to: folder)
            }
            audioRate = rate
            audioChannels = channels
            audioBigEndian = bigEndian
            var bytes = Data(count: frames * Int(asbd.mBytesPerFrame))
            let status = bytes.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: pointer.count,
                                           destination: pointer.baseAddress!)
            }
            guard status == noErr else { return }
            audioBytes.append(bytes)
            audioFrames += frames
        } else if (asbd.mBitsPerChannel == 32 && isFloat) || (asbd.mBitsPerChannel == 16 && !isFloat && nonInterleaved) {
            let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
            let chCount = Int(channels)
            let needed = frames * chCount * bytesPerSample
            guard length >= needed else { return }
            var raw = Data(count: needed)
            let status = raw.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: needed,
                                           destination: pointer.baseAddress!)
            }
            guard status == noErr else { return }
            if audioFrames > 0 && (rate != audioRate || channels != audioChannels || audioBigEndian != false) {
                flushAudio(to: folder)
            }
            audioRate = rate
            audioChannels = channels
            audioBigEndian = false
            var converted = Data(count: frames * chCount * 2)
            raw.withUnsafeBytes { srcRaw in
                converted.withUnsafeMutableBytes { dstRaw in
                    guard let dst = dstRaw.bindMemory(to: Int16.self).baseAddress else { return }
                    if isFloat {
                        guard let src = srcRaw.bindMemory(to: UInt32.self).baseAddress else { return }
                        for frame in 0..<frames {
                            for ch in 0..<chCount {
                                let srcIdx = nonInterleaved ? (ch * frames + frame) : (frame * chCount + ch)
                                let bits = bigEndian ? UInt32(bigEndian: src[srcIdx]) : UInt32(littleEndian: src[srcIdx])
                                let val = Float(bitPattern: bits)
                                let clamped = max(-1.0, min(1.0, val.isFinite ? val : 0))
                                dst[frame * chCount + ch] = Int16(clamping: Int(clamped * 32767.0)).littleEndian
                            }
                        }
                    } else {
                        guard let src = srcRaw.bindMemory(to: Int16.self).baseAddress else { return }
                        for frame in 0..<frames {
                            for ch in 0..<chCount {
                                let sample16 = src[ch * frames + frame]
                                let host = bigEndian ? Int16(bigEndian: sample16) : Int16(littleEndian: sample16)
                                dst[frame * chCount + ch] = host.littleEndian
                            }
                        }
                    }
                }
            }
            audioBytes.append(converted)
            audioFrames += frames
        } else {
            return
        }
        if audioFrames >= Int(asbd.mSampleRate * 0.20) { flushAudio(to: folder) }
    }

    private func flushAudio(to folder: URL) {
        guard audioFrames > 0, audioRate > 0 else { return }
        var packet = Data([81, 89, 65, 49])
        var rate = audioRate.littleEndian
        withUnsafeBytes(of: &rate) { packet.append(contentsOf: $0) }
        packet.append(audioChannels)
        packet.append(audioBigEndian ? 1 : 0)
        var frames = UInt32(audioFrames).littleEndian
        withUnsafeBytes(of: &frames) { packet.append(contentsOf: $0) }
        packet.append(audioBytes)
        audioSequence += 1
        let name = String(format: "voice-audio-%08d.bin", audioSequence)
        try? packet.write(to: folder.appendingPathComponent(name), options: .atomic)
        audioBytes.removeAll(keepingCapacity: true)
        audioFrames = 0
        if audioSequence % 8 == 0 {
            let queued = ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("voice-audio-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in queued.dropLast(100) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func writeJPEG(_ input: CIImage, longestSide: CGFloat, quality: CGFloat, to url: URL) {
        let scale = min(1, longestSide / max(input.extent.width, input.extent.height))
        let resized = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let data = context.jpegRepresentation(of: resized,
                                                     colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                     options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func writeState(_ state: String, to folder: URL) {
        try? state.write(to: folder.appendingPathComponent("capture.state"), atomically: true, encoding: .utf8)
    }
}
