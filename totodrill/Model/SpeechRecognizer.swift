//
//  SpeechRecognizer.swift
//  totodrill
//
//  Created by Jesus Lopez on 12/4/23.
//

import Foundation
import Speech
import SoundAnalysis

@Observable
class SpeechRecognizer {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!

    private let speechRecognizerDelegate = SpeechRecognizerDelegate()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var lmConfiguration: SFSpeechLanguageModel.Configuration = {
        let outputDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dynamicLanguageModel = outputDir.appendingPathComponent("LM")
        let dynamicVocabulary = outputDir.appendingPathComponent("Vocab")
        return SFSpeechLanguageModel.Configuration(languageModel: dynamicLanguageModel, vocabulary: dynamicVocabulary)
    }()

    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var resultsObserver: ResultsObserver?
    private var audioStartTimestamp: Int64?
    private var recordingFormat: AVAudioFormat?
    private let analysisQueue = DispatchQueue(label: "com.jesusla.totodrill.AnalysisQueue")

    func authorize() {
        // Configure the SFSpeechRecognizer object already
        // stored in a local member variable.
        speechRecognizer.delegate = speechRecognizerDelegate

        // Make the authorization request.
        SFSpeechRecognizer.requestAuthorization { authStatus in

            // Divert to the app's main thread so that the UI
            // can be updated.
            OperationQueue.main.addOperation {
                switch authStatus {
                case .authorized:
                    if #available(iOS 17, *) {
                        Task.detached {
                            do {
                                let assetPath = Bundle.main.path(forResource: "CustomLMData", ofType: "bin", inDirectory: "customlm/en_US")!
                                let assetUrl = URL(fileURLWithPath: assetPath)

                                try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: assetUrl,
                                                                                           clientIdentifier: "com.apple.SpokenWord",
                                                                                           configuration: self.lmConfiguration)
                            } catch {
                                NSLog("Failed to prepare custom LM: \(error.localizedDescription)")
                            }
                            logger.debug("Custom LM prepared")
                        }
                    } else {
                        logger.debug("LM ready")
                    }
                case .denied:
                    logger.debug(".denied")

                case .restricted:
                    logger.debug(".denied")

                case .notDetermined:
                    logger.debug(".denied")

                default:
                    logger.debug("default")
                }
            }
        }
    }

    func startRecording() throws {

        // Cancel the previous task if it's running.
        if let recognitionTask = recognitionTask {
            recognitionTask.cancel()
            self.recognitionTask = nil
        }

        // Configure the audio session for the app.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        let inputNode = audioEngine.inputNode

        // Create and configure the speech recognition request.
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { fatalError("Unable to created a SFSpeechAudioBufferRecognitionRequest object") }
        recognitionRequest.shouldReportPartialResults = true

        // Keep speech recognition data on device
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = true
            if #available(iOS 17, *) {
                recognitionRequest.customizedLanguageModel = self.lmConfiguration
            }
        }

        // Create a recognition task for the speech recognition session.
        // Keep a reference to the task so that it can be canceled.
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
            var isFinal = false

            if let result = result {
                
//                logger.debug("\(result.isFinal ? "Final t" : "T")ranscription: \(result.bestTranscription.formattedString)")
                // Update the text view with the results.
//                logger.debug("Best Transcription: \(result.bestTranscription)")
                if result.isFinal {
                    for (transcriptionIndex, transcription) in result.transcriptions.enumerated() {
                        for segment in transcription.segments {
                            let start = segment.timestamp
                            let duration = segment.duration
                            logger.debug("\(transcriptionIndex + 1) \(start, format: .fixed(precision: 2)) - \(duration, format: .fixed(precision: 2)): \(segment.substring)")
                        }
    //                    logger.debug("Transcription: \(transcription.debugDescription)")
                    }
    //                logger.debug("IsFinal: \(result.isFinal)")
                    if let metadata = result.speechRecognitionMetadata {
                        //                    logger.debug("  averagePauseDuration: \(metadata.averagePauseDuration)")
                        //                    logger.debug("  speakingRate: \(metadata.speakingRate)")
                        //                    logger.debug("  speechStartTimestamp: \(metadata.speechStartTimestamp)")
                        //                    logger.debug("  speechDuration: \(metadata.speechDuration)")
                        if let analytics = metadata.voiceAnalytics {
                            //                        logger.debug("    jitter: \(analytics.jitter)")
                            //                        logger.debug("    shimmer: \(analytics.shimmer)")
                            //                        logger.debug("    pitch: \(analytics.pitch)")
                            //                        logger.debug("    voicing: \(analytics.voicing)")
                        }
                    }
                }
                isFinal = result.isFinal
            }

            if error != nil || isFinal {
                // Stop recognizing speech if there is a problem.
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)

                self.recognitionRequest = nil
                self.recognitionTask = nil

                logger.debug("Recording stopped: \(error)")
            }
        }

        // Configure the microphone input.
        recordingFormat = inputNode.outputFormat(forBus: 0)
        audioStartTimestamp = nil
        inputNode.installTap(onBus: 0, bufferSize: 24000, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            if self.audioStartTimestamp == nil {
                self.audioStartTimestamp = when.sampleTime
                self.resultsObserver!.audioStartTimestamp = when.sampleTime
            }
            self.recognitionRequest?.append(buffer)
            self.analysisQueue.async {
//                logger.debug("* \(self.secondsIntoRecording(when.sampleTime), format: .fixed(precision: 2))")
                self.streamAnalyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
            }
        }

        // Create sound classification request
        let classifyRequest = try! SNClassifySoundRequest(classifierIdentifier: .version1)
        classifyRequest.windowDuration = switch classifyRequest.windowDurationConstraint {
        case .enumeratedDurations(let array): array.first!
        case .durationRange(let timeRange): timeRange.start
        default: classifyRequest.windowDuration
        }
        switch classifyRequest.windowDurationConstraint {
        case .durationRange(timeRange: let range):
            logger.debug("Duration range - Start: \(CMTimeCopyDescription(allocator: nil, time: range.start)), Duration: \(CMTimeCopyDescription(allocator: nil, time: range.duration))")
        case .enumeratedDurations(let durations):
            for duration in durations {
                logger.debug("Enumerated duration: \(CMTimeCopyDescription(allocator: nil, time: duration))")
            }
        default:
            logger.debug("Unknown duration constraint")
        }
        logger.debug("Window Duration: \(CMTimeCopyDescription(allocator: nil, time: classifyRequest.windowDuration))")
        resultsObserver = ResultsObserver(recordingFormat: recordingFormat!)
        streamAnalyzer = SNAudioStreamAnalyzer(format: recordingFormat!)
        try! streamAnalyzer!.add(classifyRequest, withObserver: resultsObserver!)

        audioEngine.prepare()
        try audioEngine.start()

        // Let the user know to start talking.
        logger.debug("(Go ahead, I'm listening)")
    }

    func secondsIntoRecording(_ frame: Int64) -> Double {
        Double(frame - audioStartTimestamp!) / recordingFormat!.sampleRate
    }

    func recordButtonTapped() {
        if audioEngine.isRunning {
            audioEngine.stop()
            recognitionRequest?.endAudio()
            streamAnalyzer?.completeAnalysis()
        } else {
            do {
                try startRecording()
            } catch {
                logger.debug("Unable to start recording: \(error.localizedDescription)")
            }
        }
    }

    /// An observer that receives results from a classify sound request.
    private class ResultsObserver: NSObject, SNResultsObserving {
        var audioStartTimestamp: Int64?
        var recordingFormat: AVAudioFormat

        init(recordingFormat: AVAudioFormat) {
            self.recordingFormat = recordingFormat
        }

        func secondsIntoRecording(_ frame: Int64) -> Double {
            Double(frame - audioStartTimestamp!) / recordingFormat.sampleRate
        }

        /// Notifies the observer when a request generates a prediction.
        func request(_ request: SNRequest, didProduce result: SNResult) {
            // Downcast the result to a classification result.
            guard let result = result as? SNClassificationResult else  { return }


            // Get the prediction with the highest confidence.
            guard let classification = result.classifications.first else { return }


            // Get the starting time.
            let start = result.timeRange.start
            let duration = result.timeRange.duration

            // Convert the time to a human-readable string.
            logger.debug("A \(self.secondsIntoRecording(start.value)) - \(duration.seconds, format: .fixed(precision: 2)): \(classification.identifier): \(classification.confidence * 100, format: .fixed)%")
        }




        /// Notifies the observer when a request generates an error.
        func request(_ request: SNRequest, didFailWithError error: Error) {
            print("The analysis failed: \(error.localizedDescription)")
        }


        /// Notifies the observer when a request is complete.
        func requestDidComplete(_ request: SNRequest) {
            print("The request completed successfully!")
        }
    }

    private class SpeechRecognizerDelegate : NSObject, SFSpeechRecognizerDelegate {
        // MARK: SFSpeechRecognizerDelegate

        public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
            logger.debug("Speech recognizer availability changed to \(available)")
        }
    }
}
