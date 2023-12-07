//
//  ContentView.swift
//  totodrill
//
//  Created by Jesus Lopez on 12/4/23.
//

import SwiftUI
import AVKit

struct ContentView: View {
    @Environment(SpeechRecognizer.self) var speechRecognizer
    @State var isRecording = false
    @State var bm = Benchmark()

    var body: some View {
        Form {
            Section {
                Button("Authorize") { speechRecognizer.authorize() }
                Button("Record") { speechRecognizer.recordButtonTapped()}
            }
            Section {
                Toggle("Recording", isOn: $isRecording)
                Button("Dump Stats") { bm.dumpStats() }
            }
        }
        //.task(id: isRecording, handleRecording)
        .recordAudio(isRecording: isRecording) { frames in
            for await frame in frames {
                logger.info("\(frame.timestamp, format: .fixed(precision: 0)): Received \(frame.buffer.frameLength) samples")
            }
        }
    }

    @Sendable func handleRecording() async  {
        guard isRecording else { return }

        // Configure the audio session for the app.
        let audioSession = AVAudioSession.sharedInstance() // 24ms 3ms±7ms
        try! audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try! audioSession.setActive(true, options: .notifyOthersOnDeactivation) // 129ms 130ms±4ms

        // Configure the audio engine
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode // 987ms 138ms±300ms
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let stream = AsyncStream { continuation in
            inputNode.installTap(onBus: 0, bufferSize: 24_000, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                continuation.yield((buffer, when))
            }
        }

        // Start the audio engine
        audioEngine.prepare()
        try! audioEngine.start() // 57ms 52ms±3ms

        // Streaming
        for await (buffer, when) in stream {
            if Task.isCancelled { break }
            logger.info("buffer: \(buffer) when: \(when)")
        }

        // Stop the audio engine
        inputNode.removeTap(onBus: 0)
        audioEngine.stop() // 29ms 28ms±2ms
        try! audioSession.setActive(false, options: .notifyOthersOnDeactivation) // 181ms  192ms±59ms
    }
}

struct RecordAudioFrame {
    var buffer: AVAudioPCMBuffer
    var audioTime: AVAudioTime
    var sampleTime: Int64

    var timestamp: Double {
        Double(sampleTime) / audioTime.sampleRate
    }
}

extension View {
    func recordAudio(isRecording: Bool, audioTask: @escaping (AsyncStream<RecordAudioFrame>) async throws -> ()) -> some View {
        // modifier(OldRecordAudioModifier(isRecording: isRecording, audioTask: audioTask))
        modifier(RecordAudioModifier(isRecording: isRecording, audioTask: audioTask))
    }
}

fileprivate struct RecordAudioController {
    var audioEngine: AVAudioEngine?
    var frameAsyncStream: AsyncStream<RecordAudioFrame>?

    mutating func prepare() {
        guard audioEngine == nil else {
            logger.warning("RecordAudioController already prepared")
            return
        }

        // Configure the audio session for the app.
        let audioSession = AVAudioSession.sharedInstance() // 24ms 3ms±7ms
        do { try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers) }
        catch {
            logger.error("Unable to set audioSession category: \(error)")
            return
        }
        do { try audioSession.setActive(true, options: .notifyOthersOnDeactivation) } // 129ms 130ms±4ms
        catch {
            logger.error("Unable to activate audioSession: \(error)")
            return
        }

        // Create the audio engine
        audioEngine = AVAudioEngine()

        // Ready the async squence
        prepareAsyncSequence()

        // Prepare engine
        audioEngine!.prepare()
    }

    private mutating func prepareAsyncSequence() {
        // Create tap and async sequence
        let inputNode = audioEngine!.inputNode // 987ms 138ms±300ms
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        var initialSampleTime: Int64?
        frameAsyncStream = AsyncStream<RecordAudioFrame> { continuation in
            inputNode.installTap(onBus: 0, bufferSize: 24_000, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                if initialSampleTime == nil { initialSampleTime = when.sampleTime }
                let sampleTime = when.sampleTime - initialSampleTime!
                let audioFrame = RecordAudioFrame(buffer: buffer, audioTime: when, sampleTime: sampleTime)
                continuation.yield(audioFrame)
            }
        }
    }

    mutating func record(audioTask: (AsyncStream<RecordAudioFrame>) async throws -> ()) async {
        guard let audioEngine = audioEngine, let frameAsyncStream = frameAsyncStream else {
            logger.error("RecordAudioController not prepared")
            return
        }

        // Start the audio engine
        do { try audioEngine.start() } // 57ms 52ms±3ms
        catch {
            logger.error("Unable to start audioEngine: \(error)")
            return
        }
        defer {
            stop()
            prepareAsyncSequence()
        }

        // Call the audio task providing the audio async sequence
        do { try await audioTask(frameAsyncStream) }
        catch {
            if !Task.isCancelled {
                logger.error("AudioTask error: \(error)")
            }
        }
    }

    mutating func stop() {
        guard let audioEngine = audioEngine else { return }

        let inputNode = audioEngine.inputNode // ???ms±???ms
        inputNode.removeTap(onBus: 0)
        audioEngine.stop() // 29ms 28ms±2ms
    }

    mutating func release() {
        guard audioEngine != nil else { return }

        stop()
        audioEngine = nil

        let audioSession = AVAudioSession.sharedInstance() // 24ms 3ms±7ms
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) // 181ms  192ms±59ms
    }
}

