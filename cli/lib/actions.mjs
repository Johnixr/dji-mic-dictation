import fs from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { execFile as execFileCallback } from 'node:child_process';
import { promisify } from 'node:util';

import { DEFAULT_CONFIG, loadConfig, normalizeConfig, writeConfig } from './config.mjs';
import {
	findManagedEntries,
	findProfile,
	inferTriggerMode,
	isManagedRuleCurrent,
	listProfiles,
	loadKarabinerConfig,
	loadRuleTemplate,
	MANAGED_DEVICE,
	removeManagedEntries,
	resolveTargetProfile,
	syncManagedEntries,
	TRIGGER_MODE_KEYBOARD,
	TRIGGER_MODE_KEYBOARD_DJI,
	writeKarabinerConfig,
} from './karabiner.mjs';
import { detectPermissions } from './permissions.mjs';

const execFile = promisify(execFileCallback);
const MANIFEST_VERSION = 1;

async function pathExists(filePath) {
	try {
		await fs.access(filePath, fsConstants.F_OK);
		return true;
	} catch {
		return false;
	}
}

async function removeIfExists(filePath) {
	try {
		await fs.rm(filePath, { force: true, recursive: false });
	} catch (error) {
		if (error.code !== 'ENOENT') {
			throw error;
		}
	}
}

function createCommandError(message, code) {
	const error = new Error(message);
	error.code = code;
	return error;
}

async function assertInstallationPrerequisites(runtime) {
	if (!(await pathExists(runtime.typelessDbPath))) {
		throw createCommandError(
			`Typeless DB not found at ${runtime.typelessDbPath}. Install/open Typeless first.`,
			'TYPELESS_DB_MISSING',
		);
	}
	if (!(await pathExists(runtime.karabinerConfigPath))) {
		throw createCommandError(
			`Karabiner config not found at ${runtime.karabinerConfigPath}. Open Karabiner-Elements once first.`,
			'KARABINER_CONFIG_MISSING',
		);
	}
}

export async function readManifest(runtime) {
	try {
		return JSON.parse(await fs.readFile(runtime.manifestFilePath, 'utf-8'));
	} catch (error) {
		if (error.code === 'ENOENT') {
			return null;
		}
		throw error;
	}
}

