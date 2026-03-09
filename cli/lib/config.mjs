import fs from 'node:fs/promises';

export const DEFAULT_CONFIG = Object.freeze({
	audioFeedbackEnabled: true,
	preconfirmSoundName: 'Sosumi',
	readyOverlayEnabled: true,
	reviewWindowSeconds: 3,
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

function parsePositiveNumber(value, fallback) {
	if (value == null || value === '') {
		return fallback;
	}
	const parsed = Number(value);
	if (!Number.isFinite(parsed) || parsed <= 0) {
		return fallback;
	}
	return parsed;
}

export function normalizeSoundName(value, fallback = DEFAULT_CONFIG.preconfirmSoundName) {
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
	const preconfirmSoundName = normalizeSoundName(config.preconfirmSoundName, DEFAULT_CONFIG.preconfirmSoundName);
	const derivedAudioFeedbackEnabled = preconfirmSoundName !== '';
	return {
		audioFeedbackEnabled: parseBoolean(config.audioFeedbackEnabled, derivedAudioFeedbackEnabled),
		preconfirmSoundName,
		readyOverlayEnabled: parseBoolean(config.readyOverlayEnabled, DEFAULT_CONFIG.readyOverlayEnabled),
		reviewWindowSeconds: parsePositiveNumber(config.reviewWindowSeconds, DEFAULT_CONFIG.reviewWindowSeconds),
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

function serializeEnvNumber(value) {
	return String(value);
}

export async function loadConfig(runtime) {
	try {
		const raw = await fs.readFile(runtime.configFilePath, 'utf-8');
		const env = parseEnvFile(raw);
		return normalizeConfig({
			audioFeedbackEnabled: env.DJI_ENABLE_AUDIO_FEEDBACK,
			preconfirmSoundName: env.DJI_PRECONFIRM_SOUND_NAME,
			readyOverlayEnabled: env.DJI_ENABLE_READY_HUD,
			reviewWindowSeconds: env.DJI_REVIEW_WINDOW_SECONDS,
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
		`DJI_PRECONFIRM_SOUND_NAME=${serializeEnvString(normalized.preconfirmSoundName)}`,
		`DJI_ENABLE_READY_HUD=${serializeEnvValue(normalized.readyOverlayEnabled)}`,
		`DJI_REVIEW_WINDOW_SECONDS=${serializeEnvNumber(normalized.reviewWindowSeconds)}`,
		'',
	].join('\n');
	await fs.writeFile(runtime.configFilePath, content, 'utf-8');
	return normalized;
}
