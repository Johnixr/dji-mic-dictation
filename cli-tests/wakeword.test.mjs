import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { __testOnly as wakewordTest } from '../cli/lib/wakeword.mjs';

const execFileAsync = promisify(execFile);

async function writeExecutable(filePath, content) {
	await fs.writeFile(filePath, content, 'utf-8');
	await fs.chmod(filePath, 0o755);
}

async function createFixture() {
	const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'dji-wakeword-test-'));
	const homeDir = path.join(tempDir, 'home');
	const binDir = path.join(tempDir, 'bin');
	await fs.mkdir(homeDir, { recursive: true });
	await fs.mkdir(binDir, { recursive: true });

	const recorderPath = path.join(binDir, 'fake-wakeword-recorder');
	await writeExecutable(
		recorderPath,
		`#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
\tcase "$1" in
\t\t--output)
\t\t\toutput="$2"
\t\t\tshift 2
\t\t\t;;
\t\t*)
\t\t\tshift 2
\t\t\t;;
\tesac
done
mkdir -p "$(dirname "$output")"
: > "$output"
printf '{"ok":true,"output_path":"%s","duration_ms":1400}\\n' "$output"
`,
	);

	const toolsPath = path.join(binDir, 'fake-wakeword-tools.py');
	await writeExecutable(
		toolsPath,
		`#!/usr/bin/env python3
import json
import os
import sys

def count_wavs(directory):
\ttotal = 0
\tfor root, _, files in os.walk(directory):
\t\tfor name in files:
\t\t\tif name.lower().endswith(".wav"):
\t\t\t\ttotal += 1
\treturn total

command = sys.argv[1]
if command == "analyze":
\tinput_path = sys.argv[sys.argv.index("--input") + 1]
\tif "/ambient/" in input_path:
\t\tprint(json.dumps({
\t\t\t"active_ratio": 0.0,
\t\t\t"clipped_ratio": 0.0,
\t\t\t"duration_ms": 1400,
\t\t\t"peak_norm": 0.003,
\t\t\t"rms_norm": 0.0015,
\t\t\t"sample_rate_hz": 16000
\t\t}))
\telse:
\t\tprint(json.dumps({
\t\t\t"active_ratio": 0.4,
\t\t\t"clipped_ratio": 0.0,
\t\t\t"duration_ms": 1400,
\t\t\t"peak_norm": 0.2,
\t\t\t"rms_norm": 0.03,
\t\t\t"sample_rate_hz": 16000
\t\t}))
elif command == "summarize":
\tpositive_dir = sys.argv[sys.argv.index("--positive-dir") + 1]
\tcancel_dir = sys.argv[sys.argv.index("--cancel-dir") + 1] if "--cancel-dir" in sys.argv else ""
\tnegative_dir = sys.argv[sys.argv.index("--negative-dir") + 1]
\tphrase = sys.argv[sys.argv.index("--phrase") + 1]
\tcancel_phrase = sys.argv[sys.argv.index("--cancel-phrase") + 1] if "--cancel-phrase" in sys.argv else ""
\tpositive = count_wavs(positive_dir)
\tcancel = count_wavs(cancel_dir) if cancel_dir else 0
\tnegative = count_wavs(negative_dir)
\tprint(json.dumps({
\t\t"backend_engine": "logmel-softmax",
\t\t"calibration_mode": "local-vocal-cue-v4",
\t\t"class_names": ["background", "toggle"] + (["cancel"] if cancel_phrase and cancel else []),
\t\t"class_thresholds": {"toggle": 0.58, "cancel": 0.61 if cancel_phrase and cancel else 0.0},
\t\t"class_margin_min": {"toggle": 0.08, "cancel": 0.09 if cancel_phrase and cancel else 0.0},
\t\t"feature_mean": [0.0, 0.0],
\t\t"feature_scale": [1.0, 1.0],
\t\t"weights": [[0.0, 1.0], [0.0, 1.0]],
\t\t"bias": [0.0, 0.0],
\t\t"prototypes": [[0.0, 0.0], [1.0, 1.0]],
\t\t"distance_threshold": 0.58,
\t\t"listener_start_rms_norm": 0.006,
\t\t"max_phrase_duration_ms": 1600,
\t\t"min_rms_norm": 0.006,
\t\t"min_segment_duration_ms": 180,
\t\t"cancel_count": cancel,
\t\t"cancel_phrase": cancel_phrase,
\t\t"negative_count": negative,
\t\t"negative_margin_min": 0.08,
\t\t"phrase": phrase,
\t\t"positive_count": positive,
\t\t"ready": positive >= 12 and negative >= 9 and (not cancel_phrase or cancel >= 12),
\t\t"recommended_cooldown_ms": 850,
\t\t"sample_rate_hz": 16000,
\t\t"summary": {"toggle_threshold": 0.58}
\t}))
else:
\traise SystemExit(f"unknown command: {command}")
`,
	);

	const listenerPath = path.join(binDir, 'fake-wakeword-listener');
	await writeExecutable(
		listenerPath,
		`#!/bin/sh
printf '{"status":"listening"}\\n'
trap 'exit 0' TERM INT
while :; do
\tsleep 1
done
`,
	);

	const env = {
		...process.env,
		DJI_INSTALLER_HOME: homeDir,
		DJI_WAKEWORD_RECORDER_BIN: recorderPath,
		DJI_WAKEWORD_LISTENER_BIN: listenerPath,
		DJI_WAKEWORD_TOOLS: toolsPath,
	};

	return { env, homeDir, tempDir };
}