async function writeManifest(runtime, manifest) {
	await fs.mkdir(runtime.configDir, { recursive: true });
	await fs.writeFile(runtime.manifestFilePath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf-8');
}

function isManagedDeviceIdentifiers(identifiers) {
	return (
		identifiers?.vendor_id === MANAGED_DEVICE.identifiers.vendor_id &&
		identifiers?.product_id === MANAGED_DEVICE.identifiers.product_id &&
		identifiers?.is_consumer === MANAGED_DEVICE.identifiers.is_consumer
	);
}

function parseConnectedDevicesJson(output) {
	try {
		const parsed = JSON.parse(output);
		return Array.isArray(parsed) ? parsed : null;
	} catch {
		return null;
	}
}

function hasManagedDeviceInCliOutput(stdout, stderr = '') {
	const parsedDevices = parseConnectedDevicesJson(stdout.trim());
	if (parsedDevices) {
		return parsedDevices.some((device) => isManagedDeviceIdentifiers(device?.device_identifiers));
	}

	const output = `${stdout}${stderr}`;
	return (
		new RegExp(`"?vendor_id"?\\s*[:=]\\s*${MANAGED_DEVICE.identifiers.vendor_id}`, 'u').test(output) &&
		new RegExp(`"?product_id"?\\s*[:=]\\s*${MANAGED_DEVICE.identifiers.product_id}`, 'u').test(output)
	);
}

export async function detectOptionalTriggerDevice(runtime) {
	if (!(await pathExists(runtime.karabinerCliPath))) {
		return { status: 'unknown', reason: 'karabiner_cli_missing' };
	}

	try {
		const { stdout, stderr } = await execFile(runtime.karabinerCliPath, ['--list-connected-devices'], {
			env: runtime.env,
		});
		const connected = hasManagedDeviceInCliOutput(stdout, stderr);
		return { status: connected ? 'connected' : 'not_connected', reason: null };
	} catch (error) {
		return {
			status: 'unknown',
			reason: error.code || 'karabiner_cli_failed',
		};
	}
}

function resolveConnectedDeviceStatus(triggerMode, detectedDevice) {
	if (triggerMode !== TRIGGER_MODE_KEYBOARD_DJI) {
		return { status: 'not_enabled', reason: 'optional_trigger_disabled' };
	}
	return detectedDevice;
}

async function selectProfileViaCli(runtime, profileName) {
	if (!(await pathExists(runtime.karabinerCliPath))) {
		return { status: 'skipped', reason: 'karabiner_cli_missing' };
	}

	try {
		await execFile(runtime.karabinerCliPath, ['--select-profile', profileName], {
			env: runtime.env,
		});
		return { status: 'selected', reason: null };
	} catch (error) {
		return { status: 'failed', reason: error.code || 'karabiner_cli_select_failed' };
	}
}

async function copyScript(runtime) {
	await fs.mkdir(runtime.karabinerScriptsDir, { recursive: true });
	await fs.copyFile(runtime.scriptSourcePath, runtime.scriptTargetPath);
	await fs.chmod(runtime.scriptTargetPath, 0o755);
}

function mergeConfig(existingConfig, overrides = {}) {
	return normalizeConfig({ ...existingConfig, ...overrides });
}

function normalizeTriggerMode(triggerMode) {
	if (!triggerMode) {
		return null;
	}
	const normalized = String(triggerMode).trim().toLowerCase();
	if (['keyboard', 'keyboard-only'].includes(normalized)) {
		return TRIGGER_MODE_KEYBOARD;
	}
	if (['keyboard+dji', 'keyboard+mic', 'dji', 'keyboard-and-dji'].includes(normalized)) {
		return TRIGGER_MODE_KEYBOARD_DJI;
	}
	throw new Error(`Unsupported trigger mode: ${triggerMode}`);
}

function normalizeProfileOptions(profileOptions = {}) {
	if (profileOptions.cloneProfileFrom && !profileOptions.profileStrategy) {
		return {
			profileStrategy: 'clone',
			sourceProfileName: profileOptions.cloneProfileFrom,
			newProfileName: profileOptions.newProfileName,
		};
	}
	if (profileOptions.profileName && !profileOptions.profileStrategy) {
		return {
			profileStrategy: 'existing',
			profileName: profileOptions.profileName,
		};
	}
	return {
		profileStrategy: profileOptions.profileStrategy || 'active',
		profileName: profileOptions.profileName,
		sourceProfileName: profileOptions.sourceProfileName,
		newProfileName: profileOptions.newProfileName,
	};
}

function hasExplicitProfileSelection(options = {}) {
	return Boolean(
		options.profileOptions ||
			options.profileName ||
			options.profileStrategy ||
			options.sourceProfileName ||
			options.newProfileName ||
			options.cloneProfileFrom,
	);
}

async function resolveInstallProfileOptions(runtime, options = {}) {
	if (options.profileOptions) {
		return options.profileOptions;
	}
	if (hasExplicitProfileSelection(options)) {
		return options;
	}
	const manifest = await readManifest(runtime);
	if (manifest?.profileName) {
		return {
			profileStrategy: 'existing',
			profileName: manifest.profileName,
		};
	}
	return { profileStrategy: 'active' };
}

function hasExplicitTriggerSelection(options = {}) {
	return Boolean(options.triggerMode);
}

async function resolveInstallTriggerMode(runtime, options = {}) {
	const explicitTriggerMode = normalizeTriggerMode(options.triggerMode);
	if (explicitTriggerMode) {
		return explicitTriggerMode;
	}
	const manifest = await readManifest(runtime);
	if (manifest?.triggerMode) {
		return inferTriggerMode(manifest);
	}
	const existingTemplateRule = await loadRuleTemplate(runtime, TRIGGER_MODE_KEYBOARD_DJI);
	const existingKarabinerConfig = await loadKarabinerConfig(runtime);
	const existingManagedProfiles = findManagedEntries(existingKarabinerConfig, existingTemplateRule);
	if (existingManagedProfiles.length > 0) {
		return inferTriggerMode(manifest, existingManagedProfiles);
	}
	const detectedDevice = await detectOptionalTriggerDevice(runtime);
	return detectedDevice.status === 'connected' ? TRIGGER_MODE_KEYBOARD_DJI : TRIGGER_MODE_KEYBOARD;
}

async function syncInstallation(runtime, { profileOptions = {}, configOverrides = {}, installedMode, triggerMode }) {
	const normalizedTriggerMode = normalizeTriggerMode(triggerMode) || TRIGGER_MODE_KEYBOARD;
	const detectedDevice = await detectOptionalTriggerDevice(runtime);
	const templateRule = await loadRuleTemplate(runtime, normalizedTriggerMode);
	const karabinerConfig = await loadKarabinerConfig(runtime);
	const existingConfig = await loadConfig(runtime);
	const nextConfig = mergeConfig(existingConfig, configOverrides);
	const resolvedProfile = resolveTargetProfile(karabinerConfig, normalizeProfileOptions(profileOptions));
	const { profileName: appliedProfileName } = syncManagedEntries(karabinerConfig, templateRule, resolvedProfile.profileName, {
		includeManagedDevice: normalizedTriggerMode === TRIGGER_MODE_KEYBOARD_DJI,
	});

	await writeKarabinerConfig(runtime, karabinerConfig);
	const profileSwitch = await selectProfileViaCli(runtime, appliedProfileName);
	await copyScript(runtime);
	await writeConfig(runtime, nextConfig);

	const manifest = {
		manifestVersion: MANIFEST_VERSION,
		installedMode,
		packageVersion: runtime.packageVersion,
		profileName: appliedProfileName,
		profileStrategy: resolvedProfile.profileStrategy,
		sourceProfileName: resolvedProfile.sourceProfileName,
		triggerMode: normalizedTriggerMode,
		scriptTargetPath: runtime.scriptTargetPath,
		configFilePath: runtime.configFilePath,
		updatedAt: new Date().toISOString(),
	};
	await writeManifest(runtime, manifest);
	const permissions = await detectPermissions(runtime);

	return {
		config: nextConfig,
		manifest,
		device: resolveConnectedDeviceStatus(normalizedTriggerMode, detectedDevice),
		permissions,
		profileName: appliedProfileName,
		profileStrategy: resolvedProfile.profileStrategy,
		triggerMode: normalizedTriggerMode,
		profileSwitch,
	};
}

export async function getKarabinerProfiles(runtime) {
	const karabinerConfig = await loadKarabinerConfig(runtime);
	return listProfiles(karabinerConfig);
}

export async function install(runtime, options = {}) {
	await assertInstallationPrerequisites(runtime);

	return syncInstallation(runtime, {
		profileOptions: await resolveInstallProfileOptions(runtime, options),
		triggerMode: await resolveInstallTriggerMode(runtime, options),
		configOverrides: options.configOverrides,
		installedMode: 'install',
	});
}

export async function update(runtime, options = {}) {
	await assertInstallationPrerequisites(runtime);

	const manifest = await readManifest(runtime);
	const templateRule = await loadRuleTemplate(runtime);
	const karabinerConfig = await loadKarabinerConfig(runtime);
	const managedProfiles = findManagedEntries(karabinerConfig, templateRule);
	const scriptInstalled = await pathExists(runtime.scriptTargetPath);

	if (!manifest && managedProfiles.length === 0 && !scriptInstalled) {
		throw createCommandError('No existing installation found. Run install first.', 'NOT_INSTALLED');
	}

	return syncInstallation(runtime, {
		profileOptions:
			options.profileOptions ||
			(options.profileName || options.profileStrategy || options.sourceProfileName || options.newProfileName || options.cloneProfileFrom
				? options
				: {
					profileStrategy: 'existing',
					profileName: manifest?.profileName || managedProfiles.find((profile) => profile.selected)?.name || managedProfiles[0]?.name,
				}),
		triggerMode:
			hasExplicitTriggerSelection(options) ? normalizeTriggerMode(options.triggerMode) : inferTriggerMode(manifest, managedProfiles),
		configOverrides: options.configOverrides,
		installedMode: 'update',
	});
}

export async function configureInstallation(runtime, configOverrides = {}) {
	const currentConfig = await loadConfig(runtime);
	const nextConfig = mergeConfig(currentConfig, configOverrides);
	await writeConfig(runtime, nextConfig);
	return nextConfig;
}

export async function uninstall(runtime) {
	const templateRule = await loadRuleTemplate(runtime);
	let removedRuleCount = 0;
	let removedDeviceCount = 0;

	if (await pathExists(runtime.karabinerConfigPath)) {
		const karabinerConfig = await loadKarabinerConfig(runtime);
		const removed = removeManagedEntries(karabinerConfig, templateRule);
		removedRuleCount = removed.removedRuleCount;
		removedDeviceCount = removed.removedDeviceCount;
		await writeKarabinerConfig(runtime, karabinerConfig);
	}

	await removeIfExists(runtime.scriptTargetPath);
	await removeIfExists(runtime.configFilePath);
	await removeIfExists(runtime.manifestFilePath);

	try {
		await fs.rmdir(runtime.configDir);
	} catch (error) {
		if (!['ENOENT', 'ENOTEMPTY'].includes(error.code)) {
			throw error;
		}
	}

	return { removedRuleCount, removedDeviceCount };
}

export async function doctor(runtime) {
	const karabinerConfigExists = await pathExists(runtime.karabinerConfigPath);
	const karabinerCliExists = await pathExists(runtime.karabinerCliPath);
	const typelessDbExists = await pathExists(runtime.typelessDbPath);
	const scriptInstalled = await pathExists(runtime.scriptTargetPath);
	const configInstalled = await pathExists(runtime.configFilePath);
	const manifest = await readManifest(runtime);

	let managedProfiles = [];
	let profileCurrent = false;
	let triggerMode = inferTriggerMode(manifest);
	if (karabinerConfigExists) {
		const karabinerConfig = await loadKarabinerConfig(runtime);
		const templateRule = await loadRuleTemplate(runtime, inferTriggerMode(manifest, managedProfiles));
		managedProfiles = findManagedEntries(karabinerConfig, templateRule);
		triggerMode = inferTriggerMode(manifest, managedProfiles);
		const activeProfileName = manifest?.profileName || managedProfiles.find((profile) => profile.selected)?.name;
		if (activeProfileName) {
			try {
				const currentTemplateRule = await loadRuleTemplate(runtime, triggerMode);
				const activeProfile = findProfile(karabinerConfig, activeProfileName);
				profileCurrent = isManagedRuleCurrent(activeProfile, currentTemplateRule);
			} catch {
				profileCurrent = false;
			}
		}
	}

	const connectedDevice = resolveConnectedDeviceStatus(triggerMode, await detectOptionalTriggerDevice(runtime));
	const installed = Boolean(manifest || scriptInstalled || managedProfiles.length > 0);
	const packageVersion = runtime.packageVersion;
	const installedVersion = manifest?.packageVersion || null;
	const permissions = await detectPermissions(runtime);

	return {
		packageVersion,
		installedVersion,
		updateAvailable: Boolean(installedVersion && installedVersion !== packageVersion),
		installed,
		karabinerCliExists,
		karabinerConfigExists,
		typelessDbExists,
		scriptInstalled,
		configInstalled,
		manifestExists: Boolean(manifest),
		managedProfiles,
		profileCurrent,
		triggerMode,
		connectedDevice,
		permissions,
	};
}

export { DEFAULT_CONFIG };
