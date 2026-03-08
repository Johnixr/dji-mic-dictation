import fs from 'node:fs/promises';

export const DEFAULT_CONFIG = Object.freeze({
	audioFeedbackEnabled: true,
	readySoundName: 'Tink',
	preconfirmSoundName: 'Sosumi',
	windowShakeEnabled: true,
});

function parseBoolean(value, fallback) {
	if (value == null || value === '') {
		return fallback;
	}
	const normalized = String(value).trim().toLowerCase();
	if (['1', 'true', 'yes', 'on'].includes(normalized)) {
		return true;
	}
	if (['0', 'false', 'no', 'off'].includes(normalized)) {
		return false;
	}
	return fallback;
}

export function normalizeSoundName(value, fallback = DEFAULT_CONFIG.readySoundName) {
	if (value === undefined || value === null) {
		return fallback;
	}
	const raw = String(value).trim();
	if (raw === '' || /^(off|none)$/iu.test(raw)) {
		return '';
	}
	const normalized = raw.replace(/\.aiff$/iu, '');
	if (!normalized || /[\0\r\n/]/u.test(normalized)) {
		return fallback;
	}
	return normalized;
}

export function normalizeConfig(config = {}) {
	const readySoundName = normalizeSoundName(config.readySoundName, DEFAULT_CONFIG.readySoundName);
	const preconfirmSoundName = normalizeSoundName(config.preconfirmSoundName, DEFAULT_CONFIG.preconfirmSoundName);
	const derivedAudioFeedbackEnabled = readySoundName !== '' || preconfirmSoundName !== '';
	return {
		audioFeedbackEnabled: parseBoolean(config.audioFeedbackEnabled, derivedAudioFeedbackEnabled),
		readySoundName,
		preconfirmSoundName,
		windowShakeEnabled: parseBoolean(config.windowShakeEnabled, DEFAULT_CONFIG.windowShakeEnabled),
	};
}

function parseEnvFile(text) {
	const result = {};
	for (const rawLine of text.split(/\r?\n/u)) {
		const line = rawLine.trim();
		if (!line || line.startsWith('#')) {
			continue;
		}
		const separatorIndex = line.indexOf('=');
		if (separatorIndex === -1) {
			continue;
		}
		const key = line.slice(0, separatorIndex).trim();
		let value = line.slice(separatorIndex + 1).trim();
		if (
			(value.startsWith('"') && value.endsWith('"')) ||
			(value.startsWith("'") && value.endsWith("'"))
		) {
			value = value.slice(1, -1);
		}
		result[key] = value;
	}
	return result;
}

function serializeEnvValue(value) {
	return value ? '1' : '0';
}

function serializeEnvString(value) {
	return `'${String(value).replace(/'/gu, `'"'"'`)}'`;
}

export async function loadConfig(runtime) {
	try {
		const raw = await fs.readFile(runtime.configFilePath, 'utf-8');
		const env = parseEnvFile(raw);
		return normalizeConfig({
			audioFeedbackEnabled: env.DJI_ENABLE_AUDIO_FEEDBACK,
			readySoundName: env.DJI_READY_SOUND_NAME,
			preconfirmSoundName: env.DJI_PRECONFIRM_SOUND_NAME,
			windowShakeEnabled: env.DJI_ENABLE_WINDOW_SHAKE,
		});
	} catch (error) {
		if (error.code === 'ENOENT') {
			return { ...DEFAULT_CONFIG };
		}
		throw error;
	}
}

export async function writeConfig(runtime, config) {
	const normalized = normalizeConfig(config);
	await fs.mkdir(runtime.configDir, { recursive: true });
	const content = [
		'# Managed by dji-mic-dictation CLI',
		`DJI_ENABLE_AUDIO_FEEDBACK=${serializeEnvValue(normalized.audioFeedbackEnabled)}`,
		`DJI_READY_SOUND_NAME=${serializeEnvString(normalized.readySoundName)}`,
		`DJI_PRECONFIRM_SOUND_NAME=${serializeEnvString(normalized.preconfirmSoundName)}`,
		`DJI_ENABLE_WINDOW_SHAKE=${serializeEnvValue(normalized.windowShakeEnabled)}`,
		'',
	].join('\n');
	await fs.writeFile(runtime.configFilePath, content, 'utf-8');
	return normalized;
}
