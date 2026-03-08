import fs from 'node:fs/promises';

export const TRIGGER_MODE_KEYBOARD = 'keyboard';
export const TRIGGER_MODE_KEYBOARD_DJI = 'keyboard+dji';

export const MANAGED_DEVICE = Object.freeze({
	identifiers: {
		is_consumer: true,
		product_id: 16401,
		vendor_id: 11427,
	},
	ignore: false,
});

const MANAGED_SCRIPT_COMMAND_PATH = '~/.config/karabiner/scripts/dictation-enter.sh';

function sortValue(value) {
	if (Array.isArray(value)) {
		return value.map(sortValue);
	}
	if (value && typeof value === 'object') {
		return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortValue(value[key])]));
	}
	return value;
}

function stableStringify(value) {
	return JSON.stringify(sortValue(value));
}

function ensureProfileArrays(profile) {
	profile.complex_modifications ??= {};
	profile.complex_modifications.rules ??= [];
	profile.devices ??= [];
	return profile;
}

function matchManagedDevice(device) {
	const identifiers = device?.identifiers;
	return (
		identifiers?.vendor_id === MANAGED_DEVICE.identifiers.vendor_id &&
		identifiers?.product_id === MANAGED_DEVICE.identifiers.product_id &&
		identifiers?.is_consumer === MANAGED_DEVICE.identifiers.is_consumer
	);
}

function valueContainsManagedScriptCommand(value) {
	if (Array.isArray(value)) {
		return value.some((item) => valueContainsManagedScriptCommand(item));
	}
	if (!value || typeof value !== 'object') {
		return false;
	}
	if (typeof value.shell_command === 'string' && value.shell_command.includes(MANAGED_SCRIPT_COMMAND_PATH)) {
		return true;
	}
	return Object.values(value).some((item) => valueContainsManagedScriptCommand(item));
}

function matchManagedRule(rule, templateRule) {
	return rule?.description === templateRule.description || valueContainsManagedScriptCommand(rule);
}

function isDjiManipulator(manipulator) {
	return manipulator?.from?.consumer_key_code === 'volume_increment';
}

function filterManipulatorsForTriggerMode(manipulators = [], triggerMode) {
	if (triggerMode === TRIGGER_MODE_KEYBOARD) {
		return manipulators.filter((manipulator) => !isDjiManipulator(manipulator));
	}
	return manipulators;
}

export async function loadRuleTemplate(runtime, triggerMode = TRIGGER_MODE_KEYBOARD_DJI) {
	const template = JSON.parse(await fs.readFile(runtime.karabinerTemplatePath, 'utf-8'));
	const rule = structuredClone(template.rules[0]);
	rule.manipulators = filterManipulatorsForTriggerMode(rule.manipulators, triggerMode);
	return rule;
}

export async function loadKarabinerConfig(runtime) {
	return JSON.parse(await fs.readFile(runtime.karabinerConfigPath, 'utf-8'));
}

export async function writeKarabinerConfig(runtime, config) {
	await fs.mkdir(runtime.karabinerDir, { recursive: true });
	await fs.writeFile(runtime.karabinerConfigPath, `${JSON.stringify(config, null, 2)}\n`, 'utf-8');
}

export function listProfiles(config) {
	return (config?.profiles || []).map((profile) => ({
		name: profile.name,
		selected: Boolean(profile.selected),
	}));
}

export function findProfile(config, requestedProfileName) {
	const profiles = config?.profiles || [];
	if (profiles.length === 0) {
		throw new Error('No Karabiner profiles found.');
	}
	if (requestedProfileName) {
		const matched = profiles.find((profile) => profile.name === requestedProfileName);
		if (!matched) {
			throw new Error(`Karabiner profile not found: ${requestedProfileName}`);
		}
		return matched;
	}
	return profiles.find((profile) => profile.selected) || profiles[0];
}

export function setSelectedProfile(config, requestedProfileName) {
	const profile = findProfile(config, requestedProfileName);
	for (const currentProfile of config?.profiles || []) {
		currentProfile.selected = currentProfile.name === profile.name;
	}
	return profile;
}

