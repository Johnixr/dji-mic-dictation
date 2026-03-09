import AppKit
import AVFoundation
import Foundation

struct RecorderOptions {
	let outputPath: String
	let title: String
	let prompt: String
	let meta: String
	let detail: String
	let mode: String
	let language: String
	let durationMs: Int
	let countdownMs: Int
	let sampleRate: Double
}

enum ArgumentError: Error {
	case missingValue(String)
	case unknownArgument(String)
}

func parseArguments() throws -> RecorderOptions {
	var values: [String: String] = [:]
	var iterator = CommandLine.arguments.dropFirst().makeIterator()
	while let argument = iterator.next() {
		guard argument.hasPrefix("--") else {
			throw ArgumentError.unknownArgument(argument)
		}
		guard let value = iterator.next() else {
			throw ArgumentError.missingValue(argument)
		}
		values[String(argument.dropFirst(2))] = value
	}

	guard
		let outputPath = values["output"],
		let title = values["title"],
		let prompt = values["prompt"],
		let meta = values["meta"],
		let detail = values["detail"],
		let mode = values["mode"],
		let language = values["language"],
		let durationMs = values["duration-ms"].flatMap(Int.init),
		let countdownMs = values["countdown-ms"].flatMap(Int.init),
		let sampleRate = values["sample-rate"].flatMap(Double.init)
	else {
		throw ArgumentError.missingValue("required arguments")
	}

	return RecorderOptions(
		outputPath: outputPath,
		title: title,
		prompt: prompt,
		meta: meta,
		detail: detail,
		mode: mode,
		language: language,
		durationMs: durationMs,
		countdownMs: countdownMs,
		sampleRate: sampleRate
	)
}

final class RecorderPanel: NSPanel {
	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { true }
}

enum RecorderPhase {
	case waiting
	case recording
	case saving
}

final class RecorderWindowController: NSWindowController {
	private let options: RecorderOptions
	private let rootView = NSView()
	private let badgeView = NSView()
	private let badgeLabel = NSTextField(labelWithString: "")
	private let metaView = NSView()
	private let metaLabel = NSTextField(labelWithString: "")
	private let promptLabel = NSTextField(labelWithString: "")
	private let instructionLabel = NSTextField(labelWithString: "")
	private let statusLabel = NSTextField(labelWithString: "")
	private let timerLabel = NSTextField(labelWithString: "")
	private let footerLabel = NSTextField(labelWithString: "")
	private let progressTrackView = NSView()
	private let progressFillView = NSView()
	private let keyHintView = NSView()
	private let keyHintLabel = NSTextField(labelWithString: "")
	private var recorder: AVAudioRecorder?
	private var timer: Timer?
	private var recordingStartDate: Date?
	private var hasDetectedSpeech = false
	private var phase: RecorderPhase = .waiting
	private var keyMonitor: Any?

