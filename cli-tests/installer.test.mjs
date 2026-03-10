import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import { doctor, install, uninstall, update } from '../cli/lib/actions.mjs';
import { loadConfig } from '../cli/lib/config.mjs';
import { buildInstallProfilePromptPlan } from '../cli/lib/install-profile-plan.mjs';
import {
	filterInstallPermissionReport,
	getBlockingPermissionIssues,
	getInstallPermissionReminderIssues,
} from '../cli/lib/install-permissions.mjs';
import { MANAGED_DEVICE } from '../cli/lib/karabiner.mjs';
import { createRuntime } from '../cli/lib/runtime.mjs';
import { listSystemSounds } from '../cli/lib/sounds.mjs';

const execFileAsync = promisify(execFile);
const MANAGED_SCRIPT_COMMAND_PATH = '~/.config/karabiner/scripts/dictation-enter.sh';

function ruleUsesManagedScript(rule) {
	return JSON.stringify(rule).includes(MANAGED_SCRIPT_COMMAND_PATH);
}

async function writeExecutable(filePath, content) {
	await fs.writeFile(filePath, content, 'utf-8');
	await fs.chmod(filePath, 0o755);
}

async function createFixture() {
	const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'dji-cli-test-'));
	const homeDir = path.join(tempDir, 'home');
	const karabinerDir = path.join(homeDir, '.config', 'karabiner');
	const typelessDir = path.join(homeDir, 'Library', 'Application Support', 'Typeless');
	const soundDir = path.join(tempDir, 'SystemSounds');
	const binDir = path.join(tempDir, 'bin');
	await fs.mkdir(karabinerDir, { recursive: true });
	await fs.mkdir(typelessDir, { recursive: true });
	await fs.mkdir(soundDir, { recursive: true });
	await fs.mkdir(binDir, { recursive: true });
	await Promise.all([
		fs.writeFile(path.join(soundDir, 'Basso.aiff'), '', 'utf-8'),
		fs.writeFile(path.join(soundDir, 'Frog.aiff'), '', 'utf-8'),
		fs.writeFile(path.join(soundDir, 'Sosumi.aiff'), '', 'utf-8'),
		fs.writeFile(path.join(soundDir, 'Tink.aiff'), '', 'utf-8'),
		fs.writeFile(path.join(soundDir, 'README.txt'), 'ignore me', 'utf-8'),
	]);

	const karabinerConfigPath = path.join(karabinerDir, 'karabiner.json');
	const karabinerConfigText = JSON.stringify(
		{
			profiles: [
				{
					name: 'Primary',
					selected: true,
					complex_modifications: {
						rules: [{ description: 'keep-me', manipulators: [] }],
					},
					devices: [{ identifiers: { vendor_id: 1, product_id: 2 }, ignore: true }],
				},
				{
					name: 'Secondary',
					selected: false,
					complex_modifications: { rules: [] },
					devices: [],
				},
			],
		},
		null,
		2,
	);
	await fs.writeFile(karabinerConfigPath, karabinerConfigText, 'utf-8');
	await fs.writeFile(path.join(typelessDir, 'typeless.db'), 'stub', 'utf-8');

	const karabinerCliPath = path.join(binDir, 'karabiner_cli');
	const karabinerCliScript = `#!/bin/sh
if [ -n "$FAKE_CONNECTED_DEVICES_OUTPUT" ]; then
	printf "%b" "$FAKE_CONNECTED_DEVICES_OUTPUT"
else
	cat <<'EOF'
[
	{
		"device_identifiers": {
			"is_consumer": true,
			"product_id": 16401,
			"vendor_id": 11427
		},
		"manufacturer": "DJI Technology Co., Ltd.",
		"product": "DJI MIC MINI"
	}
]
EOF
fi
	`;
	await writeExecutable(karabinerCliPath, karabinerCliScript);

	const env = {
		...process.env,
		PATH: `${binDir}:${process.env.PATH}`,
		DJI_INSTALLER_HOME: homeDir,
		DJI_KARABINER_CLI: karabinerCliPath,
		DJI_SOUND_DIR: soundDir,
		DJI_PERMISSION_CHECK_JSON: JSON.stringify({
			items: [
				{ key: 'karabinerInputMonitoring', label: 'Karabiner input monitoring', status: 'granted' },
				{ key: 'accessibilityCurrentSession', label: 'Current session accessibility', status: 'granted' },
				{ key: 'postEventCurrentSession', label: 'Current session event posting', status: 'granted' },
				{ key: 'dictation', label: 'macOS Dictation', status: 'enabled' },
			],
		}),
	};

	return {
		tempDir,
		binDir,
		env,
		karabinerCliPath,
		karabinerCliScript,
		karabinerConfigText,
		runtime: createRuntime({ env }),
		karabinerConfigPath,
	};
}

