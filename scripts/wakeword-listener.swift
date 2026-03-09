import AVFoundation
import Foundation

struct ListenerOptions {
	let modelPath: String
	let pythonPath: String
	let toolsPath: String
	let actionScriptPath: String
	let logPath: String
	let stateDir: String
}

enum ListenerArgumentError: Error {
	case missingValue(String)
	case unknownArgument(String)
}

struct CalibrationThresholds {
	let listenerStartRmsNorm: Double
	let idleListenerStartRmsNorm: Double
	let idleStartChunkCount: Int
	let minRmsNorm: Double
	let minSegmentDurationMs: Double
	let maxPhraseDurationMs: Double
	let cooldownMs: Int
	let idleToggleScoreThreshold: Double
	let idleTogglePrototypeThreshold: Double
	let idleToggleRivalGapMin: Double
	let activeCueGapMin: Double
}

func parseListenerArguments() throws -> ListenerOptions {
	var values: [String: String] = [:]
	var iterator = CommandLine.arguments.dropFirst().makeIterator()
	while let argument = iterator.next() {
		guard argument.hasPrefix("--") else {
			throw ListenerArgumentError.unknownArgument(argument)
		}
		guard let value = iterator.next() else {
			throw ListenerArgumentError.missingValue(argument)
		}
		values[String(argument.dropFirst(2))] = value
	}

	guard
		let modelPath = values["model"],
		let pythonPath = values["python"],
		let toolsPath = values["tools"],
		let actionScriptPath = values["action-script"],
		let logPath = values["log"]
	else {
		throw ListenerArgumentError.missingValue("required arguments")
	}

	return ListenerOptions(
		modelPath: modelPath,
		pythonPath: pythonPath,
		toolsPath: toolsPath,
		actionScriptPath: actionScriptPath,
		logPath: logPath,
		stateDir: values["state-dir"] ?? "/tmp/dji-dictation"
	)
}

final class WakewordListener {
	private let options: ListenerOptions
	private let thresholds: CalibrationThresholds
	private let engine = AVAudioEngine()
	private let processingQueue = DispatchQueue(label: "dji.wakeword.listener.processing")
	private let logQueue = DispatchQueue(label: "dji.wakeword.listener.log")
	private let tempDir: URL
	private let stateDir: URL
	private let trailingSilenceMs = 360.0
	private let preRollMs = 160.0
	private var signalSources: [DispatchSourceSignal] = []
	private var sampleRate: Double = 0.0
	private var isCapturing = false
	private var preRoll: [Float] = []
	private var capture: [Float] = []
	private var lastSpeechAt = Date.distantPast
	private var lastTriggerAt = Date.distantPast
	private var segmentCounter = 0
	private var pendingStartChunks = 0

	init(options: ListenerOptions) throws {
		self.options = options
		self.thresholds = try Self.loadCalibrationThresholds(from: options.modelPath)
		self.stateDir = URL(fileURLWithPath: options.stateDir, isDirectory: true)
		self.tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("dji-wakeword-listener", isDirectory: true)
		try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
	}

	private static func loadCalibrationThresholds(from path: String) throws -> CalibrationThresholds {
		let data = try Data(contentsOf: URL(fileURLWithPath: path))
		let raw = try JSONSerialization.jsonObject(with: data, options: [])
		guard let dictionary = raw as? [String: Any] else {
			throw NSError(domain: "WakewordListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid calibration JSON"])
		}

		let classThresholds = dictionary["class_thresholds"] as? [String: Any]
		let toggleThreshold = (classThresholds?["toggle"] as? NSNumber)?.doubleValue
			?? (dictionary["distance_threshold"] as? NSNumber)?.doubleValue
			?? 0.5
		let listenerStartRmsNorm = (dictionary["listener_start_rms_norm"] as? NSNumber)?.doubleValue ?? 0.0055
		let minRmsNorm = (dictionary["min_rms_norm"] as? NSNumber)?.doubleValue ?? 0.006

