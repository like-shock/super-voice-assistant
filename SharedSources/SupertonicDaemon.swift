import Foundation

/// Supertonic TTS 데몬 — Python 상주 프로세스와 stdin/stdout 바이너리 프로토콜로 통신
///
/// 프로토콜:
///   Request:  [4 bytes: text_length LE uint32][UTF-8 text]
///   Response: [4 bytes: pcm_length LE uint32][16-bit PCM @ 44100Hz mono]
///
/// 특수 명령: PING, QUIT, VOICE:X, LANG:X, SPEED:X
@available(macOS 14.0, *)
public class SupertonicDaemon: TTSAudioProvider {
    public let sampleRate: Double = 44100
    
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    
    private let pythonPath: String
    private let scriptPath: String
    private var voiceName: String
    private var lang: String
    private var speed: Double
    private var totalSteps: Int
    
    /// 데몬 프로세스 실행 중 여부
    public private(set) var isRunning: Bool = false
    
    /// 동시 접근 방지용 직렬 큐
    private let serialQueue = DispatchQueue(label: "supertonic.daemon.serial")
    
    /// 동시 합성 요청 직렬화용 actor
    private let synthesisLock = SynthesisLock()
    
    public init(
        pythonPath: String? = nil,
        scriptPath: String? = nil,
        voiceName: String = "M1",
        lang: String = "ko",
        speed: Double = 1.05,
        totalSteps: Int = 5
    ) {
        // venv python 경로 자동 탐색
        let bundlePath = Bundle.main.bundlePath
        let projectDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().path
        
        if let path = pythonPath {
            self.pythonPath = path
        } else {
            // 프로젝트 내 .venv 탐색
            let venvPython = projectDir + "/.venv/bin/python3"
            if FileManager.default.fileExists(atPath: venvPython) {
                self.pythonPath = venvPython
            } else {
                // 하드코딩된 폴백 경로
                let fallbackVenv = NSString("~/DATA/personal/50_hobbies/super-voice-assistant/.venv/bin/python3").expandingTildeInPath
                if FileManager.default.fileExists(atPath: fallbackVenv) {
                    self.pythonPath = fallbackVenv
                } else {
                    self.pythonPath = "/usr/bin/python3"
                }
            }
        }
        
        if let path = scriptPath {
            self.scriptPath = path
        } else {
            let projectScript = projectDir + "/scripts/supertonic_daemon.py"
            if FileManager.default.fileExists(atPath: projectScript) {
                self.scriptPath = projectScript
            } else {
                let fallbackScript = NSString("~/DATA/personal/50_hobbies/super-voice-assistant/scripts/supertonic_daemon.py").expandingTildeInPath
                self.scriptPath = fallbackScript
            }
        }
        
        self.voiceName = voiceName
        self.lang = lang
        self.speed = speed
        self.totalSteps = totalSteps
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Lifecycle
    
    /// 데몬 프로세스 시작. READY 신호까지 대기.
    public func start() async throws {
        if isRunning { return }
        
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw SupertonicError.scriptNotFound(scriptPath)
        }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath, voiceName, lang, String(speed), String(totalSteps)]
        
        // 환경변수 전달 (venv에서 필요할 수 있음)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.process = proc
        
        // 종료 감지
        proc.terminationHandler = { [weak self] process in
            print("⚠️ Supertonic daemon terminated with code \(process.terminationStatus)")
            self?.isRunning = false
        }
        
        try proc.run()
        
        // READY 대기 (최대 30초)
        let ready = try await waitForReady(timeout: 30)
        guard ready else {
            stop()
            throw SupertonicError.startupTimeout
        }
        
