#!/usr/bin/env node

import process from 'node:process';

import {
	cancel,
	confirm,
	intro,
	isCancel,
	note,
	outro,
	select,
	spinner,
	text,
} from '@clack/prompts';

import {
	configureInstallation,
	DEFAULT_CONFIG,
	detectOptionalTriggerDevice,
	doctor,
	getKarabinerProfiles,
	install,
	readManifest,
	uninstall,
	update,
} from './lib/actions.mjs';
import { loadConfig } from './lib/config.mjs';
import { buildInstallProfilePromptPlan } from './lib/install-profile-plan.mjs';
import { createRuntime } from './lib/runtime.mjs';
import { listSystemSounds } from './lib/sounds.mjs';

const HELP_TEXT = `dji-mic-dictation <command> [options]

Commands:
  install      Install or reconcile the Karabiner/script setup
  update       Refresh an existing installation to the current package version
  doctor       Diagnose the current setup and report what is missing
  config       Update audio/overlay preferences
  uninstall    Remove installed script/config/Karabiner entries

Options:
  --yes                  Skip confirmation prompts where possible
  --trigger-mode <mode>  Trigger mode: keyboard | keyboard+dji
  --sound on|off         Enable or disable all notification sounds
  --preconfirm-sound <name>
                         Preconfirm sound name from /System/Library/Sounds, or off
  --ready-overlay on|off Enable or disable the ready-to-send countdown overlay
  --profile <name>       Target Karabiner profile name
  --clone-profile-from <name>
                         Clone an existing Karabiner profile before installing
  --new-profile-name <name>
                         New Karabiner profile name to create when cloning
  --json                 Print machine-readable JSON output
  --help                 Show this help text
  --version              Show CLI package version
`;

function parseArgs(argv) {
	const args = [...argv];
	let command = 'help';
	if (args[0] && !args[0].startsWith('-')) {
		command = args.shift();
	}

	const flags = {};
	for (let index = 0; index < args.length; index += 1) {
		const arg = args[index];
		switch (arg) {
			case '--yes':
				flags.yes = true;
				break;
			case '--json':
				flags.json = true;
				break;
			case '--help':
				flags.help = true;
				break;
			case '--version':
				flags.version = true;
				break;
			case '--profile':
				flags.profileName = args[++index];
				break;
			case '--clone-profile-from':
				flags.cloneProfileFrom = args[++index];
				break;
			case '--new-profile-name':
				flags.newProfileName = args[++index];
				break;
			case '--sound':
				flags.sound = args[++index];
				break;
			case '--trigger-mode':
				flags.triggerMode = args[++index];
				break;
			case '--preconfirm-sound':
				flags.preconfirmSoundName = args[++index];
				break;
			case '--ready-overlay':
				flags.readyOverlay = args[++index];
				break;
			default:
				throw new Error(`Unknown option: ${arg}`);
		}
	}

	return { command, flags };
}

function formatTriggerMode(triggerMode) {
	return triggerMode === 'keyboard+dji' ? 'keyboard workflow + DJI Mic Mini trigger' : 'keyboard workflow only';
}

const ANSI_GRAY = '\u001B[90m';
const ANSI_RESET = '\u001B[39m\u001B[22m';

function formatSecondaryPromptHint(text) {
	return process.stdout.isTTY ? `${ANSI_GRAY}${text}${ANSI_RESET}` : text;
}

function buildPromptMessage(title, hint) {
	if (!hint) {
		return title;
	}
	return `${title} ${formatSecondaryPromptHint(`(${hint})`)}`;
}

function formatSoundDefaultLabel(soundName) {
	return soundName ? soundName : 'Off';
}

function printExistingInstallSummary({ profileName, triggerMode }) {
	const lines = ['Existing installation found'];
	if (profileName) {
		lines.push(`Profile: ${profileName}`);
	}
	if (triggerMode) {
		lines.push(`Trigger: ${formatTriggerMode(triggerMode)}`);
	}
	note(lines.join('\n'), 'Reusing existing install');
}

