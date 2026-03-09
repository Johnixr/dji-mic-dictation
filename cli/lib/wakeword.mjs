import { execFile as execFileCallback, spawn } from 'node:child_process';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);

const WAKEWORD_CONFIG_VERSION = 1;
const WAKEWORD_MANIFEST_VERSION = 1;
const DEFAULT_SAMPLE_RATE_HZ = 16000;
const DEFAULT_CLIP_DURATION_MS = 1400;
const DEFAULT_COUNTDOWN_MS = 900;
const SUPPORTED_WAKEWORD_UI_LANGUAGES = new Set(['en', 'zh']);

const POSITIVE_CUE_PHASES = Object.freeze([
	{
		id: 'soft',
		count: 4,
	},
	{
		id: 'natural',
		count: 4,
	},
	{
		id: 'noisy',
		count: 4,
	},
]);

const NEGATIVE_PHASES = Object.freeze([
	{
		id: 'speech-decoy',
		role: 'negative',
		count: 3,
	},
	{
		id: 'mouth-decoy',
		role: 'negative',
		count: 3,
	},
	{
		id: 'ambient',
		role: 'negative',
		count: 3,
	},
]);

export const DEFAULT_WAKEWORD_CONFIG = Object.freeze({
	configVersion: WAKEWORD_CONFIG_VERSION,
	phrase: '',
	cancelPhrase: '',
	backendEngine: 'logmel-softmax',
	backendMode: 'local-vocal-cue-v4',
	sampleRateHz: DEFAULT_SAMPLE_RATE_HZ,
	clipDurationMs: DEFAULT_CLIP_DURATION_MS,
	countdownMs: DEFAULT_COUNTDOWN_MS,
	lastSessionId: '',
	lastRecordedAt: '',
	lastTrainedAt: '',
	positiveSampleCount: 0,
	cancelSampleCount: 0,
	negativeSampleCount: 0,
	trainingReady: false,
});

function normalizePositiveInteger(value, fallback) {
	const number = Number(value);
	if (!Number.isFinite(number) || number <= 0) {
		return fallback;
	}
	return Math.round(number);
}

function normalizeWakewordUiLanguage(value) {
	const normalized = String(value || '')
		.trim()
		.toLowerCase();
	if (normalized.startsWith('zh')) {
		return 'zh';
	}
	return 'en';
}

function languageFromLocaleCandidates(candidates = []) {
	for (const candidate of candidates) {
		const language = normalizeWakewordUiLanguage(candidate);
		if (SUPPORTED_WAKEWORD_UI_LANGUAGES.has(language)) {
			return language;
		}
	}
	return 'en';
}

export async function detectWakewordUiLanguage(runtime) {
	if (runtime._wakewordUiLanguage) {
		return runtime._wakewordUiLanguage;
	}

	const envCandidates = [
		runtime.env.DJI_WAKEWORD_UI_LANGUAGE,
		runtime.env.LC_ALL,
		runtime.env.LC_MESSAGES,
		runtime.env.LANG,
	]
		.filter(Boolean)
		.map((value) => String(value).replace(/[.].*$/u, ''));

	if (envCandidates.length > 0) {
		runtime._wakewordUiLanguage = languageFromLocaleCandidates(envCandidates);
		return runtime._wakewordUiLanguage;
	}

	try {
		const { stdout } = await execFile('/usr/bin/defaults', ['read', '-g', 'AppleLanguages']);
		const matches = stdout.match(/[A-Za-z-]+/gu) || [];
		runtime._wakewordUiLanguage = languageFromLocaleCandidates(matches);
		return runtime._wakewordUiLanguage;
	} catch {
		runtime._wakewordUiLanguage = 'en';
		return runtime._wakewordUiLanguage;
	}
}

function isChineseUi(language) {
	return normalizeWakewordUiLanguage(language) === 'zh';
}

function localizePhaseLabel(phase, language) {
	const zh = isChineseUi(language);
	if (phase.role === 'toggle') {
		if (phase.id === 'soft') {
			return zh ? '轻声提示音' : 'Quiet cue';
		}
		if (phase.id === 'natural') {
			return zh ? '干净提示音' : 'Clean cue';
		}
		if (phase.id === 'noisy') {
			return zh ? '噪声提示音' : 'Noisy cue';
		}
	}
	if (phase.role === 'cancel') {
		if (phase.id === 'cancel-soft') {
			return zh ? '轻声取消音' : 'Quiet cancel';
		}
		if (phase.id === 'cancel-natural') {
			return zh ? '干净取消音' : 'Clean cancel';
		}
		if (phase.id === 'cancel-noisy') {
			return zh ? '噪声取消音' : 'Noisy cancel';
		}
	}
	if (phase.id === 'speech-decoy') {
		return zh ? '无关说话声' : 'Speech decoy';
	}
	if (phase.id === 'mouth-decoy') {
		return zh ? '其他口腔声' : 'Other mouth sound';
	}
	return zh ? '环境静音' : 'Ambient';
}