	init(options: RecorderOptions) {
		self.options = options

		let window = RecorderPanel(
			contentRect: NSRect(x: 0, y: 0, width: 500, height: 284),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.level = .statusBar
		window.isOpaque = false
		window.backgroundColor = .clear
		window.hasShadow = true
		window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
		window.hidesOnDeactivate = false

		super.init(window: window)
		setupWindow()
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	deinit {
		if let keyMonitor {
			NSEvent.removeMonitor(keyMonitor)
		}
	}

	private var isAmbientPrompt: Bool {
		options.mode == "ambient"
	}

	private var isSpeechDecoyPrompt: Bool {
		options.mode == "speech-decoy"
	}

	private var isMouthDecoyPrompt: Bool {
		options.mode == "mouth-decoy"
	}

	private var isChineseUi: Bool {
		options.language.lowercased().hasPrefix("zh")
	}

	private func localized(_ english: String, _ chinese: String) -> String {
		isChineseUi ? chinese : english
	}

	private func configureWrappingLabel(_ label: NSTextField) {
		label.isBezeled = false
		label.isEditable = false
		label.isSelectable = false
		label.drawsBackground = false
		label.maximumNumberOfLines = 0
		label.lineBreakMode = .byWordWrapping
		label.cell?.wraps = true
		label.cell?.isScrollable = false
		label.cell?.usesSingleLineMode = false
	}

	private func promptFont() -> NSFont {
		let length = options.prompt.count
		if isChineseUi {
			if length > 12 {
				return NSFont.systemFont(ofSize: 26, weight: .bold)
			}
			if length > 8 {
				return NSFont.systemFont(ofSize: 30, weight: .bold)
			}
			return NSFont.systemFont(ofSize: 34, weight: .bold)
		}
		if length > 24 {
			return NSFont.systemFont(ofSize: 22, weight: .bold)
		}
		if length > 14 {
			return NSFont.systemFont(ofSize: 27, weight: .bold)
		}
		return NSFont.systemFont(ofSize: 32, weight: .bold)
	}

	private func setupWindow() {
		guard let window else {
			return
		}

		rootView.frame = window.contentView!.bounds
		rootView.wantsLayer = true
		rootView.layer?.backgroundColor = NSColor(red: 0.09, green: 0.08, blue: 0.07, alpha: 1.0).cgColor
		rootView.layer?.cornerRadius = 24
		rootView.layer?.borderWidth = 1
		rootView.layer?.borderColor = NSColor(red: 0.95, green: 0.68, blue: 0.32, alpha: 0.24).cgColor
		window.contentView = rootView

		badgeLabel.stringValue = isChineseUi ? options.title : options.title.uppercased()
		configureCapsule(
			badgeView,
			label: badgeLabel,
			frame: NSRect(x: 24, y: 228, width: 168, height: 30),
			backgroundColor: NSColor(red: 0.96, green: 0.67, blue: 0.30, alpha: 0.16),
			textColor: NSColor(red: 0.98, green: 0.88, blue: 0.72, alpha: 0.96),
			font: NSFont.systemFont(ofSize: 11, weight: .semibold)
		)
		rootView.addSubview(badgeView)

		metaLabel.stringValue = options.meta
		configureCapsule(
			metaView,
			label: metaLabel,
			frame: NSRect(x: 396, y: 228, width: 80, height: 30),
			backgroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.06),
			textColor: NSColor(calibratedWhite: 1.0, alpha: 0.66),
			font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
		)
		rootView.addSubview(metaView)

		promptLabel.stringValue = options.prompt
		configureWrappingLabel(promptLabel)
		promptLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.95)
		promptLabel.font = promptFont()
		promptLabel.frame = NSRect(x: 24, y: 142, width: 452, height: 66)
		rootView.addSubview(promptLabel)

		instructionLabel.stringValue = options.detail
		configureWrappingLabel(instructionLabel)
		instructionLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.70)
		instructionLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
		instructionLabel.frame = NSRect(x: 24, y: 102, width: 452, height: 34)
		rootView.addSubview(instructionLabel)

		statusLabel.stringValue = localized("Press Space", "按空格开始")
		statusLabel.textColor = NSColor(red: 0.98, green: 0.88, blue: 0.72, alpha: 0.96)
		statusLabel.font = NSFont.systemFont(ofSize: 24, weight: .bold)
		statusLabel.frame = NSRect(x: 24, y: 62, width: 250, height: 30)
		rootView.addSubview(statusLabel)