		return CalibrationThresholds(
			listenerStartRmsNorm: listenerStartRmsNorm,
			idleListenerStartRmsNorm: (dictionary["idle_listener_start_rms_norm"] as? NSNumber)?.doubleValue
				?? max(0.0105, max(listenerStartRmsNorm * 1.22, minRmsNorm * 1.55)),
			idleStartChunkCount: max(1, (dictionary["idle_start_chunk_count"] as? NSNumber)?.intValue ?? 2),
			minRmsNorm: minRmsNorm,
			minSegmentDurationMs: (dictionary["min_segment_duration_ms"] as? NSNumber)?.doubleValue ?? 180.0,
			maxPhraseDurationMs: (dictionary["max_phrase_duration_ms"] as? NSNumber)?.doubleValue ?? 1800.0,
			cooldownMs: (dictionary["recommended_cooldown_ms"] as? NSNumber)?.intValue ?? 850,
			idleToggleScoreThreshold: (dictionary["idle_toggle_score_threshold"] as? NSNumber)?.doubleValue
				?? max(0.66, toggleThreshold + 0.08),
			idleTogglePrototypeThreshold: (dictionary["idle_toggle_prototype_threshold"] as? NSNumber)?.doubleValue ?? 0.16,
			idleToggleRivalGapMin: (dictionary["idle_toggle_rival_gap_min"] as? NSNumber)?.doubleValue ?? 0.44,
			activeCueGapMin: (dictionary["active_cue_gap_min"] as? NSNumber)?.doubleValue ?? 0.28
		)
	}

	func run() {
		setupSignalHandlers()
		requestMicrophoneAccess()
		RunLoop.main.run()
	}

	private func requestMicrophoneAccess() {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized:
			startAudioEngine()
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					if granted {
						self.startAudioEngine()
					} else {
						self.log("microphone_access_denied")
						exit(1)
					}
				}
			}
		default:
			log("microphone_access_denied")
			exit(1)
		}
	}

	private func setupSignalHandlers() {
		signal(SIGTERM, SIG_IGN)
		signal(SIGINT, SIG_IGN)
		for signalValue in [SIGTERM, SIGINT] {
			let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
			source.setEventHandler { [weak self] in
				self?.shutdown()
			}
			source.resume()
			signalSources.append(source)
		}
	}

	private func startAudioEngine() {
		let inputNode = engine.inputNode
		let format = inputNode.outputFormat(forBus: 0)
		sampleRate = format.sampleRate
		let bufferSize = AVAudioFrameCount(max(1024, Int(sampleRate / 25.0)))

		inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
			guard let self else {
				return
			}
			let mono = self.extractMonoSamples(from: buffer)
			guard !mono.isEmpty else {
				return
			}
			self.processingQueue.async {
				self.consume(samples: mono)
			}
		}

		do {
			try engine.start()
			log("listener_started sample_rate=\(Int(sampleRate)) cooldown_ms=\(thresholds.cooldownMs)")
			print("{\"status\":\"listening\"}")
			fflush(stdout)
		} catch {
			log("listener_start_failed \(error.localizedDescription)")
			exit(1)
		}
	}

	private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
		let frameLength = Int(buffer.frameLength)
		guard frameLength > 0 else {
			return []
		}

		if let floatData = buffer.floatChannelData {
			let channelCount = Int(buffer.format.channelCount)
			let primary = floatData[0]
			if channelCount == 1 {
				return Array(UnsafeBufferPointer(start: primary, count: frameLength))
			}
			var mono = Array(repeating: Float(0), count: frameLength)
			for channelIndex in 0..<channelCount {
				let channel = floatData[channelIndex]
				for frameIndex in 0..<frameLength {
					mono[frameIndex] += channel[frameIndex]
				}
			}
			return mono.map { $0 / Float(channelCount) }
		}

		if let int16Data = buffer.int16ChannelData {
			let channelCount = Int(buffer.format.channelCount)
			let primary = int16Data[0]
			if channelCount == 1 {
				return Array(UnsafeBufferPointer(start: primary, count: frameLength)).map { Float($0) / 32768.0 }
			}
			var mono = Array(repeating: Float(0), count: frameLength)
			for channelIndex in 0..<channelCount {
				let channel = int16Data[channelIndex]
				for frameIndex in 0..<frameLength {
					mono[frameIndex] += Float(channel[frameIndex]) / 32768.0
				}
			}
			return mono.map { $0 / Float(channelCount) }
		}

		return []
	}

	private func consume(samples: [Float]) {
		let now = Date()
		let rms = chunkRms(samples)
		let workflowState = currentWorkflowState()
		let idleState = workflowState == "idle"
		let speechThreshold = max(0.005, idleState ? thresholds.idleListenerStartRmsNorm : thresholds.listenerStartRmsNorm)
		let silenceThreshold = max(0.0035, speechThreshold * 0.55)
		let cooldownSeconds = Double(thresholds.cooldownMs) / 1000.0
		let maxSamples = Int(sampleRate * ((thresholds.maxPhraseDurationMs + 420.0) / 1000.0))
		let preRollSamples = Int(sampleRate * (preRollMs / 1000.0))
		let minimumSegmentMs = thresholds.minSegmentDurationMs

		if !isCapturing {
			preRoll.append(contentsOf: samples)
			if preRoll.count > preRollSamples {
				preRoll.removeFirst(preRoll.count - preRollSamples)
			}

			guard now.timeIntervalSince(lastTriggerAt) >= cooldownSeconds else {
				return
			}
			guard rms >= speechThreshold else {
				pendingStartChunks = 0
				return
			}
			pendingStartChunks += 1
			let requiredStartChunks = idleState ? thresholds.idleStartChunkCount : 1
			guard pendingStartChunks >= requiredStartChunks else {
				return
			}
			pendingStartChunks = 0
			isCapturing = true
			capture = preRoll
			capture.append(contentsOf: samples)
			lastSpeechAt = now
			return
		}

		capture.append(contentsOf: samples)
		if rms >= silenceThreshold {
			lastSpeechAt = now
		}

		let captureDurationMs = (Double(capture.count) / sampleRate) * 1000.0
		let silenceDurationMs = now.timeIntervalSince(lastSpeechAt) * 1000.0
		if capture.count >= maxSamples || silenceDurationMs >= trailingSilenceMs {
			let finalized = capture
			capture.removeAll(keepingCapacity: true)
			preRoll.removeAll(keepingCapacity: true)
			pendingStartChunks = 0
			isCapturing = false
			if captureDurationMs >= minimumSegmentMs {
				evaluate(segment: finalized)
			}
		}
	}

	private func evaluate(segment: [Float]) {
		segmentCounter += 1
		let clipName = "candidate-\(Int(Date().timeIntervalSince1970 * 1000))-\(segmentCounter).wav"
		let clipURL = tempDir.appendingPathComponent(clipName)
		do {
			try writeWave(samples: segment, sampleRate: Int(sampleRate), to: clipURL)
			let result = try runDetection(inputPath: clipURL.path)
			let topClass = result.topClass ?? "-"
			let action = result.action ?? "-"
			let dispatch = result.action.map { dispatchDecision(for: $0, result: result) }
			let dispatchAllowed = dispatch?.allowed ?? false
			let dispatchReason = dispatch?.reason ?? "-"
			let workflowState = dispatch?.workflowState ?? currentWorkflowState()
			let sessionOrigin = dispatch?.sessionOrigin ?? currentSessionOrigin()
			let positiveDistance = result.positiveDistance.map { String(format: "%.4f", $0) } ?? "-"
			let negativeDistance = result.negativeDistance.map { String(format: "%.4f", $0) } ?? "-"
			let margin = result.margin.map { String(format: "%.4f", $0) } ?? "-"
			let durationMs = result.candidate?.durationMs.map { String(format: "%.1f", $0) } ?? "-"
			let rmsNorm = result.analysis?.rmsNorm.map { String(format: "%.4f", $0) } ?? "-"
			let classScores = result.classScores?.map { key, value in "\(key)=\(String(format: "%.4f", value))" }.sorted().joined(separator: ",") ?? "-"
			let prototypeScores = result.prototypeScores?.map { key, value in "\(key)=\(String(format: "%.4f", value))" }.sorted().joined(separator: ",") ?? "-"
			log(
				"candidate accepted=\(result.accepted) action=\(action) dispatch=\(dispatchAllowed) dispatch_reason=\(dispatchReason) state=\(workflowState) origin=\(sessionOrigin) top=\(topClass) score=\(String(format: "%.4f", result.score)) pos=\(positiveDistance) neg=\(negativeDistance) margin=\(margin) duration_ms=\(durationMs) rms=\(rmsNorm) class_scores=\(classScores) prototype_scores=\(prototypeScores) reasons=\(result.reasons.joined(separator: ","))"
			)
			if result.accepted, let action = result.action, let dispatch {
				guard dispatch.allowed else {
					log("wakeword_suppressed action=\(action) reason=\(dispatch.reason ?? "-") state=\(dispatch.workflowState) origin=\(dispatch.sessionOrigin) score=\(String(format: "%.4f", result.score))")
					return
				}
				lastTriggerAt = Date()
				try runAction(action: action)
				log("wakeword_triggered action=\(action) state=\(dispatch.workflowState) origin=\(dispatch.sessionOrigin) score=\(String(format: "%.4f", result.score))")
			}
		} catch {
			log("candidate_error \(error.localizedDescription)")
		}
		try? FileManager.default.removeItem(at: clipURL)
	}

	private func readStateValue(_ name: String) -> String {
		let path = stateDir.appendingPathComponent(name)
		guard let data = try? Data(contentsOf: path), let value = String(data: data, encoding: .utf8) else {
			return ""
		}
		return value.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func currentWorkflowState() -> String {
		let value = readStateValue("workflow_state")
		return value.isEmpty ? "idle" : value
	}

	private func currentSessionOrigin() -> String {
		let value = readStateValue("session_origin")
		return value.isEmpty ? "manual" : value
	}

	private func wakewordActionsAreArmed() -> Bool {
		let value = readStateValue("wakeword_arm_until")
		guard let deadline = Double(value), deadline > 0 else {
			return true
		}
		return Date().timeIntervalSince1970 >= deadline
	}

	private func rivalCueGap(for action: String, classScores: [String: Double]?) -> Double? {
		guard let classScores else {
			return nil
		}
		let rivalName = action == "toggle" ? "cancel" : action == "cancel" ? "toggle" : nil
		guard let rivalName, let actionScore = classScores[action], let rivalScore = classScores[rivalName] else {
			return nil
		}
		return actionScore - rivalScore
	}

	private func dispatchDecision(for action: String, result: DetectionResult) -> DispatchDecision {
		let workflowState = currentWorkflowState()
		let sessionOrigin = currentSessionOrigin()
		let actionsArmed = wakewordActionsAreArmed()
		if let rivalGap = rivalCueGap(for: action, classScores: result.classScores), rivalGap < thresholds.activeCueGapMin {
			return DispatchDecision(allowed: false, reason: "cue_gap", workflowState: workflowState, sessionOrigin: sessionOrigin)
		}
		switch action {
		case "cancel":
			if workflowState == "idle" {
				return DispatchDecision(allowed: false, reason: "idle_action", workflowState: workflowState, sessionOrigin: sessionOrigin)
			}
			if workflowState == "dictation_active" && !actionsArmed {
				return DispatchDecision(allowed: false, reason: "arm_window", workflowState: workflowState, sessionOrigin: sessionOrigin)
			}
			return DispatchDecision(allowed: true, reason: nil, workflowState: workflowState, sessionOrigin: sessionOrigin)
		case "toggle":
			if workflowState == "dictation_active" && !actionsArmed {
				return DispatchDecision(allowed: false, reason: "arm_window", workflowState: workflowState, sessionOrigin: sessionOrigin)
			}
			if workflowState == "idle" {
				let toggleScore = result.classScores?["toggle"] ?? result.score
				let prototypeScore = result.prototypeScores?["toggle"] ?? toggleScore
				if toggleScore < thresholds.idleToggleScoreThreshold {
					return DispatchDecision(allowed: false, reason: "idle_score", workflowState: workflowState, sessionOrigin: sessionOrigin)
				}
				if prototypeScore < thresholds.idleTogglePrototypeThreshold {
					return DispatchDecision(allowed: false, reason: "idle_prototype", workflowState: workflowState, sessionOrigin: sessionOrigin)
				}
				if let rivalGap = rivalCueGap(for: action, classScores: result.classScores), rivalGap < thresholds.idleToggleRivalGapMin {
					return DispatchDecision(allowed: false, reason: "idle_cue_gap", workflowState: workflowState, sessionOrigin: sessionOrigin)
				}
				if (result.margin ?? 0.0) < 0.45 {
					return DispatchDecision(allowed: false, reason: "idle_margin", workflowState: workflowState, sessionOrigin: sessionOrigin)
				}
			}
			return DispatchDecision(allowed: true, reason: nil, workflowState: workflowState, sessionOrigin: sessionOrigin)
		default:
			return DispatchDecision(allowed: true, reason: nil, workflowState: workflowState, sessionOrigin: sessionOrigin)
		}
	}

	private func runDetection(inputPath: String) throws -> DetectionResult {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: options.pythonPath)
		process.arguments = [options.toolsPath, "detect", "--model", options.modelPath, "--input", inputPath]
		let stdout = Pipe()
		let stderr = Pipe()
		process.standardOutput = stdout
		process.standardError = stderr
		try process.run()
		process.waitUntilExit()
		let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
		let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
		guard process.terminationStatus == 0 else {
			throw NSError(
				domain: "WakewordListener",
				code: Int(process.terminationStatus),
				userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "wakeword detect failed" : errorText]
			)
		}
		let data = Data(output.utf8)
		let decoded = try JSONDecoder().decode(DetectionResult.self, from: data)
		return decoded
	}

	private func runAction(action: String) throws {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: options.actionScriptPath)
		process.arguments = ["wakeword-\(action)"]
		try process.run()
		process.waitUntilExit()
		if process.terminationStatus != 0 {
			throw NSError(domain: "WakewordListener", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "wakeword action failed"])
		}
	}

	private func writeWave(samples: [Float], sampleRate: Int, to url: URL) throws {
		var int16Samples = Data(capacity: samples.count * MemoryLayout<Int16>.size)
		for sample in samples {
			let clamped = max(-1.0, min(1.0, sample))
			var value = Int16(clamped * 32767.0)
			int16Samples.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
		}

		let byteRate = sampleRate * 2
		let blockAlign: UInt16 = 2
		let subchunk2Size = UInt32(int16Samples.count)
		let chunkSize = UInt32(36) + subchunk2Size

		var data = Data()
		data.append("RIFF".data(using: .ascii)!)
		data.append(littleEndian(chunkSize))
		data.append("WAVE".data(using: .ascii)!)
		data.append("fmt ".data(using: .ascii)!)
		data.append(littleEndian(UInt32(16)))
		data.append(littleEndian(UInt16(1)))
		data.append(littleEndian(UInt16(1)))
		data.append(littleEndian(UInt32(sampleRate)))
		data.append(littleEndian(UInt32(byteRate)))
		data.append(littleEndian(blockAlign))
		data.append(littleEndian(UInt16(16)))
		data.append("data".data(using: .ascii)!)
		data.append(littleEndian(subchunk2Size))
		data.append(int16Samples)
		try data.write(to: url, options: .atomic)
	}

	private func littleEndian<T>(_ value: T) -> Data where T: FixedWidthInteger {
		var copy = value.littleEndian
		return Data(bytes: &copy, count: MemoryLayout<T>.size)
	}

	private func chunkRms(_ samples: [Float]) -> Double {
		guard !samples.isEmpty else {
			return 0.0
		}
		let squareMean = samples.reduce(0.0) { partial, sample in
			partial + Double(sample * sample)
		} / Double(samples.count)
		return sqrt(squareMean)
	}

	private func log(_ message: String) {
		logQueue.async {
			let formatter = ISO8601DateFormatter()
			let line = "\(formatter.string(from: Date())) \(message)\n"
			let data = Data(line.utf8)
			if !FileManager.default.fileExists(atPath: self.options.logPath) {
				FileManager.default.createFile(atPath: self.options.logPath, contents: nil)
			}
			if let handle = FileHandle(forWritingAtPath: self.options.logPath) {
				_ = try? handle.seekToEnd()
				try? handle.write(contentsOf: data)
				try? handle.close()
			}
		}
	}

	private func shutdown() {
		engine.inputNode.removeTap(onBus: 0)
		engine.stop()
		log("listener_stopped")
		exit(0)
	}
}