test('install auto-enables the optional DJI trigger when the device is connected', async () => {
	const fixture = await createFixture();
	const result = await install(fixture.runtime, {
		configOverrides: {
			audioFeedbackEnabled: false,
			readyOverlayEnabled: false,
		},
	});

	assert.equal(result.profileName, 'Primary');
	assert.equal(result.triggerMode, 'keyboard+dji');
	assert.equal(result.device.status, 'connected');
	assert.deepEqual(await loadConfig(fixture.runtime), {
		audioFeedbackEnabled: false,
		preconfirmSoundName: 'Sosumi',
		readyOverlayEnabled: false,
		reviewWindowSeconds: 3,
	});

	const installedScript = await fs.readFile(fixture.runtime.scriptTargetPath, 'utf-8');
	assert.match(installedScript, /DJI MIC MINI dictation helper/u);

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const primaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Primary');
	const managedRule = primaryProfile.complex_modifications.rules.find(
		(rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter',
	);
	assert(managedRule);
	assert(managedRule.manipulators.some((manipulator) => manipulator.from?.consumer_key_code === 'volume_increment'));
	assert(primaryProfile.devices.some((device) => device.identifiers?.vendor_id === 11427 && device.identifiers?.product_id === 16401));
	assert(primaryProfile.complex_modifications.rules.some((rule) => rule.description === 'keep-me'));
	assert.equal(primaryProfile.selected, true);
});

test('install can be forced into keyboard-only mode even when the device is connected', async () => {
	const fixture = await createFixture();
	const result = await install(fixture.runtime, {
		triggerMode: 'keyboard',
	});

	assert.equal(result.triggerMode, 'keyboard');
	assert.equal(result.device.status, 'not_enabled');

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const primaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Primary');
	const managedRule = primaryProfile.complex_modifications.rules.find(
		(rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter',
	);
	assert(!managedRule.manipulators.some((manipulator) => manipulator.from?.consumer_key_code === 'volume_increment'));
	assert(!primaryProfile.devices.some((device) => device.identifiers?.vendor_id === 11427 && device.identifiers?.product_id === 16401));
});

test('install falls back to keyboard-only mode when no DJI device is detected', async () => {
	const fixture = await createFixture();
	fixture.env.FAKE_CONNECTED_DEVICES_OUTPUT = '[{"device_identifiers":{"is_consumer":true,"vendor_id":1,"product_id":2}}]\n';
	fixture.runtime = createRuntime({ env: fixture.env });

	const result = await install(fixture.runtime, {});

	assert.equal(result.triggerMode, 'keyboard');
	assert.equal(result.device.status, 'not_enabled');
});

test('install reuses the previously installed profile when rerun without overrides', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {
		profileOptions: {
			profileStrategy: 'existing',
			profileName: 'Secondary',
		},
	});

	const result = await install(fixture.runtime, {});
	assert.equal(result.profileName, 'Secondary');

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const primaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Primary');
	const secondaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Secondary');
	assert.equal(primaryProfile.selected, false);
	assert.equal(secondaryProfile.selected, true);
	assert(secondaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
	assert(secondaryProfile.devices.some((device) => device.identifiers?.vendor_id === 11427));
	assert(!primaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
});

test('CLI install --yes --json reuses the previously installed profile when rerun without overrides', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {
		profileOptions: {
			profileStrategy: 'existing',
			profileName: 'Secondary',
		},
	});

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	for (const profile of karabinerConfig.profiles) {
		profile.selected = profile.name === 'Primary';
	}
	await fs.writeFile(fixture.karabinerConfigPath, `${JSON.stringify(karabinerConfig, null, 2)}\n`, 'utf-8');

	const { stdout } = await execFileAsync(
		process.execPath,
		[path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'), 'install', '--yes', '--json'],
		{ env: fixture.env },
	);
	const payload = JSON.parse(stdout);
	assert.equal(payload.ok, true);
	assert.equal(payload.result.profileName, 'Secondary');

	const reconciledConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const primaryProfile = reconciledConfig.profiles.find((profile) => profile.name === 'Primary');
	const secondaryProfile = reconciledConfig.profiles.find((profile) => profile.name === 'Secondary');
	assert.equal(primaryProfile.selected, false);
	assert.equal(secondaryProfile.selected, true);
	assert(secondaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
	assert(!primaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
});

test('install can target an existing Karabiner profile and reconcile old managed entries', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {});

	const result = await install(fixture.runtime, {
		profileOptions: {
			profileStrategy: 'existing',
			profileName: 'Secondary',
		},
	});

	assert.equal(result.profileName, 'Secondary');
	assert.equal(result.profileSwitch.status, 'selected');

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const primaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Primary');
	const secondaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Secondary');

	assert.equal(primaryProfile.selected, false);
	assert(!primaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
	assert(secondaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
	assert(secondaryProfile.devices.some((device) => device.identifiers?.vendor_id === 11427));
	assert.equal(secondaryProfile.selected, true);
});

test('install can clone an existing Karabiner profile into a dedicated profile', async () => {
	const fixture = await createFixture();
	const result = await install(fixture.runtime, {
		profileOptions: {
			profileStrategy: 'clone',
			sourceProfileName: 'Primary',
			newProfileName: 'Primary - DJI Mic Dictation',
		},
	});

	assert.equal(result.profileName, 'Primary - DJI Mic Dictation');

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	assert.equal(karabinerConfig.profiles.length, 3);
	const clonedProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Primary - DJI Mic Dictation');
	assert(clonedProfile.complex_modifications.rules.some((rule) => rule.description === 'keep-me'));
	assert(clonedProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
	assert(clonedProfile.devices.some((device) => device.identifiers?.vendor_id === 11427));
	assert.equal(clonedProfile.selected, true);
});

test('update refreshes manifest version and preserves config', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {
		triggerMode: 'keyboard+dji',
		profileOptions: {
			profileStrategy: 'clone',
			sourceProfileName: 'Primary',
			newProfileName: 'Primary - DJI Mic Dictation',
		},
		configOverrides: { audioFeedbackEnabled: true, preconfirmSoundName: 'Sosumi', readyOverlayEnabled: true },
	});
	const manifestPath = fixture.runtime.manifestFilePath;
	const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf-8'));
	manifest.packageVersion = '0.0.1';
	await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf-8');

	const result = await update(fixture.runtime);
	assert.equal(result.profileName, 'Primary - DJI Mic Dictation');

	const updatedManifest = JSON.parse(await fs.readFile(manifestPath, 'utf-8'));
	assert.equal(updatedManifest.packageVersion, fixture.runtime.packageVersion);
	assert.equal(updatedManifest.profileStrategy, 'existing');
	assert.equal(updatedManifest.triggerMode, 'keyboard+dji');
	assert.deepEqual(await loadConfig(fixture.runtime), {
		audioFeedbackEnabled: true,
		preconfirmSoundName: 'Sosumi',
		readyOverlayEnabled: true,
		reviewWindowSeconds: 3,
	});

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	assert.equal(karabinerConfig.profiles.length, 3);
});

test('update reconciles legacy managed rules even without a manifest', async () => {
	const fixture = await createFixture();
	const template = JSON.parse(await fs.readFile(fixture.runtime.karabinerTemplatePath, 'utf-8'));
	const legacyRule = structuredClone(template.rules[0]);
	legacyRule.description = 'Legacy Fn dictation workflow';

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const primaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Primary');
	primaryProfile.complex_modifications.rules.push(legacyRule);
	primaryProfile.devices.push(structuredClone(MANAGED_DEVICE));
	await fs.writeFile(fixture.karabinerConfigPath, `${JSON.stringify(karabinerConfig, null, 2)}\n`, 'utf-8');

	const result = await update(fixture.runtime);
	assert.equal(result.profileName, 'Primary');
	assert.equal(result.triggerMode, 'keyboard+dji');

	const updatedConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const updatedPrimaryProfile = updatedConfig.profiles.find((profile) => profile.name === 'Primary');
	assert.equal(updatedPrimaryProfile.complex_modifications.rules.filter(ruleUsesManagedScript).length, 1);
	assert(
		updatedPrimaryProfile.complex_modifications.rules.some(
			(rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter',
		),
	);
	assert(
		!updatedPrimaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Legacy Fn dictation workflow'),
	);
});

test('update throws TYPELESS_DB_MISSING when Typeless DB is absent', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {});
	await fs.rm(fixture.runtime.typelessDbPath);

	await assert.rejects(
		() => update(fixture.runtime),
		(error) => {
			assert.equal(error.code, 'TYPELESS_DB_MISSING');
			return true;
		},
	);
});

test('update throws KARABINER_CONFIG_MISSING when Karabiner config is absent', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {});
	await fs.rm(fixture.karabinerConfigPath);

	await assert.rejects(
		() => update(fixture.runtime),
		(error) => {
			assert.equal(error.code, 'KARABINER_CONFIG_MISSING');
			return true;
		},
	);
});

