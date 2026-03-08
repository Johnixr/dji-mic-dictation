import fs from 'node:fs/promises';

import { DEFAULT_CONFIG } from './config.mjs';

const SOUND_EXTENSION = '.aiff';

export async function listSystemSounds(runtime) {
	try {
		const entries = await fs.readdir(runtime.soundDirectoryPath, { withFileTypes: true });
		const soundNames = entries
			.filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(SOUND_EXTENSION))
			.map((entry) => entry.name.slice(0, -SOUND_EXTENSION.length))
			.sort((left, right) => left.localeCompare(right));

		if (soundNames.length > 0) {
			return soundNames;
		}
	} catch {
		// Fall back to built-in defaults when the sound directory is unavailable.
	}

	return [...new Set([DEFAULT_CONFIG.preconfirmSoundName])];
}