struct DetectionResult: Decodable {
	let accepted: Bool
	let action: String?
	let analysis: DetectionAnalysis?
	let candidate: DetectionCandidate?
	let classScores: [String: Double]?
	let margin: Double?
	let negativeDistance: Double?
	let positiveDistance: Double?
	let prototypeScores: [String: Double]?
	let reasons: [String]
	let score: Double
	let topClass: String?

	enum CodingKeys: String, CodingKey {
		case accepted
		case action
		case analysis
		case candidate
		case classScores = "class_scores"
		case margin
		case negativeDistance = "negative_distance"
		case positiveDistance = "positive_distance"
		case prototypeScores = "prototype_scores"
		case reasons
		case score
		case topClass = "top_class"
	}
}

struct DispatchDecision {
	let allowed: Bool
	let reason: String?
	let workflowState: String
	let sessionOrigin: String
}

struct DetectionAnalysis: Decodable {
	let rmsNorm: Double?

	enum CodingKeys: String, CodingKey {
		case rmsNorm = "rms_norm"
	}
}

struct DetectionCandidate: Decodable {
	let durationMs: Double?

	enum CodingKeys: String, CodingKey {
		case durationMs = "duration_ms"
	}
}

do {
	let options = try parseListenerArguments()
	let listener = try WakewordListener(options: options)
	listener.run()
} catch {
	fputs("\(error)\n", stderr)
	exit(1)
}