function buildProfileOverrides(flags) {
	if (flags.cloneProfileFrom || flags.newProfileName) {
		if (!flags.cloneProfileFrom || !flags.newProfileName) {
			throw new Error('Both --clone-profile-from and --new-profile-name are required when cloning a Karabiner profile.');
		}
		if (flags.profileName) {
			throw new Error('Use either --profile or the clone profile flags, not both.');
		}
		return {
			profileStrategy: 'clone',
			sourceProfileName: flags.cloneProfileFrom,
			newProfileName: flags.newProfileName,
		};
	}
	if (flags.profileName) {
		return {
			profileStrategy: 'existing',
			profileName: flags.profileName,
		};
	}
	return null;
}

function parseToggle(value, key) {
	if (value == null) {
		return undefined;
	}
	const normalized = String(value).trim().toLowerCase();
	if (['1', 'true', 'yes', 'on'].includes(normalized)) {
		return true;
	}
	if (['0', 'false', 'no', 'off'].includes(normalized)) {
		return false;
	}
	throw new Error(`Invalid value for ${key}: ${value}`);
}

function buildConfigOverrides(flags) {
	const overrides = {};
	const audioFeedbackEnabled = parseToggle(flags.sound, '--sound');
	const readyOverlayEnabled = parseToggle(flags.readyOverlay, '--ready-overlay');
	if (audioFeedbackEnabled === false) {
		overrides.audioFeedbackEnabled = audioFeedbackEnabled;
		overrides.preconfirmSoundName = '';
	} else if (audioFeedbackEnabled === true) {
		overrides.audioFeedbackEnabled = audioFeedbackEnabled;
	}
	if (flags.preconfirmSoundName != null) {
		overrides.preconfirmSoundName = flags.preconfirmSoundName;
	}
	if (readyOverlayEnabled != null) {
		overrides.readyOverlayEnabled = readyOverlayEnabled;
	}
	return overrides;
}

