import AVFoundation
import Foundation
import Speech
import RecorderCore

/// On-device speech recognition of `mic.m4a` into timed words (source seconds = mic seconds).
/// Never uses the server: fails clearly when on-device recognition is unavailable.
/// macOS 26+: SpeechAnalyzer + SpeechTranscriber (long-form model, always on-device, system-managed assets).
/// macOS 15: SFSpeechRecognizer with `requiresOnDeviceRecognition`.
enum Transcriber {
    struct Failure: Error, LocalizedError {
        let errorDescription: String?
    }

    static func words(in audio: URL) async throws -> [Word] {
        if #available(macOS 26, *) { return try await analyzerWords(in: audio) }
        return try await recognizerWords(in: audio)
    }

    @available(macOS 26, *)
    static func analyzerWords(in audio: URL) async throws -> [Word] {
        guard SpeechTranscriber.isAvailable else { throw Failure(errorDescription: "On-device speech transcription is not available on this Mac.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw Failure(errorDescription: "On-device speech transcription does not support \(Locale.current.identifier).")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()  // first use per language: the system downloads the model once
        }
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Collect concurrently: results stream while the file is analysed and end when the analyzer finishes.
        let collect = Task {
            var words: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, let range = run.audioTimeRange else { continue }
                    words.append(Word(text: text, start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw error
        }
        return try await collect.value
    }

    static func recognizerWords(in audio: URL) async throws -> [Word] {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else {
            throw Failure(errorDescription: "Speech Recognition is not allowed. Enable Recorder in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw Failure(errorDescription: "Speech recognition is unavailable for \(Locale.current.identifier).")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw Failure(errorDescription: "On-device speech recognition is not available for \(Locale.current.identifier); captions are never sent to a server.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { c in
            var done = false
            // Long audio arrives as one result per utterance (absolute timestamps); the final one repeats only the last utterance.
            var utterances: [Double: [Word]] = [:]
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result {
                    let words = result.bestTranscription.segments.map {
                        Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    if let first = words.first { utterances[first.start] = words }
                }
                if let result, result.isFinal {
                    done = true
                    c.resume(returning: utterances.sorted { $0.key < $1.key }.flatMap(\.value))
                } else if let error {
                    done = true
                    c.resume(throwing: error)
                }
            }
        }
    }
}