export function cloneProfile(config, sourceProfileName, newProfileName) {
	const sourceProfile = findProfile(config, sourceProfileName);
	if (!newProfileName?.trim()) {
		throw new Error('New Karabiner profile name is required.');
	}
	if ((config?.profiles || []).some((profile) => profile.name === newProfileName)) {
		throw new Error(`Karabiner profile already exists: ${newProfileName}`);
	}
	const clonedProfile = structuredClone(sourceProfile);
	clonedProfile.name = newProfileName;
	clonedProfile.selected = false;
	config.profiles.push(clonedProfile);
	return clonedProfile;
}

export function resolveTargetProfile(config, profileOptions = {}) {
	const profileStrategy = profileOptions.profileStrategy || 'active';

	switch (profileStrategy) {
		case 'active': {
			const activeProfile = setSelectedProfile(config, findProfile(config).name);
			return {
				profileName: activeProfile.name,
				profileStrategy,
				sourceProfileName: null,
			};
		}
		case 'existing': {
			if (!profileOptions.profileName) {
				throw new Error('A Karabiner profile name is required for the existing profile strategy.');
			}
			const targetProfile = setSelectedProfile(config, profileOptions.profileName);
			return {
				profileName: targetProfile.name,
				profileStrategy,
				sourceProfileName: null,
			};
		}
		case 'clone': {
			const sourceProfileName = profileOptions.sourceProfileName || findProfile(config).name;
			if (!profileOptions.newProfileName) {
				throw new Error('A new Karabiner profile name is required for the clone strategy.');
			}
			cloneProfile(config, sourceProfileName, profileOptions.newProfileName);
			const targetProfile = setSelectedProfile(config, profileOptions.newProfileName);
			return {
				profileName: targetProfile.name,
				profileStrategy,
				sourceProfileName,
			};
		}
		default:
			throw new Error(`Unsupported Karabiner profile strategy: ${profileStrategy}`);
	}
}

export function inferTriggerMode(manifest, managedProfiles = []) {
	if (manifest?.triggerMode === TRIGGER_MODE_KEYBOARD || manifest?.triggerMode === TRIGGER_MODE_KEYBOARD_DJI) {
		return manifest.triggerMode;
	}
	return managedProfiles.some((profile) => profile.hasDevice) ? TRIGGER_MODE_KEYBOARD_DJI : TRIGGER_MODE_KEYBOARD;
}

export function syncManagedEntries(config, templateRule, requestedProfileName, { includeManagedDevice = true } = {}) {
	removeManagedEntries(config, templateRule);
	const profile = ensureProfileArrays(findProfile(config, requestedProfileName));
	const existingRules = profile.complex_modifications.rules.filter(
		(rule) => !matchManagedRule(rule, templateRule),
	);
	profile.complex_modifications.rules = [...existingRules, templateRule];

	if (includeManagedDevice) {
		const existingDevices = profile.devices.filter((device) => !matchManagedDevice(device));
		profile.devices = [...existingDevices, MANAGED_DEVICE];
	}

	return { profileName: profile.name };
}

export function removeManagedEntries(config, templateRule) {
	let removedRuleCount = 0;
	let removedDeviceCount = 0;

	for (const profile of config?.profiles || []) {
		ensureProfileArrays(profile);
		const originalRuleCount = profile.complex_modifications.rules.length;
		const originalDeviceCount = profile.devices.length;

		profile.complex_modifications.rules = profile.complex_modifications.rules.filter(
			(rule) => !matchManagedRule(rule, templateRule),
		);
		profile.devices = profile.devices.filter((device) => !matchManagedDevice(device));

		removedRuleCount += originalRuleCount - profile.complex_modifications.rules.length;
		removedDeviceCount += originalDeviceCount - profile.devices.length;
	}

	return { removedRuleCount, removedDeviceCount };
}

export function findManagedEntries(config, templateRule) {
	const profiles = [];
	for (const profile of config?.profiles || []) {
		const rules = profile?.complex_modifications?.rules || [];
		const devices = profile?.devices || [];
		const hasRule = rules.some((rule) => matchManagedRule(rule, templateRule));
		const hasDevice = devices.some((device) => matchManagedDevice(device));
		if (hasRule || hasDevice) {
			profiles.push({
				name: profile.name,
				hasRule,
				hasDevice,
				selected: Boolean(profile.selected),
			});
		}
	}
	return profiles;
}

export function isManagedRuleCurrent(profile, templateRule) {
	const rules = profile?.complex_modifications?.rules || [];
	const managedRule = rules.find((rule) => matchManagedRule(rule, templateRule));
	return managedRule ? stableStringify(managedRule) === stableStringify(templateRule) : false;
}