test('install throws KARABINER_CONFIG_MISSING when Karabiner config is absent', async () => {
	const fixture = await createFixture();
	await fs.rm(fixture.karabinerConfigPath);
	await assert.rejects(
		() => install(fixture.runtime, {}),
		(error) => {
			assert.equal(error.code, 'KARABINER_CONFIG_MISSING');
			return true;
		},
	);
});

test('CLI install --json bootstraps Karabiner and waits for config creation', async () => {
	const fixture = await createFixture();
	const brewLogPath = path.join(fixture.tempDir, 'brew.log');
	const openLogPath = path.join(fixture.tempDir, 'open.log');
	const cliTemplatePath = path.join(fixture.tempDir, 'karabiner_cli.template');
	await fs.writeFile(cliTemplatePath, fixture.karabinerCliScript, 'utf-8');
	await fs.rm(fixture.karabinerConfigPath);
	await fs.rm(fixture.karabinerCliPath);
	await writeExecutable(
		path.join(fixture.binDir, 'brew'),
		`#!/bin/sh
printf 'brew\n' >> "$DJI_TEST_BREW_LOG"
mkdir -p "$(dirname "$DJI_KARABINER_CLI")"
cat "$DJI_TEST_KARABINER_CLI_TEMPLATE" > "$DJI_KARABINER_CLI"
chmod +x "$DJI_KARABINER_CLI"
`,
	);
	await writeExecutable(
		path.join(fixture.binDir, 'open'),
		`#!/bin/sh
printf '%s\n' "$*" >> "$DJI_TEST_OPEN_LOG"
if [ "$1" = "-a" ] && [ "$2" = "Karabiner-Elements" ]; then
	mkdir -p "$(dirname "$DJI_TEST_KARABINER_CONFIG_PATH")"
	cat > "$DJI_TEST_KARABINER_CONFIG_PATH" <<'EOF'
${fixture.karabinerConfigText}
EOF
fi
`,
	);
	fixture.env.DJI_TEST_BREW_LOG = brewLogPath;
	fixture.env.DJI_TEST_OPEN_LOG = openLogPath;
	fixture.env.DJI_TEST_KARABINER_CLI_TEMPLATE = cliTemplatePath;
	fixture.env.DJI_TEST_KARABINER_CONFIG_PATH = fixture.karabinerConfigPath;

	const { stdout } = await execFileAsync(
		process.execPath,
		[path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'), 'install', '--yes', '--json'],
		{ env: fixture.env },
	);
	const payload = JSON.parse(stdout);
	assert.equal(payload.ok, true);
	assert.equal(payload.command, 'install');
	assert.equal(payload.result.profileName, 'Primary');
	assert.match(await fs.readFile(brewLogPath, 'utf-8'), /brew/u);
	assert.match(await fs.readFile(openLogPath, 'utf-8'), /Karabiner-Elements/u);
	await fs.access(fixture.karabinerConfigPath);
	await fs.access(fixture.karabinerCliPath);
});

test('CLI install --json returns actionable error when Karabiner config never appears', async () => {
	const fixture = await createFixture();
	const cliTemplatePath = path.join(fixture.tempDir, 'karabiner_cli.template');
	await fs.writeFile(cliTemplatePath, fixture.karabinerCliScript, 'utf-8');
	await fs.rm(fixture.karabinerConfigPath);
	await fs.rm(fixture.karabinerCliPath);
	await writeExecutable(
		path.join(fixture.binDir, 'brew'),
		`#!/bin/sh
mkdir -p "$(dirname "$DJI_KARABINER_CLI")"
cat "$DJI_TEST_KARABINER_CLI_TEMPLATE" > "$DJI_KARABINER_CLI"
chmod +x "$DJI_KARABINER_CLI"
`,
	);
	await writeExecutable(
		path.join(fixture.binDir, 'open'),
		`#!/bin/sh
exit 0
`,
	);
	fixture.env.DJI_TEST_KARABINER_CLI_TEMPLATE = cliTemplatePath;

	await assert.rejects(
		execFileAsync(
			process.execPath,
			[path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'), 'install', '--yes', '--json'],
			{ env: fixture.env },
		),
		(error) => {
			const payload = JSON.parse(error.stdout);
			assert.equal(payload.ok, false);
			assert.equal(payload.code, 'KARABINER_CONFIG_NOT_READY');
			assert.match(payload.error, /Open Karabiner-Elements once/u);
			return true;
		},
	);
});

test('doctor reports update availability and managed installation state', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {});
	const manifestPath = fixture.runtime.manifestFilePath;
	const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf-8'));
	manifest.packageVersion = '0.0.1';
	await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf-8');

	const report = await doctor(fixture.runtime);
	assert.equal(report.installed, true);
	assert.equal(report.updateAvailable, true);
	assert.equal(report.connectedDevice.status, 'connected');
	assert.equal(report.triggerMode, 'keyboard+dji');
	assert.equal(report.managedProfiles[0].name, 'Primary');
	assert.equal(report.profileCurrent, true);
	assert.equal(report.permissions.status, 'ok');
	assert.equal(report.permissions.items.find((item) => item.key === 'dictation')?.status, 'enabled');
});