		timerLabel.stringValue = localized("Ready", "准备好")
		timerLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.52)
		timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
		timerLabel.alignment = .right
		timerLabel.frame = NSRect(x: 318, y: 68, width: 158, height: 18)
		rootView.addSubview(timerLabel)

		progressTrackView.frame = NSRect(x: 24, y: 42, width: 452, height: 16)
		progressTrackView.wantsLayer = true
		progressTrackView.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.14).cgColor
		progressTrackView.layer?.cornerRadius = 8
		rootView.addSubview(progressTrackView)

		progressFillView.frame = NSRect(x: 0, y: 0, width: 0, height: 16)
		progressFillView.wantsLayer = true
		progressFillView.layer?.backgroundColor = NSColor(red: 0.96, green: 0.67, blue: 0.30, alpha: 1.0).cgColor
		progressFillView.layer?.cornerRadius = 8
		progressTrackView.addSubview(progressFillView)

		keyHintLabel.stringValue = localized("SPACE START / STOP", "空格 开始 / 结束")
		configureCapsule(
			keyHintView,
			label: keyHintLabel,
			frame: NSRect(x: 24, y: 12, width: 164, height: 24),
			backgroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.08),
			textColor: NSColor(calibratedWhite: 1.0, alpha: 0.66),
			font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
		)
		rootView.addSubview(keyHintView)

		footerLabel.stringValue = readyFooterMessage()
		configureWrappingLabel(footerLabel)
		footerLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.46)
		footerLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
		footerLabel.frame = NSRect(x: 198, y: 10, width: 278, height: 28)
		rootView.addSubview(footerLabel)
	}

	private func configureCapsule(
		_ capsuleView: NSView,
		label: NSTextField,
		frame: NSRect,
		backgroundColor: NSColor,
		textColor: NSColor,
		font: NSFont
	) {
		capsuleView.frame = frame
		capsuleView.wantsLayer = true
		capsuleView.layer?.backgroundColor = backgroundColor.cgColor
		capsuleView.layer?.cornerRadius = frame.height / 2

		label.removeFromSuperview()
		label.translatesAutoresizingMaskIntoConstraints = false
		label.textColor = textColor
		label.font = font
		label.alignment = .center
		label.lineBreakMode = .byClipping

		capsuleView.addSubview(label)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: capsuleView.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: capsuleView.centerYAnchor),
			label.leadingAnchor.constraint(greaterThanOrEqualTo: capsuleView.leadingAnchor, constant: 12),
			label.trailingAnchor.constraint(lessThanOrEqualTo: capsuleView.trailingAnchor, constant: -12),
		])
	}

	private func updateProgress(_ fraction: Double) {
		let clamped = max(0.0, min(1.0, fraction))
		let width = progressTrackView.bounds.width * CGFloat(clamped)
		progressFillView.frame = NSRect(x: 0, y: 0, width: width, height: progressTrackView.bounds.height)
	}

	private func normalizedInputLevel() -> Double {
		guard let recorder else {
			return 0
		}
		recorder.updateMeters()
		let averagePower = recorder.averagePower(forChannel: 0)
		if averagePower <= -60 {
			return 0
		}
		return Double(pow(10, averagePower / 35.0))
	}

	func presentAndBegin() {
		guard let window else {
			return
		}

		let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
		window.setFrameOrigin(
			NSPoint(
				x: visibleFrame.origin.x + round((visibleFrame.width - window.frame.width) / 2),
				y: visibleFrame.origin.y + 84
			)
		)
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		requestMicrophoneAccess()
	}

	private func requestMicrophoneAccess() {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .authorized:
			armForManualRecording()
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { granted in
				DispatchQueue.main.async {
					if granted {
						self.armForManualRecording()
					} else {
						self.fail(message: self.localized("Microphone permission was denied.", "麦克风权限被拒绝。"))
					}
				}
			}
		default:
			fail(message: localized("Microphone permission is required for wake-cue enrollment.", "录制提示音需要麦克风权限。"))
		}
	}

	private func armForManualRecording() {
		installKeyMonitor()
		phase = .waiting
		statusLabel.stringValue = localized("Press Space", "按空格开始")
		statusLabel.textColor = NSColor(red: 0.98, green: 0.88, blue: 0.72, alpha: 0.96)
		timerLabel.stringValue = localized("Ready", "准备好")
		footerLabel.stringValue = readyFooterMessage()
		updateProgress(0)
		progressFillView.layer?.backgroundColor = NSColor(red: 0.96, green: 0.67, blue: 0.30, alpha: 1.0).cgColor
	}

	private func installKeyMonitor() {
		guard keyMonitor == nil else {
			return
		}
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
			guard let self else {
				return event
			}
			if event.keyCode == 49 {
				self.handlePrimaryAction()
				return nil
			}
			return event
		}
	}

	private func handlePrimaryAction() {
		switch phase {
		case .waiting:
			startRecording()
		case .recording:
			stopAndFinish()
		case .saving:
			return
		}
	}

	private func readyFooterMessage() -> String {
		if isAmbientPrompt {
			return localized("Press Space to start room tone. Press Space again when done.", "按空格开始录环境声，结束时再按一次空格。")
		}
		if isSpeechDecoyPrompt {
			return localized("Press Space to start. Say one unrelated sentence. Press Space again to stop.", "按空格开始，说一句无关的话，再按一次空格结束。")
		}
		if isMouthDecoyPrompt {
			return localized(
				"Press Space to start. Make a different mouth sound. Press Space again to stop.",
				"按空格开始，做一个和两个提示音都不同的口腔声，再按一次空格结束。"
			)
		}
		return localized("Press Space to start. Make the cue once. Press Space again to stop.", "按空格开始，只做一次声音，再按一次空格结束。")
	}

	private func recordingFooterMessage() -> String {
		if isAmbientPrompt {
			return localized("Stay quiet, then press Space again.", "保持安静，结束时再按一次空格。")
		}
		if isSpeechDecoyPrompt {
			return localized("Say one unrelated sentence, then press Space again.", "说一句无关的话，结束时再按一次空格。")
		}
		if isMouthDecoyPrompt {
			return localized("Make a different mouth sound, then press Space again.", "做一个不同的口腔声，结束时再按一次空格。")
		}
		return localized("Make the cue once, then press Space again.", "做一次声音，结束时再按一次空格。")
	}

	private func startRecording() {
		let url = URL(fileURLWithPath: options.outputPath)
		try? FileManager.default.removeItem(at: url)
		try? FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true,
			attributes: nil
		)

		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: options.sampleRate,
			AVNumberOfChannelsKey: 1,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsFloatKey: false,
		]

		do {
			recorder = try AVAudioRecorder(url: url, settings: settings)
			recorder?.isMeteringEnabled = true
			recorder?.prepareToRecord()
			recorder?.record()
		} catch {
			fail(message: localized("Failed to start recording: \(error.localizedDescription)", "启动录音失败：\(error.localizedDescription)"))
			return
		}

		phase = .recording
		recordingStartDate = Date()
		hasDetectedSpeech = false
		updateProgress(0)
		statusLabel.stringValue = isAmbientPrompt ? localized("Recording room tone", "正在录环境声") : localized("Recording", "正在录音")
		statusLabel.textColor = NSColor(red: 0.98, green: 0.88, blue: 0.72, alpha: 0.96)
		timerLabel.stringValue = "0.0 / \(String(format: "%.1f", Double(options.durationMs) / 1000.0))s"
		footerLabel.stringValue = recordingFooterMessage()
		progressFillView.layer?.backgroundColor = NSColor(red: 0.96, green: 0.67, blue: 0.30, alpha: 1.0).cgColor
		timer?.invalidate()
		timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
			self?.updateRecordingProgress()
		}
	}

	private func updateRecordingProgress() {
		guard let recordingStartDate else {
			return
		}
		let elapsedMs = Int(Date().timeIntervalSince(recordingStartDate) * 1000.0)
		let level = normalizedInputLevel()
		updateProgress(Double(min(options.durationMs, elapsedMs)) / Double(max(options.durationMs, 1)))
		if !hasDetectedSpeech && !isAmbientPrompt && level > 0.08 {
			hasDetectedSpeech = true
			statusLabel.stringValue = localized("Input detected", "已检测到输入")
			footerLabel.stringValue = localized("Input detected. Press Space again to stop.", "已检测到输入，再按一次空格结束。")
		}
		timerLabel.stringValue = String(format: "%.1f / %.1fs", Double(elapsedMs) / 1000.0, Double(options.durationMs) / 1000.0)
		if elapsedMs >= options.durationMs {
			stopAndFinish()
		}
	}

	private func stopAndFinish() {
		guard phase == .recording else {
			return
		}
		phase = .saving
		timer?.invalidate()
		recorder?.stop()
		recorder = nil
		statusLabel.stringValue = localized("Saved", "已保存")
		statusLabel.textColor = NSColor(red: 0.64, green: 0.89, blue: 0.62, alpha: 0.96)
		timerLabel.stringValue = localized("Saved", "已保存")
		footerLabel.stringValue = localized("Saved. Returning to the terminal...", "样本已保存，正在返回终端...")
		updateProgress(1)
		progressFillView.layer?.backgroundColor = NSColor(red: 0.64, green: 0.89, blue: 0.62, alpha: 1.0).cgColor

		let payload = [
			"duration_ms": Int(Date().timeIntervalSince(recordingStartDate ?? Date()) * 1000.0),
			"ok": true,
			"output_path": options.outputPath,
		] as [String: Any]
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
			if let data = try? JSONSerialization.data(withJSONObject: payload),
				let text = String(data: data, encoding: .utf8)
			{
				print(text)
			}
			NSApp.terminate(nil)
		}
	}

	private func fail(message: String) {
		timer?.invalidate()
		fputs("\(message)\n", stderr)
		exit(1)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	private let options: RecorderOptions
	private var controller: RecorderWindowController?

	init(options: RecorderOptions) {
		self.options = options
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		controller = RecorderWindowController(options: options)
		controller?.presentAndBegin()
	}
}

let options: RecorderOptions
do {
	options = try parseArguments()
} catch {
	fputs("Failed to parse recorder arguments: \(error)\n", stderr)
	exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
