import os from 'node:os';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const APP_NAME = 'dji-mic-dictation';
const REPO_ROOT = path.resolve(fileURLToPath(new URL('../..', import.meta.url)));
const PACKAGE_JSON_PATH = path.join(REPO_ROOT, 'package.json');
const SCRIPT_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'dictation-enter.sh');
const KARABINER_TEMPLATE_PATH = path.join(REPO_ROOT, 'karabiner', 'dji-mic-mini.json');
const WAKEWORD_RECORDER_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'wakeword-recorder.swift');
const WAKEWORD_LISTENER_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'wakeword-listener.swift');
const WAKEWORD_TOOLS_SCRIPT_PATH = path.join(REPO_ROOT, 'scripts', 'wakeword_tools.py');
const DEFAULT_KARABINER_CLI = '/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli';

let cachedPackageVersion;

function getPackageVersion() {
	if (!cachedPackageVersion) {
		cachedPackageVersion = JSON.parse(readFileSync(PACKAGE_JSON_PATH, 'utf-8')).version;
	}
	return cachedPackageVersion;
}

export function createRuntime({ env = process.env } = {}) {
	const homeDir = env.DJI_INSTALLER_HOME || os.homedir();
	const configDir = env.DJI_CONFIG_DIR || path.join(homeDir, '.config', APP_NAME);
	const wakewordDir = env.DJI_WAKEWORD_DIR || path.join(configDir, 'wakeword');
	const karabinerDir = env.DJI_KARABINER_DIR || path.join(homeDir, '.config', 'karabiner');
	const karabinerScriptsDir = env.DJI_KARABINER_SCRIPTS_DIR || path.join(karabinerDir, 'scripts');
	const stateDir = env.DJI_STATE_DIR || '/tmp/dji-dictation';

	return {
		env,
		homeDir,
		configDir,
		stateDir,
		configFilePath: env.DJI_CONFIG_FILE || path.join(configDir, 'config.env'),
		manifestFilePath: env.DJI_INSTALLER_MANIFEST || path.join(configDir, 'install-state.json'),
		wakewordDir,
		wakewordConfigPath: env.DJI_WAKEWORD_CONFIG || path.join(wakewordDir, 'config.json'),
		wakewordCalibrationPath: env.DJI_WAKEWORD_CALIBRATION || path.join(wakewordDir, 'calibration.json'),
		wakewordManifestPath: env.DJI_WAKEWORD_MANIFEST || path.join(wakewordDir, 'install-state.json'),
		wakewordSamplesDir: env.DJI_WAKEWORD_SAMPLES_DIR || path.join(wakewordDir, 'samples'),
		wakewordPositiveSamplesDir:
			env.DJI_WAKEWORD_POSITIVE_SAMPLES_DIR || path.join(wakewordDir, 'samples', 'positive'),
		wakewordCancelSamplesDir:
			env.DJI_WAKEWORD_CANCEL_SAMPLES_DIR || path.join(wakewordDir, 'samples', 'cancel'),
		wakewordNegativeSamplesDir:
			env.DJI_WAKEWORD_NEGATIVE_SAMPLES_DIR || path.join(wakewordDir, 'samples', 'negative'),
		wakewordBinDir: env.DJI_WAKEWORD_BIN_DIR || path.join(wakewordDir, 'bin'),
		wakewordRecorderBinaryPath:
			env.DJI_WAKEWORD_RECORDER_BIN || path.join(wakewordDir, 'bin', 'wakeword-recorder'),
		wakewordListenerBinaryPath:
			env.DJI_WAKEWORD_LISTENER_BIN || path.join(wakewordDir, 'bin', 'wakeword-listener'),
		wakewordListenerPidPath: env.DJI_WAKEWORD_LISTENER_PID || path.join(wakewordDir, 'listener.pid'),
		wakewordListenerLogPath: env.DJI_WAKEWORD_LISTENER_LOG || path.join(wakewordDir, 'listener.log'),
		karabinerDir,
		karabinerConfigPath: env.DJI_KARABINER_CONFIG || path.join(karabinerDir, 'karabiner.json'),
		karabinerScriptsDir,
		scriptTargetPath: env.DJI_SCRIPT_TARGET || path.join(karabinerScriptsDir, 'dictation-enter.sh'),
		karabinerCliPath: env.DJI_KARABINER_CLI || DEFAULT_KARABINER_CLI,
		soundDirectoryPath: env.DJI_SOUND_DIR || '/System/Library/Sounds',
		typelessDbPath:
			env.DJI_TYPELESS_DB ||
			path.join(homeDir, 'Library', 'Application Support', 'Typeless', 'typeless.db'),
		repoRoot: REPO_ROOT,
		scriptSourcePath: SCRIPT_SOURCE_PATH,
		karabinerTemplatePath: KARABINER_TEMPLATE_PATH,
		wakewordRecorderSourcePath: env.DJI_WAKEWORD_RECORDER_SOURCE || WAKEWORD_RECORDER_SOURCE_PATH,
		wakewordListenerSourcePath: env.DJI_WAKEWORD_LISTENER_SOURCE || WAKEWORD_LISTENER_SOURCE_PATH,
		wakewordToolsScriptPath: env.DJI_WAKEWORD_TOOLS || WAKEWORD_TOOLS_SCRIPT_PATH,
		packageVersion: getPackageVersion(),
	};
}

export {
	APP_NAME,
	DEFAULT_KARABINER_CLI,
	KARABINER_TEMPLATE_PATH,
	REPO_ROOT,
	SCRIPT_SOURCE_PATH,
	WAKEWORD_LISTENER_SOURCE_PATH,
	WAKEWORD_RECORDER_SOURCE_PATH,
	WAKEWORD_TOOLS_SCRIPT_PATH,
};