test('uninstall removes managed files and leaves unrelated Karabiner entries', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, {});

	const result = await uninstall(fixture.runtime);
	assert.equal(result.removedRuleCount, 1);
	assert.equal(result.removedDeviceCount, 1);

	const karabinerConfig = JSON.parse(await fs.readFile(fixture.karabinerConfigPath, 'utf-8'));
	const primaryProfile = karabinerConfig.profiles.find((profile) => profile.name === 'Primary');
	assert(primaryProfile.complex_modifications.rules.some((rule) => rule.description === 'keep-me'));
	assert(!primaryProfile.complex_modifications.rules.some((rule) => rule.description === 'Fn dictation toggle + confirm/preconfirm to send Enter'));
	assert(!primaryProfile.devices.some((device) => device.identifiers?.vendor_id === 11427));
	await assert.rejects(fs.access(fixture.runtime.scriptTargetPath));
	await assert.rejects(fs.access(fixture.runtime.configFilePath));
});

test('uninstall keeps unrelated devices when keyboard-only mode was forced', async () => {
	const fixture = await createFixture();
	await install(fixture.runtime, { triggerMode: 'keyboard' });

	const result = await uninstall(fixture.runtime);
	assert.equal(result.removedRuleCount, 1);
	assert.equal(result.removedDeviceCount, 0);
});

