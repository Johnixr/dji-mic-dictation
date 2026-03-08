import os from 'node:os';
import path from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const APP_NAME = 'dji-mic-dictation';
const REPO_ROOT = path.resolve(fileURLToPath(new URL('../..', import.meta.url)));
const PACKAGE_JSON_PATH = path.join(REPO_ROOT, 'package.json');
const SCRIPT_SOURCE_PATH = path.join(REPO_ROOT, 'scripts', 'dictation-enter.sh');
const KARABINER_TEMPLATE_PATH = path.join(REPO_ROOT, 'karabiner', 'dji-mic-mini.json');
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
	const karabinerDir = env.DJI_KARABINER_DIR || path.join(homeDir, '.config', 'karabiner');
	const karabinerScriptsDir = env.DJI_KARABINER_SCRIPTS_DIR || path.join(karabinerDir, 'scripts');

	return {
		env,
		homeDir,
		configDir,
		configFilePath: env.DJI_CONFIG_FILE || path.join(configDir, 'config.env'),
		manifestFilePath: env.DJI_INSTALLER_MANIFEST || path.join(configDir, 'install-state.json'),
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
		packageVersion: getPackageVersion(),
	};
}

export { APP_NAME, DEFAULT_KARABINER_CLI, KARABINER_TEMPLATE_PATH, REPO_ROOT, SCRIPT_SOURCE_PATH };