fileprivate struct RecordAudioModifier : ViewModifier {
    let isRecording: Bool
    let audioTask: (AsyncStream<RecordAudioFrame>) async throws -> ()

    @State private var controller = RecordAudioController()

    init(isRecording: Bool, audioTask: @escaping (AsyncStream<RecordAudioFrame>) async throws -> Void) {
        self.isRecording = isRecording
        self.audioTask = audioTask
    }

    func body(content: Content) -> some View {
        content
            .onAppear { controller.prepare() }
            .onDisappear { controller.release() }
            .task(id: isRecording, handleRecording)
    }

    @Sendable func handleRecording() async  {
        guard isRecording else { return }

        await controller.record(audioTask: audioTask)
    }
}

// Old version, delete once RecordAudioModifier works
fileprivate struct OldRecordAudioModifier : ViewModifier {
    let isRecording: Bool
    let audioTask: (AsyncStream<RecordAudioFrame>) async throws -> ()

    func body(content: Content) -> some View {
        content
            .task(id: isRecording, handleRecording)
    }

    @Sendable func handleRecording() async  {
        guard isRecording else { return }

        // Configure the audio session for the app.
        let audioSession = AVAudioSession.sharedInstance() // 24ms 3ms±7ms
        do { try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers) }
        catch {
            logger.error("Unable to set audioSession category: \(error)")
            return
        }
        do { try audioSession.setActive(true, options: .notifyOthersOnDeactivation) } // 129ms 130ms±4ms
        catch {
            logger.error("Unable to activate audioSession: \(error)")
            return
        }
        defer {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) // 181ms  192ms±59ms
        }

        // Configure the audio engine
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode // 987ms 138ms±300ms
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Create tap and async sequence
        var initialSampleTime: Int64?
        let stream = AsyncStream<RecordAudioFrame> { continuation in
            inputNode.installTap(onBus: 0, bufferSize: 24_000, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                if initialSampleTime == nil { initialSampleTime = when.sampleTime }
                let sampleTime = when.sampleTime - initialSampleTime!
                let audioFrame = RecordAudioFrame(buffer: buffer, audioTime: when, sampleTime: sampleTime)
                continuation.yield(audioFrame)
            }
        }
        defer {
            inputNode.removeTap(onBus: 0)
        }

        // Start the audio engine
        audioEngine.prepare()
        do { try audioEngine.start() } // 57ms 52ms±3ms
        catch {
            logger.error("Unable to start audioEngine: \(error)")
            return
        }
        defer {
            audioEngine.stop() // 29ms 28ms±2ms
        }

        // Call the audio task providing the audio async sequence
        do { try await audioTask(stream) }
        catch {
            if !Task.isCancelled {
                logger.error("AudioTask error: \(error)")
            }
        }
    }
}

struct Benchmark {
    var ts0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    var stats = [String: Stat]()

    mutating func lap(_ message: String) {
        let ts1 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let delta = ts1 - ts0
        let stat = stats[message] ?? Stat()
        stats[message] = stat.update(delta)
        ts0 = ts1
    }

    mutating func reset() {
        ts0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    func dumpStats() {
        for (key, value) in stats.sorted(by: { $0.value.mean > $1.value.mean }) {
            logger.info("\(key): \(value)")
        }
    }
}

struct Stat {
    var sum: UInt64 = 0
    var sumOfSquares: UInt64 = 0
    var count: UInt64 = 0

    var mean: Double {
        Double(sum) / Double(count)
    }

    var variance: Double {
        return Double(sumOfSquares) / Double(count) - mean * mean
    }

    var stddev: Double {
        sqrt(variance)
    }

    func update(_ delta: UInt64) -> Stat {
        var stat = self
        stat.sum += delta
        stat.sumOfSquares += delta * delta
        stat.count += 1
        return stat
    }
}

extension Stat: CustomStringConvertible {
    var description: String {
        // Display mean and stddev as "123ms±456ms"
        let mean = String(format: "%.0f", self.mean / 1_000_000)
        let stddev = String(format: "%.0f", self.stddev / 1_000_000)
        return "\(mean)ms±\(stddev)ms"
    }
}

#Preview {
    ContentView()
        .environment(SpeechRecognizer())
}