test('CLI config command supports non-interactive JSON output', async () => {
	const fixture = await createFixture();
	const { stdout } = await execFileAsync(
		process.execPath,
		[
			path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'),
			'config',
			'--sound',
			'off',
			'--ready-overlay',
			'off',
			'--json',
		],
		{ env: fixture.env },
	);
	const payload = JSON.parse(stdout);
	assert.equal(payload.ok, true);
	assert.equal(payload.command, 'config');
	assert.equal(payload.result.audioFeedbackEnabled, false);
	assert.equal(payload.result.preconfirmSoundName, '');
	assert.equal(payload.result.readyOverlayEnabled, false);
	const configText = await fs.readFile(fixture.runtime.configFilePath, 'utf-8');
	assert.match(configText, /DJI_ENABLE_READY_HUD=0/u);
});

test('CLI install --json omits dictation and input monitoring permission items', async () => {
	const fixture = await createFixture();
	fixture.env.DJI_PERMISSION_CHECK_JSON = JSON.stringify({
		items: [
			{ key: 'karabinerInputMonitoring', label: 'Karabiner input monitoring', status: 'denied' },
			{ key: 'accessibilityCurrentSession', label: 'Current session accessibility', status: 'granted' },
			{ key: 'postEventCurrentSession', label: 'Current session event posting', status: 'granted' },
			{ key: 'dictation', label: 'macOS Dictation', status: 'disabled' },
		],
	});

	const { stdout } = await execFileAsync(
		process.execPath,
		[path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'), 'install', '--yes', '--json'],
		{ env: fixture.env },
	);
	const payload = JSON.parse(stdout);
	assert.equal(payload.ok, true);
	assert.equal(payload.result.permissions.status, 'ok');
	assert.equal(payload.result.permissions.items.find((item) => item.key === 'dictation'), undefined);
	assert.equal(payload.result.permissions.items.find((item) => item.key === 'karabinerInputMonitoring'), undefined);
});

test('CLI config command supports setting preconfirm sound independently', async () => {
	const fixture = await createFixture();
	const { stdout } = await execFileAsync(
		process.execPath,
		[
			path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'),
			'config',
			'--preconfirm-sound',
			'Frog',
			'--json',
		],
		{ env: fixture.env },
	);
	const payload = JSON.parse(stdout);
	assert.equal(payload.ok, true);
	assert.equal(payload.command, 'config');
	assert.equal(payload.result.audioFeedbackEnabled, true);
	assert.equal(payload.result.preconfirmSoundName, 'Frog');
});

test('CLI config command supports setting review window independently', async () => {
	const fixture = await createFixture();
	const { stdout } = await execFileAsync(
		process.execPath,
		[
			path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'),
			'config',
			'--review-window',
			'4.5',
			'--json',
		],
		{ env: fixture.env },
	);
	const payload = JSON.parse(stdout);
	assert.equal(payload.ok, true);
	assert.equal(payload.command, 'config');
	assert.equal(payload.result.reviewWindowSeconds, 4.5);
	const configText = await fs.readFile(fixture.runtime.configFilePath, 'utf-8');
	assert.match(configText, /DJI_REVIEW_WINDOW_SECONDS=4\.5/u);
});

test('install permission gating ignores dictation and input monitoring', () => {
	const report = {
		status: 'action_required',
		items: [
			{ key: 'karabinerInputMonitoring', status: 'denied' },
			{ key: 'dictation', status: 'disabled' },
			{ key: 'accessibilityCurrentSession', status: 'denied' },
		],
	};

	assert.deepEqual(getBlockingPermissionIssues(report).map((item) => item.key), ['accessibilityCurrentSession']);
	assert.deepEqual(getInstallPermissionReminderIssues(report).map((item) => item.key), ['accessibilityCurrentSession']);
	assert.deepEqual(filterInstallPermissionReport(report), {
		status: 'action_required',
		items: [{ key: 'accessibilityCurrentSession', status: 'denied' }],
	});
});

test('CLI config --sound on restores default preconfirm sound after --sound off', async () => {
	const fixture = await createFixture();
	await execFileAsync(
		process.execPath,
		[path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'), 'config', '--sound', 'off', '--json'],
		{ env: fixture.env },
	);
	const { stdout } = await execFileAsync(
		process.execPath,
		[path.join(fixture.runtime.repoRoot, 'cli', 'index.mjs'), 'config', '--sound', 'on', '--json'],
		{ env: fixture.env },
	);
	const payload = JSON.parse(stdout);
	assert.equal(payload.ok, true);
	assert.equal(payload.result.audioFeedbackEnabled, true);
	assert.equal(payload.result.preconfirmSoundName, 'Sosumi');
});

test('system sounds are discovered from the configured sound directory', async () => {
	const fixture = await createFixture();
	const sounds = await listSystemSounds(fixture.runtime);
	assert.deepEqual(sounds, ['Basso', 'Frog', 'Sosumi', 'Tink']);
});

test('profile prompt plan reuses manifest and shrinks single-profile flows', async () => {
	assert.deepEqual(
		buildInstallProfilePromptPlan({
			profiles: [
				{ name: 'Default profile', selected: true },
				{ name: 'Other profile', selected: false },
			],
			manifest: { profileName: 'Other profile' },
		}),
		{
			kind: 'reuse-installed',
			profileName: 'Other profile',
			profileOptions: {
				profileStrategy: 'existing',
				profileName: 'Other profile',
			},
		},
	);

	assert.deepEqual(
		buildInstallProfilePromptPlan({
			profiles: [{ name: 'Default profile', selected: true }],
		}),
		{
			kind: 'single-profile',
			currentProfileName: 'Default profile',
			defaultCloneName: 'Default profile - DJI Mic Dictation',
			profileOptions: {
				profileStrategy: 'active',
			},
		},
	);

	assert.deepEqual(
		buildInstallProfilePromptPlan({
			profiles: [
				{ name: 'Default profile', selected: true },
				{ name: 'Other profile', selected: false },
			],
		}),
		{
			kind: 'multi-profile',
			activeProfileName: 'Default profile',
		},
	);
});