test('CLI wakeword setup records samples, trains calibration, and reports ready status', async () => {
	const fixture = await createFixture();

	const { stdout } = await execFileAsync(
		'node',
		['cli/index.mjs', 'wakeword', '--phrase', 'dragon dragon', '--json'],
		{
			cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
			env: fixture.env,
		},
	);
	const parsed = JSON.parse(stdout);
	assert.equal(parsed.ok, true);
	assert.equal(parsed.command, 'wakeword');
	assert.equal(parsed.result.subcommand, 'setup');
	assert.equal(parsed.result.record.config.phrase, 'dragon dragon');
	assert.equal(parsed.result.record.config.positiveSampleCount, 12);
	assert.equal(parsed.result.record.config.cancelSampleCount, 0);
	assert.equal(parsed.result.record.config.negativeSampleCount, 9);
	assert.equal(parsed.result.train.summary.ready, true);

	const configPath = path.join(fixture.homeDir, '.config', 'dji-mic-dictation', 'wakeword', 'config.json');
	const calibrationPath = path.join(fixture.homeDir, '.config', 'dji-mic-dictation', 'wakeword', 'calibration.json');
	const config = JSON.parse(await fs.readFile(configPath, 'utf-8'));
	assert.equal(config.trainingReady, true);
	assert.equal(config.positiveSampleCount, 12);
	assert.equal(config.cancelSampleCount, 0);
	assert.equal(config.negativeSampleCount, 9);
	assert.equal(JSON.parse(await fs.readFile(calibrationPath, 'utf-8')).ready, true);

	const doctorResult = await execFileAsync(
		'node',
		['cli/index.mjs', 'wakeword', 'doctor', '--json'],
		{
			cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
			env: fixture.env,
		},
	);
	const doctor = JSON.parse(doctorResult.stdout);
	assert.equal(doctor.ok, true);
	assert.equal(doctor.result.trainingReady, true);
	assert.equal(doctor.result.positiveSampleCount, 12);
	assert.equal(doctor.result.cancelSampleCount, 0);
	assert.equal(doctor.result.negativeSampleCount, 9);
});

test('CLI wakeword setup with cancel cue records one shared negative set', async () => {
	const fixture = await createFixture();

	const { stdout } = await execFileAsync(
		'node',
		['cli/index.mjs', 'wakeword', '--phrase', 'double hiss', '--cancel-cue', 'double puff', '--json'],
		{
			cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
			env: fixture.env,
		},
	);
	const parsed = JSON.parse(stdout);
	assert.equal(parsed.ok, true);
	assert.equal(parsed.result.subcommand, 'setup');
	assert.equal(parsed.result.record.config.phrase, 'double hiss');
	assert.equal(parsed.result.record.config.cancelPhrase, 'double puff');
	assert.equal(parsed.result.record.config.positiveSampleCount, 12);
	assert.equal(parsed.result.record.config.cancelSampleCount, 12);
	assert.equal(parsed.result.record.config.negativeSampleCount, 9);
	assert.equal(parsed.result.train.summary.ready, true);
	assert.deepEqual(parsed.result.train.summary.class_names, ['background', 'toggle', 'cancel']);
});

