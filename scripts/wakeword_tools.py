#!/usr/bin/env python3

import argparse
import json
import math
import os
import random
import statistics
import sys
import wave
from array import array

try:
	import numpy as np
except ImportError as error:  # pragma: no cover - runtime environment guard
	raise SystemExit(
		"wakeword_tools.py requires numpy. Install it with `python3 -m pip install numpy` and rerun wakeword training."
	) from error


TARGET_SAMPLE_RATE_HZ = 16_000
FRAME_LENGTH = 400
HOP_LENGTH = 160
N_FFT = 512
N_MELS = 40
FEATURE_FRAMES = 48
MEL_LOW_HZ = 20.0
MEL_HIGH_HZ = 7_600.0
EPSILON = 1e-6
SOFTMAX_EPOCHS = 320
SOFTMAX_LR = 0.18
SOFTMAX_WEIGHT_DECAY = 8e-4
PROTOTYPE_TEMPERATURE = 6.0
SOFTMAX_BLEND = 0.64
PROTOTYPE_BLEND = 0.36
POSITIVE_AUGMENTATION_COUNT = 10
BACKGROUND_AUGMENTATION_COUNT = 4
CALIBRATION_AUGMENTATION_COUNT = 2
TIME_MASK_COUNT = 2
TIME_MASK_MAX_FRAMES = 6
FREQ_MASK_COUNT = 2
FREQ_MASK_MAX_BANDS = 5

_MEL_FILTERBANK_CACHE = {}


def _read_wav(path):
	with wave.open(path, "rb") as wav_file:
		sample_rate_hz = wav_file.getframerate()
		sample_width = wav_file.getsampwidth()
		channel_count = wav_file.getnchannels()
		frame_count = wav_file.getnframes()
		raw = wav_file.readframes(frame_count)

	if sample_width != 2:
		raise ValueError(f"Only 16-bit PCM WAV is supported: {path}")

	samples = array("h")
	samples.frombytes(raw)
	if channel_count > 1:
		mono = array("h")
		for index in range(0, len(samples), channel_count):
			frame = samples[index : index + channel_count]
			mono.append(int(sum(frame) / len(frame)))
		samples = mono

	return sample_rate_hz, samples


def _iter_wavs(directory):
	if not directory or not os.path.isdir(directory):
		return []

	results = []
	for root, _, files in os.walk(directory):
		for name in sorted(files):
			if name.lower().endswith(".wav"):
				results.append(os.path.join(root, name))
	return results


def _median(values, fallback=0.0):
	return statistics.median(values) if values else fallback


def _quantile(values, fraction, fallback=0.0):
	if not values:
		return fallback
	if len(values) == 1:
		return values[0]
	ordered = sorted(values)
	position = max(0.0, min(1.0, fraction)) * (len(ordered) - 1)
	lower = math.floor(position)
	upper = math.ceil(position)
	if lower == upper:
		return ordered[lower]
	weight = position - lower
	return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def _resample_int16(samples, sample_rate_hz, target_sample_rate_hz=TARGET_SAMPLE_RATE_HZ):
	if sample_rate_hz == target_sample_rate_hz:
		return np.asarray(samples, dtype=np.float32)
	if not samples:
		return np.asarray([], dtype=np.float32)
	source = np.asarray(samples, dtype=np.float32)
	source_positions = np.arange(len(source), dtype=np.float32)
	target_length = max(1, int(round(len(source) * (target_sample_rate_hz / sample_rate_hz))))
	target_positions = np.linspace(0.0, len(source) - 1, num=target_length, dtype=np.float32)
	return np.interp(target_positions, source_positions, source).astype(np.float32)


def _normalize_float_samples(samples):
	return np.asarray(samples, dtype=np.float32) / 32768.0


def _trim_active_region(samples):
	if samples.size == 0:
		return samples.copy()
	abs_samples = np.abs(samples)
	peak = float(np.max(abs_samples))
	if peak <= 0.0:
		return samples.copy()
	threshold = max(0.010, peak * 0.14)
	active = np.flatnonzero(abs_samples >= threshold)
	if active.size == 0:
		return samples.copy()
	padding = int(TARGET_SAMPLE_RATE_HZ * 0.08)
	start = max(0, int(active[0]) - padding)
	end = min(len(samples), int(active[-1]) + padding + 1)
	return samples[start:end].copy()


def _frame_waveform(samples):
	if samples.size == 0:
		return np.zeros((1, FRAME_LENGTH), dtype=np.float32)
	frame_count = 1
	if samples.size > FRAME_LENGTH:
		frame_count = 1 + int(math.ceil((samples.size - FRAME_LENGTH) / HOP_LENGTH))
	total_length = FRAME_LENGTH + ((frame_count - 1) * HOP_LENGTH)
	if total_length > samples.size:
		samples = np.pad(samples, (0, total_length - samples.size))
	frames = [samples[offset : offset + FRAME_LENGTH] for offset in range(0, total_length - FRAME_LENGTH + 1, HOP_LENGTH)]
	return np.stack(frames).astype(np.float32)