function localizePhaseInstructions(phase, language) {
	const zh = isChineseUi(language);
	if (phase.role === 'toggle') {
		if (phase.id === 'soft') {
			return zh ? '用安静办公音量做一次主提示音。' : 'Use a quiet office volume and make the main cue once.';
		}
		if (phase.id === 'natural') {
			return zh ? '用正常近讲音量做一次主提示音。' : 'Use your normal near-mic volume and make the main cue once.';
		}
		return zh ? '带正常房间噪声做一次主提示音。' : 'Make the main cue once with normal room noise in the background.';
	}
	if (phase.role === 'cancel') {
		if (phase.id === 'cancel-soft') {
			return zh ? '用安静办公音量做一次取消提示音。' : 'Use a quiet office volume and make the cancel cue once.';
		}
		if (phase.id === 'cancel-natural') {
			return zh ? '用正常近讲音量做一次取消提示音。' : 'Use your normal near-mic volume and make the cancel cue once.';
		}
		return zh ? '带正常房间噪声做一次取消提示音。' : 'Make the cancel cue once with normal room noise in the background.';
	}
	if (phase.id === 'speech-decoy') {
		return zh ? '共享负样本：说一句和两个提示音都无关的话。' : 'Shared negative: say one short sentence that is unrelated to both cues.';
	}
	if (phase.id === 'mouth-decoy') {
		return zh ? '共享负样本：做一个和两个提示音都不同的口腔声。' : 'Shared negative: make a different mouth sound from both cues.';
	}
	return zh ? '共享负样本：保持安静，只录环境声。' : 'Shared negative: stay quiet and record only room tone.';
}

export function normalizeWakewordPhrase(value) {
	const normalized = String(value || '')
		.trim()
		.replace(/\s+/gu, ' ');
	if (!normalized) {
		throw new Error('Wake cue label is required.');
	}
	if (normalized.length > 80) {
		throw new Error('Wake cue label is too long.');
	}
	return normalized;
}

export function normalizeWakewordConfig(config = {}) {
	return {
		configVersion: WAKEWORD_CONFIG_VERSION,
		phrase: config.phrase ? normalizeWakewordPhrase(config.phrase) : '',
		cancelPhrase: config.cancelPhrase ? normalizeWakewordPhrase(config.cancelPhrase) : '',
		backendEngine: config.backendEngine && config.backendEngine !== 'personal-template' ? config.backendEngine : DEFAULT_WAKEWORD_CONFIG.backendEngine,
		backendMode: config.backendMode && config.backendMode !== 'local-vocal-cue-v3' ? config.backendMode : DEFAULT_WAKEWORD_CONFIG.backendMode,
		sampleRateHz: normalizePositiveInteger(config.sampleRateHz, DEFAULT_WAKEWORD_CONFIG.sampleRateHz),
		clipDurationMs: normalizePositiveInteger(config.clipDurationMs, DEFAULT_WAKEWORD_CONFIG.clipDurationMs),
		countdownMs: normalizePositiveInteger(config.countdownMs, DEFAULT_WAKEWORD_CONFIG.countdownMs),
		lastSessionId: String(config.lastSessionId || ''),
		lastRecordedAt: String(config.lastRecordedAt || ''),
		lastTrainedAt: String(config.lastTrainedAt || ''),
		positiveSampleCount: normalizePositiveInteger(config.positiveSampleCount, 0),
		cancelSampleCount: normalizePositiveInteger(config.cancelSampleCount, 0),
		negativeSampleCount: normalizePositiveInteger(config.negativeSampleCount, 0),
		trainingReady: Boolean(config.trainingReady),
	};
}

async function pathExists(filePath) {
	try {
		await fs.access(filePath, fsConstants.F_OK);
		return true;
	} catch {
		return false;
	}
}

async function ensureDirectory(directoryPath) {
	await fs.mkdir(directoryPath, { recursive: true });
}