test('CLI wakeword listener start/status/stop manages the background process', async () => {
	const fixture = await createFixture();

	await execFileAsync('node', ['cli/index.mjs', 'wakeword', '--phrase', 'dragon dragon', '--json'], {
		cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
		env: fixture.env,
	});

	const started = JSON.parse(
		(
			await execFileAsync('node', ['cli/index.mjs', 'wakeword', 'start', '--json'], {
				cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
				env: fixture.env,
			})
		).stdout,
	);
	assert.equal(started.ok, true);
	assert.equal(started.result.subcommand, 'start');
	assert.equal(started.result.alreadyRunning, false);
	assert.ok(Number.isInteger(started.result.pid));

	const status = JSON.parse(
		(
			await execFileAsync('node', ['cli/index.mjs', 'wakeword', 'status', '--json'], {
				cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
				env: fixture.env,
			})
		).stdout,
	);
	assert.equal(status.ok, true);
	assert.equal(status.result.subcommand, 'status');
	assert.equal(status.result.running, true);
	assert.equal(status.result.pid, started.result.pid);

	const stopped = JSON.parse(
		(
			await execFileAsync('node', ['cli/index.mjs', 'wakeword', 'stop', '--json'], {
				cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
				env: fixture.env,
			})
		).stdout,
	);
	assert.equal(stopped.ok, true);
	assert.equal(stopped.result.subcommand, 'stop');
	assert.equal(stopped.result.stopped, true);
});

test('CLI wakeword record resumes from accepted phase samples already on disk', async () => {
	const fixture = await createFixture();
	const wakewordDir = path.join(fixture.homeDir, '.config', 'dji-mic-dictation', 'wakeword');
	const softDir = path.join(wakewordDir, 'samples', 'positive', 'soft');
	const naturalDir = path.join(wakewordDir, 'samples', 'positive', 'natural');
	await fs.mkdir(softDir, { recursive: true });
	await fs.mkdir(naturalDir, { recursive: true });
	for (let index = 1; index <= 4; index += 1) {
		await fs.writeFile(path.join(softDir, `seed-soft-${index}.wav`), '', 'utf-8');
	}
	for (let index = 1; index <= 2; index += 1) {
		await fs.writeFile(path.join(naturalDir, `seed-natural-${index}.wav`), '', 'utf-8');
	}

	const { stdout } = await execFileAsync(
		'node',
		['cli/index.mjs', 'wakeword', 'record', '--phrase', 'dragon dragon', '--json'],
		{
			cwd: '/Users/john/workspace/claude_code/my/dji-mic-dictation',
			env: fixture.env,
		},
	);
	const parsed = JSON.parse(stdout);
	assert.equal(parsed.ok, true);
	assert.equal(parsed.result.subcommand, 'record');
	assert.equal(parsed.result.config.positiveSampleCount, 12);
	assert.equal(parsed.result.config.negativeSampleCount, 9);
});

test('Low voice enrollment accepts quieter clips without relaxing normal phases', () => {
	const quietButUsableClip = {
		active_ratio: 0.045,
		clipped_ratio: 0.0,
		duration_ms: 1350,
		peak_norm: 0.014,
		rms_norm: 0.0036,
		sample_rate_hz: 16000,
	};

	assert.equal(wakewordTest.evaluateClipAnalysis({ id: 'soft' }, quietButUsableClip).accepted, true);
	assert.equal(wakewordTest.evaluateClipAnalysis({ id: 'natural' }, quietButUsableClip).accepted, false);
	assert.equal(
		wakewordTest.evaluateClipAnalysis(
			{ id: 'soft' },
			{
				...quietButUsableClip,
				active_ratio: 0.012,
				peak_norm: 0.004,
				rms_norm: 0.0018,
			},
		).accepted,
		false,
	);
	assert.equal(
		wakewordTest.evaluateClipAnalysis(
			{ id: 'ambient', role: 'negative' },
			{
				...quietButUsableClip,
				active_ratio: 0.24,
				peak_norm: 0.18,
				rms_norm: 0.022,
			},
		).accepted,
		false,
	);
});