async function askBooleanPrompt(message, initialValue) {
	const answer = await confirm({ message, initialValue });
	if (isCancel(answer)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return answer;
}

async function askSelectPrompt(message, initialValue, options) {
	const answer = await select({
		message,
		initialValue,
		options,
	});
	if (isCancel(answer)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return answer;
}

async function askTextPrompt(message, initialValue, validate) {
	const answer = await text({
		message,
		initialValue,
		validate,
	});
	if (isCancel(answer)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return answer;
}

async function collectInteractiveConfig(runtime, overrides = {}) {
	const currentConfig = { ...DEFAULT_CONFIG, ...(await loadConfig(runtime)), ...overrides };
	const soundOptions = await listSystemSounds(runtime);
	const selectableSoundOptions = [
		{ value: '', label: 'Off' },
		...soundOptions.map((soundName) => ({ value: soundName, label: soundName })),
	];
	const currentPreconfirmSoundName = currentConfig.audioFeedbackEnabled ? currentConfig.preconfirmSoundName : '';
	const initialPreconfirmSound = soundOptions.includes(currentPreconfirmSoundName) ? currentPreconfirmSoundName : '';
	const preconfirmSoundName = await askSelectPrompt(
		buildPromptMessage(
			'Preconfirm sound',
			`Default: ${formatSoundDefaultLabel(initialPreconfirmSound)}`,
		),
		initialPreconfirmSound,
		selectableSoundOptions,
	);
	const readyOverlayEnabled = await askBooleanPrompt('Enable the ready-to-send countdown overlay?', currentConfig.readyOverlayEnabled);
	return {
		audioFeedbackEnabled: preconfirmSoundName !== '',
		preconfirmSoundName,
		readyOverlayEnabled,
	};
}

function formatSoundSetting(soundName) {
	return soundName ? soundName : 'off';
}

function printJson(result) {
	process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

function createProgress(enabled) {
	if (!enabled) {
		return {
			start() {},
			stop() {},
		};
	}
	return spinner();
}

function isPermissionSatisfied(status) {
	return ['granted', 'enabled', 'ok'].includes(status);
}

function formatPermissionAction(item) {
	switch (item.key) {
		case 'karabinerInputMonitoring':
			return item.status === 'unknown'
				? 'Input Monitoring: could not verify automatically'
				: 'Input Monitoring: allow Karabiner in Privacy & Security';
		case 'accessibilityCurrentSession':
			return item.status === 'unknown'
				? 'Accessibility: could not verify this terminal session automatically'
				: 'Accessibility: allow your terminal app';
		case 'postEventCurrentSession':
			return item.status === 'unknown'
				? 'Event control: could not verify automatically'
				: 'Event control: allow your terminal session to send keys';
		case 'dictation':
			return item.status === 'unknown' ? 'Dictation: could not verify automatically' : 'Dictation: turn it on in Keyboard settings';
		default:
			return `${item.label}: ${item.status}`;
	}
}

function printPermissionsReminder(permissions) {
	if (!permissions || permissions.status === 'ok') {
		return;
	}
	const issues = (permissions.items || []).filter((item) => !isPermissionSatisfied(item.status));
	if (issues.length === 0) {
		return;
	}
	note(issues.map((item) => formatPermissionAction(item)).join('\n'), 'Permissions needing attention');
}

function formatDoctorReport(report) {
	const lines = [
		`installed: ${report.installed ? 'yes' : 'no'}`,
		`package version: ${report.packageVersion}`,
		`installed version: ${report.installedVersion || 'none'}`,
		`update available: ${report.updateAvailable ? 'yes' : 'no'}`,
		`Typeless DB: ${report.typelessDbExists ? 'ok' : 'missing'}`,
		`Karabiner CLI: ${report.karabinerCliExists ? 'ok' : 'missing'}`,
		`Karabiner config: ${report.karabinerConfigExists ? 'ok' : 'missing'}`,
		`script installed: ${report.scriptInstalled ? 'yes' : 'no'}`,
		`config installed: ${report.configInstalled ? 'yes' : 'no'}`,
		`trigger mode: ${formatTriggerMode(report.triggerMode)}`,
		`device: ${report.connectedDevice.status}`,
		`managed profiles: ${report.managedProfiles.length ? report.managedProfiles.map((profile) => profile.name).join(', ') : 'none'}`,
	];
	if (report.permissions?.status) {
		lines.push(`permissions: ${report.permissions.status}`);
	}
	return lines.join('\n');
}

async function collectInteractiveTriggerMode(runtime) {
	const manifest = await readManifest(runtime);
	if (manifest?.triggerMode) {
		return { triggerMode: manifest.triggerMode, reusedTriggerMode: manifest.triggerMode };
	}

	const installReport = await doctor(runtime);
	if (installReport.installed && installReport.managedProfiles.length > 0) {
		return { triggerMode: installReport.triggerMode, reusedTriggerMode: installReport.triggerMode };
	}

	const detectedDevice = await detectOptionalTriggerDevice(runtime);
	if (detectedDevice.status === 'connected') {
		note(
			['DJI Mic Mini receiver detected', 'Optional trigger will be enabled'].join('\n'),
			'Trigger mode',
		);
		return { triggerMode: 'keyboard+dji', reusedTriggerMode: null };
	}

	const triggerMode = await select({
		message:
			detectedDevice.status === 'unknown'
				? 'Could not confirm whether a DJI Mic Mini is connected. Install keyboard workflow only, or also configure the optional DJI trigger?'
				: 'No DJI Mic Mini detected right now. Install keyboard workflow only, or also configure the optional DJI trigger for later?',
		initialValue: 'keyboard',
		options: [
			{
				value: 'keyboard',
				label: 'Keyboard workflow only',
				hint: 'Fn stays first-class; no external button required',
			},
			{
				value: 'keyboard+dji',
				label: 'Keyboard workflow + DJI Mic Mini trigger',
				hint: 'Adds an optional hardware trigger mapped to the same workflow',
			},
		],
	});
	if (isCancel(triggerMode)) {
		cancel('Cancelled');
		process.exit(1);
	}
	return { triggerMode, reusedTriggerMode: null };
}

async function collectInteractiveProfileOptions(runtime) {
	const profiles = await getKarabinerProfiles(runtime);
	const manifest = await readManifest(runtime);
	const promptPlan = buildInstallProfilePromptPlan({ profiles, manifest });
	const activeProfile = profiles.find((profile) => profile.selected) || profiles[0];

	if (promptPlan.kind === 'reuse-installed') {
		return { profileOptions: promptPlan.profileOptions, reusedProfileName: promptPlan.profileName };
	}

	if (promptPlan.kind === 'single-profile') {
		const mode = await select({
			message: `Detected one Karabiner profile: ${promptPlan.currentProfileName}`,
			initialValue: 'active',
			options: [
				{
					value: 'active',
					label: 'Use current profile',
					hint: promptPlan.currentProfileName,
				},
				{ value: 'clone', label: 'Clone current profile into a dedicated profile' },
			],
		});
		if (isCancel(mode)) {
			cancel('Cancelled');
			process.exit(1);
		}
		if (mode === 'active') {
			return { profileOptions: promptPlan.profileOptions, reusedProfileName: null };
		}
		const newProfileName = await askTextPrompt(
			'Name for the dedicated Karabiner profile',
			promptPlan.defaultCloneName,
			(value) => {
				if (!value?.trim()) {
					return 'Profile name is required.';
				}
				if (profiles.some((profile) => profile.name === value.trim())) {
					return 'That Karabiner profile already exists.';
				}
				return undefined;
			},
		);
		return {
			profileOptions: {
				profileStrategy: 'clone',
				sourceProfileName: promptPlan.currentProfileName,
				newProfileName: newProfileName.trim(),
			},
			reusedProfileName: null,
		};
	}

	const mode = await select({
		message: 'Choose how to handle the Karabiner profile',
		initialValue: activeProfile ? 'active' : 'existing',
		options: [
			{
				value: 'active',
				label: 'Use current active profile',
				hint: activeProfile ? activeProfile.name : 'first profile',
			},
			{ value: 'existing', label: 'Use an existing profile' },
			{ value: 'clone', label: 'Clone an existing profile into a dedicated profile' },
		],
	});
	if (isCancel(mode)) {
		cancel('Cancelled');
		process.exit(1);
	}

	if (mode === 'active') {
		return { profileOptions: { profileStrategy: 'active' }, reusedProfileName: null };
	}

	const selectedSource = await select({
		message: mode === 'existing' ? 'Choose the Karabiner profile to use' : 'Choose the Karabiner profile to clone',
		initialValue: activeProfile?.name,
		options: profiles.map((profile) => ({
			value: profile.name,
			label: profile.name,
			hint: profile.selected ? 'active' : undefined,
		})),
	});
	if (isCancel(selectedSource)) {
		cancel('Cancelled');
		process.exit(1);
	}

	if (mode === 'existing') {
		return {
			profileOptions: { profileStrategy: 'existing', profileName: selectedSource },
			reusedProfileName: null,
		};
	}

	const newProfileName = await askTextPrompt(
		'Name for the dedicated Karabiner profile',
		`${selectedSource} - DJI Mic Dictation`,
		(value) => {
			if (!value?.trim()) {
				return 'Profile name is required.';
			}
			if (profiles.some((profile) => profile.name === value.trim())) {
				return 'That Karabiner profile already exists.';
			}
			return undefined;
		},
	);

	return {
		profileOptions: {
			profileStrategy: 'clone',
			sourceProfileName: selectedSource,
			newProfileName: newProfileName.trim(),
		},
		reusedProfileName: null,
	};
}

async function retryableInstall(runtime, flags, interactive) {
	const showUi = interactive;
	let configOverrides = buildConfigOverrides(flags);
	const explicitProfileOverrides = buildProfileOverrides(flags);
	const explicitTriggerMode = flags.triggerMode;

	while (true) {
		const s = createProgress(showUi);
		try {
			let profileOptions = explicitProfileOverrides || { profileStrategy: 'active' };
			let triggerMode = explicitTriggerMode;
			let reusedProfileName = null;
			let reusedTriggerMode = null;
			if (showUi && !explicitProfileOverrides) {
				const profileDecision = await collectInteractiveProfileOptions(runtime);
				profileOptions = profileDecision.profileOptions;
				reusedProfileName = profileDecision.reusedProfileName;
			}
			if (showUi && !explicitTriggerMode) {
				const triggerDecision = await collectInteractiveTriggerMode(runtime);
				triggerMode = triggerDecision.triggerMode;
				reusedTriggerMode = triggerDecision.reusedTriggerMode;
			}
			if (showUi && (reusedProfileName || reusedTriggerMode)) {
				printExistingInstallSummary({
					profileName: reusedProfileName,
					triggerMode: reusedTriggerMode,
				});
			}
			if (showUi && Object.keys(configOverrides).length === 0) {
				configOverrides = await collectInteractiveConfig(runtime);
			}
			s.start('Applying Karabiner, script, and config changes');
			const result = await install(runtime, {
				profileOptions,
				triggerMode,
				configOverrides,
			});
			s.stop(`Installed on profile ${result.profileName}`);
			if (showUi && result.profileSwitch.status === 'failed') {
				note(
					`Karabiner CLI could not switch to profile "${result.profileName}" automatically. Select it manually in Karabiner-Elements if needed.`,
					'Profile switch warning',
				);
			}
			if (showUi) {
				printPermissionsReminder(result.permissions);
			}
			if (showUi && result.triggerMode === 'keyboard+dji' && result.device.status !== 'connected') {
				note('DJI receiver not detected right now. You can still finish setup and run `doctor` later.', 'Device check');
			}
			return result;
		} catch (error) {
			s.stop('Install failed');
			if (!showUi || flags.yes || !['TYPELESS_DB_MISSING', 'KARABINER_CONFIG_MISSING'].includes(error.code)) {
				throw error;
			}
			note(error.message, 'Action required');
			const shouldRetry = await askBooleanPrompt('Retry install after fixing this?', true);
			if (!shouldRetry) {
				throw error;
			}
		}
	}
}

async function run() {
	const runtime = createRuntime();
	const { command, flags } = parseArgs(process.argv.slice(2));
	const interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY && !flags.json);

	if (flags.version) {
		process.stdout.write(`${runtime.packageVersion}\n`);
		return;
	}

	if (flags.help || command === 'help') {
		process.stdout.write(HELP_TEXT);
		return;
	}

	const profileOverrides = buildProfileOverrides(flags);

	if (interactive) {
		intro(`dji-mic-dictation ${command}`);
	}

	let result;
	try {
		switch (command) {
			case 'install':
				result = await retryableInstall(runtime, flags, interactive);
				break;
			case 'update': {
					const s = createProgress(interactive);
				s.start('Updating installed files and Karabiner rules');
				result = await update(runtime, {
					profileOptions: profileOverrides || undefined,
					triggerMode: flags.triggerMode,
					configOverrides: buildConfigOverrides(flags),
				});
				s.stop(`Updated installation on profile ${result.profileName}`);
					if (interactive && result.profileSwitch.status === 'failed') {
					note(
						`Karabiner CLI could not switch to profile "${result.profileName}" automatically. Select it manually in Karabiner-Elements if needed.`,
						'Profile switch warning',
					);
				}
				break;
			}
			case 'doctor': {
					const s = createProgress(interactive);
				s.start('Inspecting current setup');
				result = await doctor(runtime);
				s.stop('Doctor report ready');
				break;
			}
			case 'config': {
				let configOverrides = buildConfigOverrides(flags);
				if (interactive && Object.keys(configOverrides).length === 0) {
					configOverrides = await collectInteractiveConfig(runtime);
				}
				result = await configureInstallation(runtime, configOverrides);
				break;
			}
			case 'uninstall': {
				if (interactive && !flags.yes) {
					const approved = await askBooleanPrompt('Remove the installed script, config, and Karabiner entries?', false);
					if (!approved) {
						cancel('Uninstall cancelled');
						return;
					}
				}
				result = await uninstall(runtime);
				break;
			}
			default:
				throw new Error(`Unknown command: ${command}`);
		}
	} catch (error) {
		if (flags.json) {
			printJson({ ok: false, error: error.message, code: error.code || null });
		} else {
			cancel(error.message);
		}
		process.exitCode = 1;
		return;
	}

	if (flags.json) {
		printJson({ ok: true, command, result });
		return;
	}

	if (command === 'doctor') {
		note(formatDoctorReport(result), 'Doctor summary');
	} else if (command === 'config') {
		note(
			[
				`preconfirm sound: ${formatSoundSetting(result.preconfirmSoundName)}`,
				`ready countdown overlay: ${result.readyOverlayEnabled ? 'on' : 'off'}`,
			].join('\n'),
			'Configuration updated',
		);
	} else if (command === 'uninstall') {
		note(
			[`removed rules: ${result.removedRuleCount}`, `removed devices: ${result.removedDeviceCount}`].join('\n'),
			'Uninstall complete',
		);
	} else {
		const manifest = await readManifest(runtime);
		note(
			[
				`profile: ${result.profileName}`,
				`trigger mode: ${formatTriggerMode(result.triggerMode)}`,
				`script: ${manifest?.scriptTargetPath || runtime.scriptTargetPath}`,
				`version: ${runtime.packageVersion}`,
			].join('\n'),
			command === 'install' ? 'Install complete' : 'Update complete',
		);
	}

	if (interactive) {
		outro('Done');
	}
}

await run();