function sleep(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseJson(text, filePath) {
	try {
		return JSON.parse(text);
	} catch (error) {
		const wrapped = new Error(`Failed to parse JSON from ${filePath}: ${error.message}`);
		wrapped.cause = error;
		throw wrapped;
	}
}

function buildPositiveCuePhase(variant, cueKind, cueLabel) {
	return {
		...variant,
		id: cueKind === 'toggle' ? variant.id : `cancel-${variant.id}`,
		role: cueKind,
		cueKind,
		cueLabel,
	};
}

function sessionPhasePlan({ phrase, cancelPhrase }) {
	const phases = POSITIVE_CUE_PHASES.map((phase) => buildPositiveCuePhase(phase, 'toggle', phrase));
	if (cancelPhrase) {
		phases.push(...POSITIVE_CUE_PHASES.map((phase) => buildPositiveCuePhase(phase, 'cancel', cancelPhrase)));
	}
	return phases.concat(NEGATIVE_PHASES.map((phase) => ({ ...phase })));
}

function getSessionsDir(runtime) {
	return path.join(runtime.wakewordDir, 'sessions');
}

function getRoleDirectory(runtime, role, phaseId) {
	const baseDir =
		role === 'toggle'
			? runtime.wakewordPositiveSamplesDir
			: role === 'cancel'
				? runtime.wakewordCancelSamplesDir
				: runtime.wakewordNegativeSamplesDir;
	return path.join(baseDir, phaseId);
}

function createSessionId() {
	return `${new Date().toISOString().replace(/[-:.TZ]/gu, '').slice(0, 17)}-${Math.random().toString(36).slice(2, 6)}`;
}

async function readJsonIfExists(filePath, fallback) {
	try {
		return parseJson(await fs.readFile(filePath, 'utf-8'), filePath);
	} catch (error) {
		if (error.code === 'ENOENT') {
			return fallback;
		}
		throw error;
	}
}

async function countWaveFiles(directoryPath) {
	try {
		const entries = await fs.readdir(directoryPath, { withFileTypes: true });
		let count = 0;
		for (const entry of entries) {
			const childPath = path.join(directoryPath, entry.name);
			if (entry.isDirectory()) {
				count += await countWaveFiles(childPath);
			} else if (entry.isFile() && entry.name.toLowerCase().endsWith('.wav')) {
				count += 1;
			}
		}
		return count;
	} catch (error) {
		if (error.code === 'ENOENT') {
			return 0;
		}
		throw error;
	}
}

async function ensureSwiftBinary(runtime, { envPath, binaryPath, sourcePath, label }) {
	if (envPath) {
		if (!(await pathExists(binaryPath))) {
			throw new Error(`${label} binary not found at ${binaryPath}`);
		}
		return binaryPath;
	}

	await ensureDirectory(runtime.wakewordBinDir);
	const moduleCacheDir = path.join(runtime.wakewordBinDir, 'module-cache');
	await ensureDirectory(moduleCacheDir);

	const [sourceStat, binaryStat] = await Promise.all([
		fs.stat(sourcePath),
		fs.stat(binaryPath).catch((error) => (error.code === 'ENOENT' ? null : Promise.reject(error))),
	]);

	if (binaryStat && binaryStat.mtimeMs >= sourceStat.mtimeMs) {
		return binaryPath;
	}

	await execFile('/usr/bin/swiftc', ['-module-cache-path', moduleCacheDir, sourcePath, '-o', binaryPath]);
	return binaryPath;
}

async function ensureRecorderBinary(runtime) {
	return ensureSwiftBinary(runtime, {
		envPath: runtime.env.DJI_WAKEWORD_RECORDER_BIN,
		binaryPath: runtime.wakewordRecorderBinaryPath,
		sourcePath: runtime.wakewordRecorderSourcePath,
		label: 'Wake-word recorder',
	});
}

async function ensureListenerBinary(runtime) {
	return ensureSwiftBinary(runtime, {
		envPath: runtime.env.DJI_WAKEWORD_LISTENER_BIN,
		binaryPath: runtime.wakewordListenerBinaryPath,
		sourcePath: runtime.wakewordListenerSourcePath,
		label: 'Wake-word listener',
	});
}

async function runRecorderClip(runtime, options) {
	const recorderPath = await ensureRecorderBinary(runtime);
	const args = [
		'--output',
		options.outputPath,
		'--title',
		options.title,
		'--prompt',
		options.prompt,
		'--meta',
		options.meta,
		'--detail',
		options.detail,
		'--mode',
		options.mode,
		'--language',
		options.language,
		'--duration-ms',
		String(options.durationMs),
		'--countdown-ms',
		String(options.countdownMs),
		'--sample-rate',
		String(options.sampleRateHz),
	];
	const { stdout } = await execFile(recorderPath, args, { env: runtime.env });
	const line = stdout
		.trim()
		.split(/\r?\n/u)
		.filter(Boolean)
		.at(-1);
	if (!line) {
		throw new Error('Wake-word recorder returned no output.');
	}
	return parseJson(line, 'wakeword-recorder stdout');
}

async function analyzeClip(runtime, filePath) {
	const { stdout } = await execFile(
		'python3',
		[runtime.wakewordToolsScriptPath, 'analyze', '--input', filePath],
		{ env: runtime.env },
	);
	return parseJson(stdout, runtime.wakewordToolsScriptPath);
}

function evaluateClipAnalysis(phase, analysis) {
	const isSoftPhase = phase.id === 'soft' || phase.id.endsWith('-soft');
	const isAmbientPhase = phase.id === 'ambient';
	const isSpeechDecoyPhase = phase.id === 'speech-decoy';
	const isMouthDecoyPhase = phase.id === 'mouth-decoy';
	const isCancelCuePhase = phase.role === 'cancel';
	const isPositivePhase =
		phase.role != null ? ['toggle', 'cancel', 'positive'].includes(phase.role) : !isAmbientPhase && !isSpeechDecoyPhase && !isMouthDecoyPhase;
	const minimumDurationMs = isPositivePhase
		? isSoftPhase
			? 250
			: isCancelCuePhase
				? 240
				: 300
		: isSpeechDecoyPhase
			? 350
			: isMouthDecoyPhase
				? 180
				: 0;
	const maximumDurationMs = isPositivePhase ? 1800 : isSpeechDecoyPhase ? 2400 : isMouthDecoyPhase ? 1600 : 0;
	const minimumRmsNorm = isPositivePhase
		? isSoftPhase
			? 0.0028
			: isCancelCuePhase
				? 0.0036
				: 0.0045
		: isSpeechDecoyPhase
			? 0.0045
			: isMouthDecoyPhase
				? 0.003
				: 0;
	const minimumActiveRatio = isPositivePhase
		? isSoftPhase
			? 0.025
			: isCancelCuePhase
				? 0.04
				: 0.06
		: isSpeechDecoyPhase
			? 0.05
			: isMouthDecoyPhase
				? 0.025
				: 0;
	const minimumPeakNorm = isPositivePhase && isSoftPhase ? 0.008 : isCancelCuePhase ? 0.0065 : 0;

	if (analysis.sample_rate_hz !== DEFAULT_SAMPLE_RATE_HZ) {
		return { accepted: false, reason: `Unexpected sample rate: ${analysis.sample_rate_hz}Hz` };
	}

	if ((analysis.clipped_ratio || 0) > 0.01) {
		return { accepted: false, reason: 'Audio clipped. Make the cue a little softer or move slightly farther away.' };
	}

	if (isAmbientPhase) {
		if ((analysis.rms_norm || 0) > 0.012 || (analysis.active_ratio || 0) > 0.16 || (analysis.peak_norm || 0) > 0.12) {
			return { accepted: false, reason: 'Ambient clip had too much voice or mouth noise. Stay quiet for this take.' };
		}
		return { accepted: true, reason: '' };
	}

	if ((analysis.duration_ms || 0) < minimumDurationMs) {
		return {
			accepted: false,
			reason: isPositivePhase
				? 'Clip was too short. Start cleanly, make the full cue, then stop.'
				: 'Clip was too short. Give one clean decoy take before stopping.',
		};
	}

	if (maximumDurationMs > 0 && (analysis.duration_ms || 0) > maximumDurationMs) {
		return {
			accepted: false,
			reason: isPositivePhase ? 'Clip was too long. Keep the cue short and consistent.' : 'Clip was too long. Keep the decoy short.',
		};
	}

	if ((analysis.rms_norm || 0) < minimumRmsNorm) {
		return {
			accepted: false,
			reason: isSoftPhase
				? 'Quiet-cue sample was still too quiet. Move slightly closer or raise it by one notch.'
				: isPositivePhase
					? 'Audio was too quiet. Make the cue a little closer to the mic.'
					: 'Audio was too quiet. Give a clearer decoy take.',
		};
	}

	if ((analysis.active_ratio || 0) < minimumActiveRatio) {
		return {
			accepted: false,
			reason: isSoftPhase
				? 'Quiet-cue sample was too faint. Start again and make the cue once.'
				: isPositivePhase
					? 'The clip was mostly silence. Try again with one clean cue take.'
					: 'The clip was mostly silence. Try again with one clean decoy take.',
		};
	}

	if (minimumPeakNorm > 0 && (analysis.peak_norm || 0) < minimumPeakNorm) {
		return {
			accepted: false,
			reason: 'Quiet-cue sample did not carry enough signal energy. Move a little closer to the mic.',
		};
	}

	return { accepted: true, reason: '' };
}

export const __testOnly = {
	evaluateClipAnalysis,
};

function createPromptForPhase(phase, phrase, language) {
	const zh = isChineseUi(language);
	if (phase.role === 'toggle' || phase.role === 'cancel' || phase.role === 'positive') {
		return phase.cueLabel || phrase;
	}
	if (phase.id === 'speech-decoy') {
		return zh ? '说一句别的话' : 'Say a short sentence';
	}
	if (phase.id === 'mouth-decoy') {
		return zh ? '做一个别的口腔声' : 'Make a different mouth sound';
	}
	return zh ? '保持安静' : 'Stay quiet';
}

function createDetailForPhase(phase, language) {
	const zh = isChineseUi(language);
	if (phase.role === 'toggle' || phase.role === 'cancel' || phase.role === 'positive') {
		return zh ? '按空格开始，只做一次声音，再按空格结束。' : 'Press Space to start. Make the cue once. Press Space again to stop.';
	}
	if (phase.id === 'speech-decoy') {
		return zh
			? '共享负样本。按空格开始，说一句无关的话，再按空格结束。'
			: 'Shared negative. Press Space to start, say one unrelated sentence, then press Space again.';
	}
	if (phase.id === 'mouth-decoy') {
		return zh
			? '共享负样本。按空格开始，做一个和两个提示音都不同的口腔声，再按空格结束。'
			: 'Shared negative. Press Space to start, make a different mouth sound, then press Space again.';
	}
	return zh ? '共享负样本。按空格开始保持安静，再按空格结束。' : 'Shared negative. Press Space to start, stay quiet, then press Space again.';
}

function createMetaForPhase(phase, clipIndex) {
	return `${clipIndex} / ${phase.count}`;
}

function createTitleForPhase(phase, language) {
	return localizePhaseLabel(phase, language);
}

function createRecorderModeForPhase(phase) {
	if (phase.id === 'ambient') {
		return 'ambient';
	}
	if (phase.id === 'speech-decoy') {
		return 'speech-decoy';
	}
	if (phase.id === 'mouth-decoy') {
		return 'mouth-decoy';
	}
	if (phase.role === 'cancel') {
		return 'cancel';
	}
	return 'cue';
}

function formatPhaseProgressMessage(phase, language, existingCount) {
	const label = localizePhaseLabel(phase, language);
	const instructions = localizePhaseInstructions(phase, language);
	const zh = isChineseUi(language);
	if (existingCount > 0) {
		return `${label}: ${instructions}\n${zh ? `已复用磁盘上 ${existingCount}/${phase.count} 条通过样本。` : `Using ${existingCount}/${phase.count} accepted sample(s) already on disk.`}`;
	}
	return `${label}: ${instructions}`;
}

export function formatWakewordSetupIntro(language, hasCancelCue) {
	const zh = isChineseUi(language);
	if (zh) {
		return [
			hasCancelCue
				? '录音面板会先采集主提示音和取消提示音的轻声 / 干净 / 带噪声正样本，再采集一套共享的无关说话声、其他口腔声和环境静音负样本。'
				: '录音面板会采集主提示音的轻声 / 干净 / 带噪声正样本，再采集一套共享的无关说话声、其他口腔声和环境静音负样本。',
			'无关说话声、其他口腔声和环境静音只录一套，会同时用于主提示音和取消提示音。',
			'按空格开始，再按一次空格结束当前样本。',
		].join('\n');
	}
	return [
		hasCancelCue
			? 'The recorder will capture quiet/clean/noisy positives for both the main cue and the cancel cue, then one shared set of speech, mouth-sound, and ambient negatives.'
			: 'The recorder will capture quiet/clean/noisy positives for the main cue, then one shared set of speech, mouth-sound, and ambient negatives.',
		'Speech, mouth-sound, and ambient negatives are recorded once and reused for both cues.',
		'Press Space to start each take, then press Space again to stop.',
	].join('\n');
}

async function allocateClipPath(runtime, phase, sessionId, clipNumber) {
	const phaseDir = getRoleDirectory(runtime, phase.role, phase.id);
	await ensureDirectory(phaseDir);
	return path.join(phaseDir, `${sessionId}-${String(clipNumber).padStart(2, '0')}.wav`);
}

async function countPhaseWaveFiles(runtime, phase) {
	const phaseDir = getRoleDirectory(runtime, phase.role, phase.id);
	return Math.min(phase.count, await countWaveFiles(phaseDir));
}

function summarizeSessionEntries(entries) {
	const acceptedEntries = entries.filter((entry) => entry.accepted);
	const positiveCount = acceptedEntries.filter((entry) => entry.role === 'toggle' || entry.role === 'positive').length;
	const cancelCount = acceptedEntries.filter((entry) => entry.role === 'cancel').length;
	const negativeCount = acceptedEntries.filter((entry) => entry.role === 'negative').length;
	const rejectedCount = entries.length - acceptedEntries.length;
	return {
		positiveCount,
		cancelCount,
		negativeCount,
		rejectedCount,
		totalCount: entries.length,
	};
}

async function writeWakewordManifest(runtime, manifest) {
	await ensureDirectory(runtime.wakewordDir);
	await fs.writeFile(runtime.wakewordManifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf-8');
}

export async function loadWakewordConfig(runtime) {
	const config = await readJsonIfExists(runtime.wakewordConfigPath, DEFAULT_WAKEWORD_CONFIG);
	return normalizeWakewordConfig(config);
}

export async function writeWakewordConfig(runtime, config) {
	const normalized = normalizeWakewordConfig(config);
	await ensureDirectory(runtime.wakewordDir);
	await fs.writeFile(runtime.wakewordConfigPath, `${JSON.stringify(normalized, null, 2)}\n`, 'utf-8');
	return normalized;
}

async function resolveActionScriptPath(runtime) {
	return (await pathExists(runtime.scriptTargetPath)) ? runtime.scriptTargetPath : runtime.scriptSourcePath;
}

async function resolvePythonExecutable(runtime) {
	const configured = String(runtime.env.PYTHON3_BIN || '').trim();
	if (configured) {
		if (path.isAbsolute(configured)) {
			return configured;
		}
		const { stdout } = await execFile('/usr/bin/env', [
			configured,
			'-c',
			'import os, sys; print(os.path.realpath(sys.executable))',
		]);
		const resolved = stdout.trim();
		if (!resolved) {
			throw new Error(`Failed to resolve Python executable from ${configured}`);
		}
		return resolved;
	}

	const { stdout } = await execFile('/usr/bin/env', [
		'python3',
		'-c',
		'import os, sys; print(os.path.realpath(sys.executable))',
	]);
	const resolved = stdout.trim();
	if (!resolved) {
		throw new Error('Failed to resolve python3 executable.');
	}
	return resolved;
}

async function loadWakewordCalibration(runtime) {
	return readJsonIfExists(runtime.wakewordCalibrationPath, null);
}

async function assertWakewordReadyForListening(runtime) {
	const [config, calibration] = await Promise.all([loadWakewordConfig(runtime), loadWakewordCalibration(runtime)]);
	if (!config.phrase) {
		throw new Error('Wake cue is not configured. Run `wakeword setup` first.');
	}
	if (!calibration?.ready) {
		throw new Error('Wake-word calibration is not ready. Run `wakeword train` after recording more samples.');
	}
	return { calibration, config };
}

async function readListenerPid(runtime) {
	try {
		const raw = (await fs.readFile(runtime.wakewordListenerPidPath, 'utf-8')).trim();
		const pid = Number.parseInt(raw, 10);
		return Number.isFinite(pid) && pid > 0 ? pid : null;
	} catch (error) {
		if (error.code === 'ENOENT') {
			return null;
		}
		throw error;
	}
}

function isProcessRunning(pid) {
	if (!pid) {
		return false;
	}
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

async function waitForProcessExit(pid, timeoutMs = 2000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (!isProcessRunning(pid)) {
			return true;
		}
		await sleep(50);
	}
	return !isProcessRunning(pid);
}

function buildListenerArgs(runtime) {
	return [
		'--model',
		runtime.wakewordCalibrationPath,
		'--python',
		runtime._resolvedWakewordPythonPath,
		'--tools',
		runtime.wakewordToolsScriptPath,
		'--action-script',
		runtime._resolvedWakewordActionScriptPath,
		'--log',
		runtime.wakewordListenerLogPath,
		'--state-dir',
		runtime.stateDir,
	];
}

export async function wakewordListenerStatus(runtime) {
	const pid = await readListenerPid(runtime);
	const running = isProcessRunning(pid);
	if (!running && pid) {
		await fs.rm(runtime.wakewordListenerPidPath, { force: true });
	}
	return {
		logPath: runtime.wakewordListenerLogPath,
		pid: running ? pid : null,
		pidFileExists: await pathExists(runtime.wakewordListenerPidPath),
		running,
	};
}

export async function recordWakewordSamples(runtime, { phrase, cancelPhrase = '', progress = () => {} }) {
	const normalizedPhrase = normalizeWakewordPhrase(phrase);
	const existingConfig = await loadWakewordConfig(runtime);
	const normalizedCancelPhrase = cancelPhrase ? normalizeWakewordPhrase(cancelPhrase) : existingConfig.cancelPhrase || '';
	const planCancelPhrase = cancelPhrase ? normalizedCancelPhrase : '';
	const uiLanguage = await detectWakewordUiLanguage(runtime);
	const sessionId = createSessionId();
	const sessionEntries = [];
	const phasePlan = sessionPhasePlan({ phrase: normalizedPhrase, cancelPhrase: planCancelPhrase });
	const sessionsDir = getSessionsDir(runtime);
	await ensureDirectory(sessionsDir);

	for (const phase of phasePlan) {
		const existingCount = await countPhaseWaveFiles(runtime, phase);
		progress({
			type: 'phase',
			phase,
			phaseLabel: localizePhaseLabel(phase, uiLanguage),
			message: formatPhaseProgressMessage(phase, uiLanguage, existingCount),
		});
		if (existingCount >= phase.count) {
			continue;
		}

		for (let clipIndex = existingCount + 1; clipIndex <= phase.count; clipIndex += 1) {
			let accepted = false;
			let attempt = 0;
			while (!accepted && attempt < 3) {
				attempt += 1;
				const outputPath = await allocateClipPath(runtime, phase, sessionId, clipIndex);
				const detail = `${localizePhaseLabel(phase, uiLanguage)} ${clipIndex}/${phase.count}`;
				progress({
					type: 'clip',
					phase,
					phaseLabel: localizePhaseLabel(phase, uiLanguage),
					clipIndex,
					attempt,
					message: `${detail}${attempt > 1 ? ` (retry ${attempt})` : ''}`,
				});
				await fs.rm(outputPath, { force: true });
				await runRecorderClip(runtime, {
					outputPath,
					title: createTitleForPhase(phase, uiLanguage),
					prompt: createPromptForPhase(phase, normalizedPhrase, uiLanguage),
					meta: createMetaForPhase(phase, clipIndex),
					detail: createDetailForPhase(phase, uiLanguage),
					durationMs: existingConfig.clipDurationMs,
					countdownMs: existingConfig.countdownMs,
					sampleRateHz: existingConfig.sampleRateHz,
					mode: createRecorderModeForPhase(phase),
					language: uiLanguage,
				});
				const analysis = await analyzeClip(runtime, outputPath);
				const verdict = evaluateClipAnalysis(phase, analysis);
				if (!verdict.accepted) {
					await fs.rm(outputPath, { force: true });
					progress({
						type: 'retry',
						phase,
						phaseLabel: localizePhaseLabel(phase, uiLanguage),
						clipIndex,
						attempt,
						message: verdict.reason,
					});
					if (attempt >= 3) {
						throw new Error(`Failed to capture a usable ${localizePhaseLabel(phase, uiLanguage).toLowerCase()} sample: ${verdict.reason}`);
					}
					continue;
				}

				sessionEntries.push({
					analysis,
					accepted: true,
					attempt,
					clipIndex,
					filePath: outputPath,
					phaseId: phase.id,
					phaseLabel: localizePhaseLabel(phase, uiLanguage),
					role: phase.role,
				});
				accepted = true;
			}
		}
	}

	const now = new Date().toISOString();
	const sessionSummary = summarizeSessionEntries(sessionEntries);
	const sessionManifest = {
		sessionId,
		phrase: normalizedPhrase,
		cancelPhrase: normalizedCancelPhrase,
		recordedAt: now,
		entries: sessionEntries,
		summary: sessionSummary,
	};
	await fs.writeFile(
		path.join(sessionsDir, `${sessionId}.json`),
		`${JSON.stringify(sessionManifest, null, 2)}\n`,
		'utf-8',
	);

	const [positiveSampleCount, cancelSampleCount, negativeSampleCount] = await Promise.all([
		countWaveFiles(runtime.wakewordPositiveSamplesDir),
		countWaveFiles(runtime.wakewordCancelSamplesDir),
		countWaveFiles(runtime.wakewordNegativeSamplesDir),
	]);
	const nextConfig = await writeWakewordConfig(runtime, {
		...existingConfig,
		phrase: normalizedPhrase,
		cancelPhrase: normalizedCancelPhrase,
		lastSessionId: sessionId,
		lastRecordedAt: now,
		positiveSampleCount,
		cancelSampleCount,
		negativeSampleCount,
	});
	await writeWakewordManifest(runtime, {
		manifestVersion: WAKEWORD_MANIFEST_VERSION,
		packageVersion: runtime.packageVersion,
		phrase: normalizedPhrase,
		cancelPhrase: normalizedCancelPhrase,
		lastSessionId: sessionId,
		updatedAt: now,
	});

	return {
		config: nextConfig,
		sessionId,
		sessionManifest,
	};
}

export async function trainWakeword(runtime) {
	const config = await loadWakewordConfig(runtime);
	if (!config.phrase) {
		throw new Error('Wake cue is not configured. Run `wakeword setup` or `wakeword record` first.');
	}

	const { stdout } = await execFile(
		'python3',
		[
			runtime.wakewordToolsScriptPath,
			'summarize',
			'--phrase',
			config.phrase,
			'--positive-dir',
			runtime.wakewordPositiveSamplesDir,
			'--cancel-dir',
			runtime.wakewordCancelSamplesDir,
			'--cancel-phrase',
			config.cancelPhrase || '',
			'--negative-dir',
			runtime.wakewordNegativeSamplesDir,
		],
		{ env: runtime.env },
	);
	const summary = parseJson(stdout, runtime.wakewordToolsScriptPath);
	const now = new Date().toISOString();
	await ensureDirectory(runtime.wakewordDir);
	await fs.writeFile(runtime.wakewordCalibrationPath, `${JSON.stringify(summary, null, 2)}\n`, 'utf-8');

	const nextConfig = await writeWakewordConfig(runtime, {
		...config,
		lastTrainedAt: now,
		positiveSampleCount: summary.positive_count,
		cancelSampleCount: summary.cancel_count || 0,
		negativeSampleCount: summary.negative_count,
		trainingReady: Boolean(summary.ready),
	});
	await writeWakewordManifest(runtime, {
		manifestVersion: WAKEWORD_MANIFEST_VERSION,
		packageVersion: runtime.packageVersion,
		phrase: config.phrase,
		cancelPhrase: config.cancelPhrase || '',
		lastSessionId: config.lastSessionId,
		lastTrainedAt: now,
		updatedAt: now,
	});

	return {
		config: nextConfig,
		summary,
	};
}

export async function doctorWakeword(runtime) {
	const [config, calibration, positiveSampleCount, cancelSampleCount, negativeSampleCount, listenerStatus] = await Promise.all([
		loadWakewordConfig(runtime),
		readJsonIfExists(runtime.wakewordCalibrationPath, null),
		countWaveFiles(runtime.wakewordPositiveSamplesDir),
		countWaveFiles(runtime.wakewordCancelSamplesDir),
		countWaveFiles(runtime.wakewordNegativeSamplesDir),
		wakewordListenerStatus(runtime),
	]);

	let nextStep = 'Run `wakeword setup` to capture samples.';
	if (config.phrase && positiveSampleCount + negativeSampleCount > 0) {
		nextStep = 'Run `wakeword train` to refresh calibration.';
	}
	if (calibration?.ready) {
		nextStep = listenerStatus.running ? 'Samples, calibration, and listener look healthy.' : 'Run `wakeword start` to enable hands-free listening.';
	}

	return {
		backendEngine: config.backendEngine,
		backendMode: config.backendMode,
		calibration,
		calibrationExists: await pathExists(runtime.wakewordCalibrationPath),
		configExists: await pathExists(runtime.wakewordConfigPath),
		lastRecordedAt: config.lastRecordedAt || null,
		lastSessionId: config.lastSessionId || null,
		lastTrainedAt: config.lastTrainedAt || null,
		nextStep,
		cancelPhrase: config.cancelPhrase || null,
		cancelSampleCount,
		negativeSampleCount,
		phrase: config.phrase || null,
		positiveSampleCount,
		recorderReady: await pathExists(runtime.wakewordRecorderSourcePath),
		listenerLogPath: runtime.wakewordListenerLogPath,
		listenerReady: await pathExists(runtime.wakewordListenerSourcePath),
		listenerRunning: listenerStatus.running,
		listenerPid: listenerStatus.pid,
		trainingReady: Boolean(config.trainingReady && calibration?.ready),
	};
}

export async function setupWakeword(runtime, { phrase, cancelPhrase = '', progress = () => {} }) {
	const recordResult = await recordWakewordSamples(runtime, { phrase, cancelPhrase, progress });
	const trainResult = await trainWakeword(runtime);
	return {
		record: recordResult,
		train: trainResult,
	};
}

export async function startWakewordListener(runtime) {
	const readiness = await assertWakewordReadyForListening(runtime);
	runtime._resolvedWakewordActionScriptPath = await resolveActionScriptPath(runtime);
	runtime._resolvedWakewordPythonPath = await resolvePythonExecutable(runtime);
	const existingStatus = await wakewordListenerStatus(runtime);
	if (existingStatus.running) {
		return {
			alreadyRunning: true,
			cancelPhrase: readiness.config.cancelPhrase || '',
			pid: existingStatus.pid,
			logPath: existingStatus.logPath,
			phrase: readiness.config.phrase,
		};
	}

	const listenerPath = await ensureListenerBinary(runtime);
	await ensureDirectory(runtime.wakewordDir);
	const stdoutHandle = await fs.open(runtime.wakewordListenerLogPath, 'a');
	const stderrHandle = await fs.open(runtime.wakewordListenerLogPath, 'a');
	const child = spawn(listenerPath, buildListenerArgs(runtime), {
		cwd: runtime.repoRoot,
		detached: true,
		env: runtime.env,
		stdio: ['ignore', stdoutHandle.fd, stderrHandle.fd],
	});
	child.unref();
	await stdoutHandle.close();
	await stderrHandle.close();
	await fs.writeFile(runtime.wakewordListenerPidPath, `${child.pid}\n`, 'utf-8');
	await sleep(300);
	if (!isProcessRunning(child.pid)) {
		const logTail = await fs.readFile(runtime.wakewordListenerLogPath, 'utf-8').catch(() => '');
		throw new Error(`Wake-word listener exited immediately.${logTail ? `\n${logTail.trim()}` : ''}`);
	}
	return {
		alreadyRunning: false,
		cancelPhrase: readiness.config.cancelPhrase || '',
		logPath: runtime.wakewordListenerLogPath,
		pid: child.pid,
		phrase: readiness.config.phrase,
	};
}

export async function stopWakewordListener(runtime) {
	const pid = await readListenerPid(runtime);
	if (!pid || !isProcessRunning(pid)) {
		await fs.rm(runtime.wakewordListenerPidPath, { force: true });
		return { running: false, stopped: false };
	}
	process.kill(pid, 'SIGTERM');
	if (!(await waitForProcessExit(pid))) {
		process.kill(pid, 'SIGKILL');
		await waitForProcessExit(pid, 1000);
	}
	await fs.rm(runtime.wakewordListenerPidPath, { force: true });
	return { running: false, stopped: true, pid };
}

export async function listenWakeword(runtime) {
	const readiness = await assertWakewordReadyForListening(runtime);
	runtime._resolvedWakewordActionScriptPath = await resolveActionScriptPath(runtime);
	runtime._resolvedWakewordPythonPath = await resolvePythonExecutable(runtime);
	const listenerPath = await ensureListenerBinary(runtime);
	await ensureDirectory(runtime.wakewordDir);
	const child = spawn(listenerPath, buildListenerArgs(runtime), {
		cwd: runtime.repoRoot,
		env: runtime.env,
		stdio: 'inherit',
	});
	const exitCode = await new Promise((resolve, reject) => {
		child.on('error', reject);
		child.on('exit', (code) => resolve(code ?? 0));
	});
	if (exitCode !== 0) {
		throw new Error(`Wake-word listener exited with code ${exitCode}`);
	}
	return {
		cancelPhrase: readiness.config.cancelPhrase || '',
		exitCode,
		phrase: readiness.config.phrase,
	};
}