        isRunning = true
        print("✅ Supertonic daemon started (python: \(pythonPath), voice: \(voiceName), lang: \(lang))")
    }
    
    /// READY 시그널 대기
    private func waitForReady(timeout: TimeInterval) async throws -> Bool {
        guard let stderr = stderrHandle else { return false }
        
        return try await withCheckedThrowingContinuation { continuation in
            var buffer = Data()
            var resumed = false
            
            // 타임아웃 타이머
            let timer = DispatchSource.makeTimerSource(queue: serialQueue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard !resumed else { return }
                resumed = true
                timer.cancel()
                continuation.resume(returning: false)
            }
            timer.resume()
            
            // stderr 비동기 읽기
            DispatchQueue.global(qos: .userInitiated).async {
                while !resumed {
                    let chunk = stderr.availableData
                    if chunk.isEmpty { break }
                    
                    buffer.append(chunk)
                    if let text = String(data: buffer, encoding: .utf8) {
                        // stderr 로그 출력
                        for line in text.components(separatedBy: "\n") where !line.isEmpty {
                            print("🐍 [supertonic] \(line)")
                        }
                        
                        if text.contains("READY") {
                            guard !resumed else { return }
                            resumed = true
                            timer.cancel()
                            continuation.resume(returning: true)
                            return
                        }
                    }
                }
            }
        }
    }
    
    /// 데몬 종료
    public func stop() {
        guard let proc = process, proc.isRunning else {
            isRunning = false
            return
        }
        
        // QUIT 명령 전송 시도
        if let stdin = stdinHandle {
            let quitBytes = "QUIT".data(using: .utf8)!
            var len = UInt32(quitBytes.count).littleEndian
            let header = Data(bytes: &len, count: 4)
            try? stdin.write(contentsOf: header)
            try? stdin.write(contentsOf: quitBytes)
        }
        
        // 1초 대기 후 강제 종료
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak proc] in
            if let proc = proc, proc.isRunning {
                proc.terminate()
            }
        }
        
        isRunning = false
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        
        print("🛑 Supertonic daemon stopped")
    }
    
    // MARK: - TTSAudioProvider
    
    /// 텍스트를 PCM 오디오 청크 스트림으로 변환
    /// 문장 단위로 쪼개서 각각 합성 → 즉시 yield
    public func collectAudioChunks(from text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let sentences = SmartSentenceSplitter.splitIntoSentences(text)
                    print("📖 [Supertonic] Split into \(sentences.count) sentences")
                    
                    for (index, sentence) in sentences.enumerated() {
                        try Task.checkCancellation()
                        
                        let pcmData = try await self.synthesize(sentence)
                        
                        if !pcmData.isEmpty {
                            print("🎵 [Supertonic] Sentence \(index+1)/\(sentences.count): \(pcmData.count) bytes")
                            continuation.yield(pcmData)
                        }
                        
                        // 문장 간 무음 (0.25초 @ 44100Hz, 16-bit)
                        if index < sentences.count - 1 {
                            let silenceSamples = Int(self.sampleRate * 0.25)
                            let silenceData = Data(count: silenceSamples * 2)
                            continuation.yield(silenceData)
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Synthesis
    
    /// 단일 텍스트 합성 (직렬화됨)
    public func synthesize(_ text: String) async throws -> Data {
        return try await synthesisLock.run {
            try await self._synthesize(text)
        }
    }
    
    /// 실제 합성 (내부용, synthesisLock 내에서만 호출)
    private func _synthesize(_ text: String) async throws -> Data {
        guard isRunning, let stdin = stdinHandle, let stdout = stdoutHandle else {
            throw SupertonicError.daemonNotRunning
        }
        
        let textData = text.data(using: .utf8)!
        
        // 요청 전송: [4 bytes length][text]
        var len = UInt32(textData.count).littleEndian
        let header = Data(bytes: &len, count: 4)
        
        try stdin.write(contentsOf: header)
        try stdin.write(contentsOf: textData)
        
        // 응답 읽기: [4 bytes pcm_length][pcm_data]
        let respHeader = stdout.readData(ofLength: 4)
        guard respHeader.count == 4 else {
            throw SupertonicError.protocolError("Failed to read response header")
        }
        
        let pcmLen = respHeader.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        
        if pcmLen == 0 {
            return Data()
        }
        
        // PCM 데이터 읽기 (큰 데이터는 여러 번에 나눠 올 수 있음)
        var pcmData = Data()
        pcmData.reserveCapacity(Int(pcmLen))
        
        while pcmData.count < pcmLen {
            let remaining = Int(pcmLen) - pcmData.count
            let chunk = stdout.readData(ofLength: remaining)
            if chunk.isEmpty {
                throw SupertonicError.protocolError("Unexpected EOF reading PCM data")
            }
            pcmData.append(chunk)
        }
        
        // stderr 로그 소비 (블로킹 방지)
        drainStderr()
        
        return pcmData
    }
    
    // MARK: - Commands
    
    /// 음성 스타일 변경
    public func setVoice(_ name: String) async throws {
        try await sendCommand("VOICE:\(name)")
        voiceName = name
    }
    
    /// 언어 변경
    public func setLang(_ newLang: String) async throws {
        try await sendCommand("LANG:\(newLang)")
        lang = newLang
    }
    
    /// 속도 변경
    public func setSpeed(_ newSpeed: Double) async throws {
        try await sendCommand("SPEED:\(newSpeed)")
        speed = newSpeed
    }
    
    /// 특수 명령 전송 (ACK 대기)
    private func sendCommand(_ command: String) async throws {
        guard isRunning, let stdin = stdinHandle, let stdout = stdoutHandle else {
            throw SupertonicError.daemonNotRunning
        }
        
        let cmdData = command.data(using: .utf8)!
        var len = UInt32(cmdData.count).littleEndian
        let header = Data(bytes: &len, count: 4)
        
        try stdin.write(contentsOf: header)
        try stdin.write(contentsOf: cmdData)
        
        // ACK (빈 응답) 읽기
        let ack = stdout.readData(ofLength: 4)
        guard ack.count == 4 else {
            throw SupertonicError.protocolError("Failed to read command ACK")
        }
        
        drainStderr()
    }
    
    // MARK: - Helpers
    
    /// stderr 비동기 drain (로그 출력, 블로킹 방지)
    private func drainStderr() {
        guard let stderr = stderrHandle else { return }
        
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    print("🐍 [supertonic] \(line)")
                }
            }
        }
    }
    
    /// 현재 설정 정보
    public var info: String {
        "SupertonicDaemon(voice=\(voiceName), lang=\(lang), speed=\(speed), running=\(isRunning))"
    }
}

// MARK: - SynthesisLock (동시 요청 직렬화)

private actor SynthesisLock {
    func run<T>(_ body: () async throws -> T) async throws -> T {
        return try await body()
    }
}

// MARK: - Errors

public enum SupertonicError: Error, LocalizedError {
    case scriptNotFound(String)
    case startupTimeout
    case daemonNotRunning
    case protocolError(String)
    case synthesisError(String)
    
    public var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            return "Supertonic daemon script not found: \(path)"
        case .startupTimeout:
            return "Supertonic daemon failed to start within timeout"
        case .daemonNotRunning:
            return "Supertonic daemon is not running"
        case .protocolError(let msg):
            return "Supertonic protocol error: \(msg)"
        case .synthesisError(let msg):
            return "Supertonic synthesis error: \(msg)"
        }
    }
}