def _hz_to_mel(values):
	return 2595.0 * np.log10(1.0 + (values / 700.0))


def _mel_to_hz(values):
	return 700.0 * (np.power(10.0, values / 2595.0) - 1.0)


def _mel_filterbank():
	cache_key = (TARGET_SAMPLE_RATE_HZ, N_FFT, N_MELS, MEL_LOW_HZ, MEL_HIGH_HZ)
	if cache_key in _MEL_FILTERBANK_CACHE:
		return _MEL_FILTERBANK_CACHE[cache_key]

	mel_points = np.linspace(_hz_to_mel(np.array([MEL_LOW_HZ]))[0], _hz_to_mel(np.array([MEL_HIGH_HZ]))[0], N_MELS + 2)
	hz_points = _mel_to_hz(mel_points)
	bins = np.floor(((N_FFT + 1) * hz_points) / TARGET_SAMPLE_RATE_HZ).astype(int)
	filterbank = np.zeros((N_MELS, (N_FFT // 2) + 1), dtype=np.float32)

	for mel_index in range(1, N_MELS + 1):
		left = int(bins[mel_index - 1])
		center = int(bins[mel_index])
		right = int(bins[mel_index + 1])
		if center <= left:
			center = left + 1
		if right <= center:
			right = center + 1
		for fft_index in range(left, min(center, filterbank.shape[1])):
			filterbank[mel_index - 1, fft_index] = (fft_index - left) / max(1, center - left)
		for fft_index in range(center, min(right, filterbank.shape[1])):
			filterbank[mel_index - 1, fft_index] = (right - fft_index) / max(1, right - center)

	_MEL_FILTERBANK_CACHE[cache_key] = filterbank
	return filterbank


def _resize_time_axis(matrix, frame_count=FEATURE_FRAMES):
	if matrix.shape[1] == frame_count:
		return matrix.astype(np.float32)
	if matrix.shape[1] <= 1:
		return np.repeat(matrix, frame_count, axis=1).astype(np.float32)

	source_positions = np.linspace(0.0, 1.0, num=matrix.shape[1], dtype=np.float32)
	target_positions = np.linspace(0.0, 1.0, num=frame_count, dtype=np.float32)
	resized = np.empty((matrix.shape[0], frame_count), dtype=np.float32)
	for row_index in range(matrix.shape[0]):
		resized[row_index] = np.interp(target_positions, source_positions, matrix[row_index]).astype(np.float32)
	return resized


def _waveform_to_feature_matrix(samples):
	if samples.size == 0:
		samples = np.zeros(FRAME_LENGTH, dtype=np.float32)
	frames = _frame_waveform(samples)
	window = np.hanning(FRAME_LENGTH).astype(np.float32)
	windowed = frames * window
	spectrum = np.fft.rfft(windowed, n=N_FFT, axis=1)
	power = (np.abs(spectrum) ** 2).astype(np.float32)
	mel = _mel_filterbank() @ power.T
	log_mel = np.log(np.maximum(mel, EPSILON)).astype(np.float32)
	log_mel -= np.mean(log_mel, axis=1, keepdims=True)
	log_mel /= np.maximum(np.std(log_mel, axis=1, keepdims=True), 1e-4)
	delta = np.diff(log_mel, axis=1, prepend=log_mel[:, :1])
	combined = np.concatenate([log_mel, delta], axis=0)
	return _resize_time_axis(combined)


def _resample_float_waveform(samples, target_length):
	if samples.size == 0:
		return np.zeros(max(1, int(target_length)), dtype=np.float32)
	if target_length <= 1:
		return np.asarray([samples[0]], dtype=np.float32)
	source_positions = np.linspace(0.0, 1.0, num=samples.size, dtype=np.float32)
	target_positions = np.linspace(0.0, 1.0, num=int(target_length), dtype=np.float32)
	return np.interp(target_positions, source_positions, samples).astype(np.float32)


def _apply_time_shift(samples, shift):
	if samples.size == 0 or shift == 0:
		return samples
	if shift > 0:
		padding = np.zeros(shift, dtype=np.float32)
		return np.concatenate([padding, samples])[: samples.size]
	shift = abs(shift)
	padding = np.zeros(shift, dtype=np.float32)
	return np.concatenate([samples[shift:], padding])


def _background_overlay(background_bank, target_length, rng):
	if not background_bank:
		return np.zeros(target_length, dtype=np.float32)
	source = np.asarray(background_bank[rng.integers(0, len(background_bank))], dtype=np.float32)
	if source.size == 0:
		return np.zeros(target_length, dtype=np.float32)
	if source.size < target_length:
		repeats = int(math.ceil(target_length / max(source.size, 1)))
		source = np.tile(source, repeats)
	start = int(rng.integers(0, max(1, source.size - target_length + 1)))
	segment = source[start : start + target_length].astype(np.float32)
	if segment.size < target_length:
		segment = np.pad(segment, (0, target_length - segment.size))
	return segment


def _mix_with_background(samples, background_bank, rng, positive):
	if not background_bank or samples.size == 0:
		return samples
	overlay = _background_overlay(background_bank, samples.size, rng)
	overlay_rms = float(np.sqrt(np.mean(overlay * overlay))) if overlay.size else 0.0
	signal_rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
	if overlay_rms <= 1e-5 or signal_rms <= 1e-5:
		return samples
	snr_db = rng.uniform(9.0, 20.0) if positive else rng.uniform(1.5, 10.0)
	target_overlay_rms = signal_rms / (10 ** (snr_db / 20.0))
	scaled_overlay = overlay * (target_overlay_rms / overlay_rms)
	return np.clip(samples + scaled_overlay.astype(np.float32), -1.0, 1.0)


def _augment_feature_matrix(matrix, seed, positive):
	rng = np.random.default_rng(seed)
	augmented = np.asarray(matrix, dtype=np.float32).copy()
	for _ in range(TIME_MASK_COUNT):
		max_width = min(TIME_MASK_MAX_FRAMES if positive else TIME_MASK_MAX_FRAMES - 2, augmented.shape[1] - 1)
		if max_width <= 1:
			continue
		width = int(rng.integers(1, max_width + 1))
		start = int(rng.integers(0, max(1, augmented.shape[1] - width + 1)))
		augmented[:, start : start + width] *= rng.uniform(0.0, 0.18)
	for _ in range(FREQ_MASK_COUNT):
		max_width = min(FREQ_MASK_MAX_BANDS if positive else FREQ_MASK_MAX_BANDS - 1, augmented.shape[0] - 1)
		if max_width <= 1:
			continue
		width = int(rng.integers(1, max_width + 1))
		start = int(rng.integers(0, max(1, augmented.shape[0] - width + 1)))
		augmented[start : start + width, :] *= rng.uniform(0.0, 0.22)
	return augmented


def _augment_waveform(samples, seed, positive, background_bank=None):
	rng = np.random.default_rng(seed)
	output = np.asarray(samples, dtype=np.float32).copy()
	if output.size == 0:
		return output
	stretch = rng.uniform(0.86, 1.14) if positive else rng.uniform(0.92, 1.08)
	target_length = max(64, int(round(output.size * stretch)))
	output = _resample_float_waveform(output, target_length)
	shift = int(round(output.size * rng.uniform(-0.08, 0.08)))
	output = _apply_time_shift(output, shift)
	output *= rng.uniform(0.68, 1.34) if positive else rng.uniform(0.78, 1.22)
	output = _mix_with_background(output, background_bank, rng, positive)
	output += rng.normal(0.0, 0.0036 if positive else 0.0022, size=output.shape).astype(np.float32)
	drift = rng.normal(0.0, 0.0015 if positive else 0.001, size=output.shape).astype(np.float32)
	drift = np.cumsum(drift)
	drift /= max(float(np.max(np.abs(drift))), 1.0)
	output += drift * (0.0028 if positive else 0.0014)
	return np.clip(output, -1.0, 1.0)


def analyze_wav(path):
	sample_rate_hz, samples = _read_wav(path)
	total_samples = len(samples)
	if total_samples == 0:
		raise ValueError(f"Empty WAV file: {path}")

	abs_samples = [abs(sample) for sample in samples]
	peak = max(abs_samples)
	rms = math.sqrt(sum(sample * sample for sample in samples) / total_samples)
	peak_norm = peak / 32768.0
	rms_norm = rms / 32768.0

	activity_threshold = max(250, int(max(peak * 0.12, 400)))
	active_samples = sum(1 for sample in abs_samples if sample >= activity_threshold)
	clipped_samples = sum(1 for sample in abs_samples if sample >= 32760)
	active_ratio = active_samples / total_samples
	clipped_ratio = clipped_samples / total_samples
	duration_ms = round((total_samples / sample_rate_hz) * 1000.0, 2)
	crest_factor = peak_norm / max(rms_norm, 1e-6)

	return {
		"active_ratio": round(active_ratio, 6),
		"clipped_ratio": round(clipped_ratio, 6),
		"crest_factor": round(crest_factor, 6),
		"duration_ms": duration_ms,
		"file_path": os.path.abspath(path),
		"peak_norm": round(peak_norm, 6),
		"rms_norm": round(rms_norm, 6),
		"sample_count": total_samples,
		"sample_rate_hz": sample_rate_hz,
	}


def extract_sample(path):
	sample_rate_hz, pcm_samples = _read_wav(path)
	float_samples = _normalize_float_samples(_resample_int16(pcm_samples, sample_rate_hz))
	trimmed = _trim_active_region(float_samples)
	analysis = analyze_wav(path)
	duration_ms = round((len(trimmed) / TARGET_SAMPLE_RATE_HZ) * 1000.0, 2) if trimmed.size else 0.0
	trimmed_rms_norm = float(np.sqrt(np.mean(trimmed * trimmed))) if trimmed.size else 0.0
	trimmed_peak_norm = float(np.max(np.abs(trimmed))) if trimmed.size else 0.0
	feature_matrix = _waveform_to_feature_matrix(trimmed)
	return {
		"analysis": analysis,
		"duration_ms": duration_ms or analysis["duration_ms"],
		"feature_matrix": feature_matrix,
		"feature_vector": feature_matrix.reshape(-1).astype(np.float32),
		"file_path": os.path.abspath(path),
		"trimmed_peak_norm": round(trimmed_peak_norm, 6),
		"trimmed_rms_norm": round(trimmed_rms_norm, 6),
		"trimmed_samples": trimmed.astype(np.float32),
	}


def _load_sample_set(paths, label_name):
	samples = []
	skipped = []
	for file_path in paths:
		try:
			sample = extract_sample(file_path)
		except Exception as error:  # noqa: BLE001
			skipped.append({"file_path": os.path.abspath(file_path), "reason": str(error)})
			continue
		sample["label_name"] = label_name
		samples.append(sample)
	return samples, skipped


def _build_training_matrix(samples_by_label, class_names):
	features = []
	labels = []
	rng = random.Random(7)
	background_bank = [sample["trimmed_samples"] for sample in samples_by_label.get("background", []) if sample["trimmed_samples"].size > 0]
	for label_name, samples in samples_by_label.items():
		label_index = class_names.index(label_name)
		for sample in samples:
			features.append(sample["feature_vector"])
			labels.append(label_index)
			augmentation_count = POSITIVE_AUGMENTATION_COUNT if label_name != "background" else BACKGROUND_AUGMENTATION_COUNT
			for _ in range(augmentation_count):
				augmented = _augment_waveform(
					sample["trimmed_samples"],
					rng.randint(0, 1_000_000),
					positive=label_name != "background",
					background_bank=background_bank,
				)
				augmented_matrix = _augment_feature_matrix(
					_waveform_to_feature_matrix(augmented),
					rng.randint(0, 1_000_000),
					positive=label_name != "background",
				)
				features.append(augmented_matrix.reshape(-1).astype(np.float32))
				labels.append(label_index)
	return np.stack(features).astype(np.float32), np.asarray(labels, dtype=np.int64)


def _softmax(logits):
	logits = logits - np.max(logits, axis=1, keepdims=True)
	exp = np.exp(logits).astype(np.float32)
	return exp / np.maximum(np.sum(exp, axis=1, keepdims=True), EPSILON)


def _train_softmax_classifier(features, labels, class_count):
	feature_mean = np.mean(features, axis=0).astype(np.float32)
	feature_scale = np.std(features, axis=0).astype(np.float32)
	feature_scale[feature_scale < 1e-4] = 1.0
	normalized = ((features - feature_mean) / feature_scale).astype(np.float32)

	weights = np.zeros((normalized.shape[1], class_count), dtype=np.float32)
	bias = np.zeros(class_count, dtype=np.float32)
	class_counts = np.bincount(labels, minlength=class_count).astype(np.float32)
	class_weights = np.ones(class_count, dtype=np.float32)
	nonzero = class_counts > 0
	class_weights[nonzero] = len(labels) / (class_count * class_counts[nonzero])
	targets = np.eye(class_count, dtype=np.float32)[labels]

	for epoch in range(SOFTMAX_EPOCHS):
		logits = normalized @ weights + bias
		probabilities = _softmax(logits)
		error = (probabilities - targets) * class_weights[labels][:, None]
		lr = SOFTMAX_LR * (0.985 ** (epoch / 24.0))
		grad_weights = (normalized.T @ error) / len(normalized)
		grad_weights += SOFTMAX_WEIGHT_DECAY * weights
		grad_bias = np.mean(error, axis=0)
		weights -= lr * grad_weights
		bias -= lr * grad_bias

	return feature_mean, feature_scale, weights, bias


def _compute_prototypes(samples_by_label, class_names, feature_mean, feature_scale):
	prototypes = []
	for label_name in class_names:
		samples = samples_by_label.get(label_name, [])
		if not samples:
			prototypes.append(np.zeros_like(feature_mean, dtype=np.float32))
			continue
		stack = np.stack([sample["feature_vector"] for sample in samples]).astype(np.float32)
		normalized = (stack - feature_mean) / feature_scale
		prototype = np.mean(normalized, axis=0).astype(np.float32)
		prototypes.append(prototype)
	return np.stack(prototypes).astype(np.float32)


def _model_scores(feature_vector, model):
	feature_mean = np.asarray(model["feature_mean"], dtype=np.float32)
	feature_scale = np.asarray(model["feature_scale"], dtype=np.float32)
	weights = np.asarray(model["weights"], dtype=np.float32)
	bias = np.asarray(model["bias"], dtype=np.float32)
	prototypes = np.asarray(model["prototypes"], dtype=np.float32)
	normalized = ((np.asarray(feature_vector, dtype=np.float32) - feature_mean) / feature_scale).astype(np.float32)
	logits = (normalized @ weights) + bias
	softmax_scores = _softmax(logits.reshape(1, -1))[0]
	prototype_norms = np.linalg.norm(prototypes, axis=1) * max(np.linalg.norm(normalized), EPSILON)
	cosine = np.divide(prototypes @ normalized, np.maximum(prototype_norms, EPSILON))
	prototype_scores = _softmax((cosine * PROTOTYPE_TEMPERATURE).reshape(1, -1))[0]
	combined_scores = (softmax_scores * SOFTMAX_BLEND) + (prototype_scores * PROTOTYPE_BLEND)
	return combined_scores, softmax_scores, prototype_scores


def _calibrate_class_thresholds(samples_by_label, class_names, model):
	class_thresholds = {}
	class_margin_min = {}
	all_samples = []
	background_bank = [sample["trimmed_samples"] for sample in samples_by_label.get("background", []) if sample["trimmed_samples"].size > 0]
	rng = random.Random(19)
	for label_name, samples in samples_by_label.items():
		for sample in samples:
			all_samples.append((label_name, sample))

	for class_name in class_names:
		if class_name == "background":
			continue
		class_index = class_names.index(class_name)
		positive_scores = []
		negative_scores = []
		positive_margins = []
		negative_margins = []
		for label_name, sample in all_samples:
			feature_vectors = [sample["feature_vector"]]
			augmentation_count = CALIBRATION_AUGMENTATION_COUNT if label_name != "background" else 1
			for _ in range(augmentation_count):
				augmented_waveform = _augment_waveform(
					sample["trimmed_samples"],
					rng.randint(0, 1_000_000),
					positive=label_name != "background",
					background_bank=background_bank,
				)
				augmented_matrix = _augment_feature_matrix(
					_waveform_to_feature_matrix(augmented_waveform),
					rng.randint(0, 1_000_000),
					positive=label_name != "background",
				)
				feature_vectors.append(augmented_matrix.reshape(-1).astype(np.float32))
			for feature_vector in feature_vectors:
				combined_scores, _, _ = _model_scores(feature_vector, model)
				ranked = np.sort(combined_scores)
				margin = float(ranked[-1] - ranked[-2]) if ranked.size >= 2 else float(ranked[-1])
				score = float(combined_scores[class_index])
				if label_name == class_name:
					positive_scores.append(score)
					positive_margins.append(margin)
				else:
					negative_scores.append(score)
					negative_margins.append(margin)

		positive_floor = _quantile(positive_scores, 0.08, 0.72)
		negative_ceiling = _quantile(negative_scores, 0.97, 0.28)
		threshold = max(0.40, min(0.72, positive_floor * 0.86))
		threshold = max(threshold, negative_ceiling + 0.08)
		threshold = min(threshold, max(positive_floor * 0.97, 0.40))
		class_thresholds[class_name] = round(float(threshold), 6)

		positive_margin_floor = _quantile(positive_margins, 0.08, 0.18)
		negative_margin_ceiling = _quantile(negative_margins, 0.97, 0.02)
		margin_threshold = max(0.035, min(0.20, (positive_margin_floor + negative_margin_ceiling) / 2.0))
		margin_threshold = min(margin_threshold, max(positive_margin_floor * 0.96, 0.05))
		class_margin_min[class_name] = round(float(margin_threshold), 6)

	return class_thresholds, class_margin_min


def _collect_class_score_profiles(samples_by_label, class_names, model):
	profiles = {
		class_name: {
			"combined": [],
			"prototype": [],
			"margin": [],
			"rival_gap": [],
		}
		for class_name in class_names
		if class_name != "background"
	}
	background_bank = [sample["trimmed_samples"] for sample in samples_by_label.get("background", []) if sample["trimmed_samples"].size > 0]
	rng = random.Random(29)
	for class_name, samples in samples_by_label.items():
		if class_name == "background":
			continue
		class_index = class_names.index(class_name)
		rival_name = "cancel" if class_name == "toggle" else "toggle" if class_name == "cancel" else None
		rival_index = class_names.index(rival_name) if rival_name in class_names else None
		for sample in samples:
			feature_vectors = [sample["feature_vector"]]
			for _ in range(CALIBRATION_AUGMENTATION_COUNT):
				augmented_waveform = _augment_waveform(
					sample["trimmed_samples"],
					rng.randint(0, 1_000_000),
					positive=True,
					background_bank=background_bank,
				)
				augmented_matrix = _augment_feature_matrix(
					_waveform_to_feature_matrix(augmented_waveform),
					rng.randint(0, 1_000_000),
					positive=True,
				)
				feature_vectors.append(augmented_matrix.reshape(-1).astype(np.float32))
			for feature_vector in feature_vectors:
				combined_scores, _, prototype_scores = _model_scores(feature_vector, model)
				ranked = np.sort(combined_scores)
				margin = float(ranked[-1] - ranked[-2]) if ranked.size >= 2 else float(ranked[-1])
				profiles[class_name]["combined"].append(float(combined_scores[class_index]))
				profiles[class_name]["prototype"].append(float(prototype_scores[class_index]))
				profiles[class_name]["margin"].append(margin)
				if rival_index is not None:
					profiles[class_name]["rival_gap"].append(float(combined_scores[class_index] - combined_scores[rival_index]))
	return profiles


def _derive_runtime_hardening(profiles, class_thresholds, quiet_positive_rms, listener_start_rms_norm, min_rms_norm):
	toggle_scores = profiles.get("toggle", {}).get("combined", [])
	toggle_prototypes = profiles.get("toggle", {}).get("prototype", [])
	toggle_rival_gaps = profiles.get("toggle", {}).get("rival_gap", [])
	all_rival_gaps = []
	for class_name in ("toggle", "cancel"):
		all_rival_gaps.extend(profiles.get(class_name, {}).get("rival_gap", []))

	toggle_positive_floor = _quantile(toggle_scores, 0.1, class_thresholds.get("toggle", 0.72))
	idle_toggle_score_threshold = max(
		0.66,
		float(class_thresholds.get("toggle", 0.5)) + 0.08,
		toggle_positive_floor * 0.94,
	)
	idle_toggle_score_threshold = min(idle_toggle_score_threshold, max(toggle_positive_floor * 0.99, 0.66))

	toggle_prototype_floor = _quantile(toggle_prototypes, 0.1, 0.22)
	idle_toggle_prototype_threshold = max(0.14, min(0.68, toggle_prototype_floor * 0.74))
	idle_toggle_prototype_threshold = min(idle_toggle_prototype_threshold, max(toggle_prototype_floor * 0.96, 0.14))

	active_gap_floor = _quantile(all_rival_gaps, 0.08, 0.52)
	active_cue_gap_min = max(0.28, min(0.62, active_gap_floor * 0.58))

	toggle_gap_floor = _quantile(toggle_rival_gaps, 0.1, 0.6)
	idle_toggle_rival_gap_min = max(0.44, min(0.82, toggle_gap_floor * 0.8))

	idle_listener_start_rms_norm = max(
		0.0105,
		float(listener_start_rms_norm) * 1.22,
		float(min_rms_norm) * 1.55,
		float(quiet_positive_rms) * 0.42,
	)

	return {
		"idle_listener_start_rms_norm": round(float(idle_listener_start_rms_norm), 6),
		"idle_start_chunk_count": 2,
		"idle_toggle_prototype_threshold": round(float(idle_toggle_prototype_threshold), 6),
		"idle_toggle_rival_gap_min": round(float(idle_toggle_rival_gap_min), 6),
		"idle_toggle_score_threshold": round(float(idle_toggle_score_threshold), 6),
		"active_cue_gap_min": round(float(active_cue_gap_min), 6),
	}


def summarize_samples(phrase, positive_dir, negative_dir, cancel_dir=None, cancel_phrase=""):
	toggle_files = _iter_wavs(positive_dir)
	cancel_files = _iter_wavs(cancel_dir) if cancel_dir else []
	negative_files = _iter_wavs(negative_dir)

	toggle_samples, toggle_skipped = _load_sample_set(toggle_files, "toggle")
	cancel_samples, cancel_skipped = _load_sample_set(cancel_files, "cancel")
	negative_samples, negative_skipped = _load_sample_set(negative_files, "background")
	skipped_invalid_files = toggle_skipped + cancel_skipped + negative_skipped

	class_names = ["background", "toggle"]
	samples_by_label = {
		"background": negative_samples,
		"toggle": toggle_samples,
	}
	if cancel_phrase and cancel_samples:
		class_names.append("cancel")
		samples_by_label["cancel"] = cancel_samples

	positive_rms = [sample["trimmed_rms_norm"] for sample in toggle_samples + cancel_samples]
	positive_duration = [sample["duration_ms"] for sample in toggle_samples + cancel_samples]
	negative_rms = [sample["trimmed_rms_norm"] for sample in negative_samples]

	ready = len(toggle_samples) >= 12 and len(negative_samples) >= 9 and (not cancel_phrase or len(cancel_samples) >= 12)

	if not toggle_samples:
		return {
			"backend_engine": "logmel-softmax",
			"calibration_mode": "local-vocal-cue-v4",
			"phrase": phrase,
			"cancel_phrase": cancel_phrase or "",
			"positive_count": 0,
			"cancel_count": len(cancel_samples),
			"negative_count": len(negative_samples),
			"ready": False,
			"sample_rate_hz": TARGET_SAMPLE_RATE_HZ,
			"skipped_invalid_count": len(skipped_invalid_files),
			"skipped_invalid_files": skipped_invalid_files,
		}

	features, labels = _build_training_matrix(samples_by_label, class_names)
	feature_mean, feature_scale, weights, bias = _train_softmax_classifier(features, labels, len(class_names))
	prototypes = _compute_prototypes(samples_by_label, class_names, feature_mean, feature_scale)

	model = {
		"feature_mean": feature_mean.tolist(),
		"feature_scale": feature_scale.tolist(),
		"weights": weights.tolist(),
		"bias": bias.tolist(),
		"prototypes": prototypes.tolist(),
	}
	class_thresholds, class_margin_min = _calibrate_class_thresholds(samples_by_label, class_names, model)

	quiet_positive_rms = _quantile(positive_rms, 0.08, _median(positive_rms, 0.012))
	min_rms_norm = round(max(0.0032, quiet_positive_rms * 0.34), 6)
	listener_start_rms_norm = round(max(0.0042, quiet_positive_rms * 0.5), 6)
	profiles = _collect_class_score_profiles(samples_by_label, class_names, model)
	runtime_hardening = _derive_runtime_hardening(
		profiles,
		class_thresholds,
		quiet_positive_rms,
		listener_start_rms_norm,
		min_rms_norm,
	)
	duration_floor = _quantile(positive_duration, 0.05, _median(positive_duration, 420.0))
	duration_ceiling = _quantile(positive_duration, 0.95, _median(positive_duration, 520.0))
	min_segment_duration_ms = round(max(140.0, duration_floor - 130.0), 2)
	max_phrase_duration_ms = round(max(1200.0, duration_ceiling + 260.0), 2)

	return {
		"backend_engine": "logmel-softmax",
		"calibration_mode": "local-vocal-cue-v4",
		"phrase": phrase,
		"cancel_phrase": cancel_phrase or "",
		"positive_count": len(toggle_samples),
		"cancel_count": len(cancel_samples),
		"negative_count": len(negative_samples),
		"ready": ready,
		"sample_rate_hz": TARGET_SAMPLE_RATE_HZ,
		"listener_start_rms_norm": listener_start_rms_norm,
		"min_rms_norm": min_rms_norm,
		"min_segment_duration_ms": min_segment_duration_ms,
		"max_phrase_duration_ms": max_phrase_duration_ms,
		"idle_listener_start_rms_norm": runtime_hardening["idle_listener_start_rms_norm"],
		"idle_start_chunk_count": runtime_hardening["idle_start_chunk_count"],
		"idle_toggle_score_threshold": runtime_hardening["idle_toggle_score_threshold"],
		"idle_toggle_prototype_threshold": runtime_hardening["idle_toggle_prototype_threshold"],
		"idle_toggle_rival_gap_min": runtime_hardening["idle_toggle_rival_gap_min"],
		"active_cue_gap_min": runtime_hardening["active_cue_gap_min"],
		"feature_spec": {
			"frame_length": FRAME_LENGTH,
			"hop_length": HOP_LENGTH,
			"mels": N_MELS,
			"frames": FEATURE_FRAMES,
		},
		"class_names": class_names,
		"class_thresholds": class_thresholds,
		"class_margin_min": class_margin_min,
		"feature_mean": model["feature_mean"],
		"feature_scale": model["feature_scale"],
		"weights": model["weights"],
		"bias": model["bias"],
		"prototypes": model["prototypes"],
		"distance_threshold": round(float(class_thresholds.get("toggle", 0.5)), 6),
		"negative_margin_min": round(float(class_margin_min.get("toggle", 0.08)), 6),
		"skipped_invalid_count": len(skipped_invalid_files),
		"skipped_invalid_files": skipped_invalid_files,
		"summary": {
			"augmentation": {
				"positive_per_sample": POSITIVE_AUGMENTATION_COUNT,
				"background_per_sample": BACKGROUND_AUGMENTATION_COUNT,
				"calibration_per_sample": CALIBRATION_AUGMENTATION_COUNT,
				"transforms": ["gain", "speed", "time_shift", "noise", "background_mix", "spec_mask"],
			},
			"median_positive_duration_ms": round(_median(positive_duration, 0.0), 2),
			"median_positive_rms_norm": round(_median(positive_rms, 0.0), 6),
			"median_negative_rms_norm": round(_median(negative_rms, 0.0), 6),
			"toggle_threshold": class_thresholds.get("toggle", 0.0),
			"cancel_threshold": class_thresholds.get("cancel", 0.0),
			"toggle_margin_min": class_margin_min.get("toggle", 0.0),
			"cancel_margin_min": class_margin_min.get("cancel", 0.0),
			"idle_listener_start_rms_norm": runtime_hardening["idle_listener_start_rms_norm"],
			"idle_start_chunk_count": runtime_hardening["idle_start_chunk_count"],
			"idle_toggle_score_threshold": runtime_hardening["idle_toggle_score_threshold"],
			"idle_toggle_prototype_threshold": runtime_hardening["idle_toggle_prototype_threshold"],
			"idle_toggle_rival_gap_min": runtime_hardening["idle_toggle_rival_gap_min"],
			"active_cue_gap_min": runtime_hardening["active_cue_gap_min"],
		},
	}


def detect_wakeword(model_path, input_path):
	with open(model_path, "r", encoding="utf-8") as file_handle:
		model = json.load(file_handle)

	sample = extract_sample(input_path)
	analysis = sample["analysis"]
	class_names = model.get("class_names", ["background", "toggle"])
	combined_scores, softmax_scores, prototype_scores = _model_scores(sample["feature_vector"], model)
	top_index = int(np.argmax(combined_scores))
	top_class = class_names[top_index]
	sorted_scores = np.sort(combined_scores)
	margin = float(sorted_scores[-1] - sorted_scores[-2]) if sorted_scores.size >= 2 else float(sorted_scores[-1])
	score = float(combined_scores[top_index])
	reasons = []

	if sample["duration_ms"] < float(model.get("min_segment_duration_ms", 180.0)):
		reasons.append("too_short")
	if sample["duration_ms"] > float(model.get("max_phrase_duration_ms", 1800.0)):
		reasons.append("too_long")
	if sample.get("trimmed_rms_norm", analysis["rms_norm"]) < float(model.get("min_rms_norm", 0.005)):
		reasons.append("too_quiet")

	if top_class == "background":
		reasons.append("classified_as_background")
	else:
		class_thresholds = model.get("class_thresholds", {})
		class_margin_min = model.get("class_margin_min", {})
		if score < float(class_thresholds.get(top_class, 0.5)):
			reasons.append("score_below_threshold")
		if margin < float(class_margin_min.get(top_class, 0.08)):
			reasons.append("margin_too_small")

	background_index = class_names.index("background") if "background" in class_names else 0
	background_score = float(combined_scores[background_index])
	action = top_class if top_class in {"toggle", "cancel"} and not reasons else None

	return {
		"accepted": action is not None,
		"action": action,
		"analysis": analysis,
		"candidate": {
			"duration_ms": round(float(sample["duration_ms"]), 2),
			"trimmed_rms_norm": round(float(sample.get("trimmed_rms_norm", 0.0)), 6),
		},
		"class_scores": {name: round(float(combined_scores[index]), 6) for index, name in enumerate(class_names)},
		"softmax_scores": {name: round(float(softmax_scores[index]), 6) for index, name in enumerate(class_names)},
		"prototype_scores": {name: round(float(prototype_scores[index]), 6) for index, name in enumerate(class_names)},
		"distance_threshold": model.get("distance_threshold", 0.0),
		"input_path": os.path.abspath(input_path),
		"margin": round(margin, 6),
		"negative_distance": round(max(0.0, 1.0 - background_score), 6),
		"negative_margin_min": float(model.get("negative_margin_min", 0.0)),
		"positive_distance": round(max(0.0, 1.0 - score), 6),
		"reasons": reasons,
		"score": round(score, 6),
		"top_class": top_class,
	}


def _build_parser():
	parser = argparse.ArgumentParser(description="Wake-word sample analysis tools")
	subparsers = parser.add_subparsers(dest="command", required=True)

	analyze_parser = subparsers.add_parser("analyze", help="Analyze a single WAV file")
	analyze_parser.add_argument("--input", required=True, help="Path to a WAV file")

	summarize_parser = subparsers.add_parser("summarize", help="Summarize recorded wake-word samples")
	summarize_parser.add_argument("--phrase", required=True, help="Primary wake cue label")
	summarize_parser.add_argument("--cancel-phrase", default="", help="Optional cancel cue label")
	summarize_parser.add_argument("--positive-dir", required=True, help="Directory of primary cue samples")
	summarize_parser.add_argument("--cancel-dir", default="", help="Directory of cancel cue samples")
	summarize_parser.add_argument("--negative-dir", required=True, help="Directory of negative samples")

	detect_parser = subparsers.add_parser("detect", help="Score a candidate clip against a trained model")
	detect_parser.add_argument("--model", required=True, help="Path to calibration.json")
	detect_parser.add_argument("--input", required=True, help="Path to a WAV file")

	return parser


def main(argv):
	parser = _build_parser()
	args = parser.parse_args(argv)

	if args.command == "analyze":
		result = analyze_wav(args.input)
	elif args.command == "summarize":
		result = summarize_samples(args.phrase, args.positive_dir, args.negative_dir, cancel_dir=args.cancel_dir, cancel_phrase=args.cancel_phrase)
	elif args.command == "detect":
		result = detect_wakeword(args.model, args.input)
	else:  # pragma: no cover - argparse keeps this unreachable
		parser.error(f"Unsupported command: {args.command}")
		return 2

	sys.stdout.write(f"{json.dumps(result, ensure_ascii=True)}\n")
	return 0


if __name__ == "__main__":
	raise SystemExit(main(sys.argv[1:]))
