import json
import math
import random
import subprocess
import sys
import wave
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TOOLS_SCRIPT = REPO_ROOT / "scripts" / "wakeword_tools.py"


def write_wave(path: Path, seconds: float, amplitude: float, frequency_hz: float = 220.0) -> None:
    sample_rate = 16_000
    frame_count = int(sample_rate * seconds)
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        frames = bytearray()
        for index in range(frame_count):
            value = int(32767 * amplitude * math.sin((2.0 * math.pi * frequency_hz * index) / sample_rate))
            frames.extend(int(value).to_bytes(2, byteorder="little", signed=True))
        wav_file.writeframes(bytes(frames))


def write_noise_wave(path: Path, seconds: float, amplitude: float, seed: int, lowpass: float = 0.0) -> None:
    sample_rate = 16_000
    frame_count = int(sample_rate * seconds)
    rng = random.Random(seed)
    smoothed = 0.0
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        frames = bytearray()
        for index in range(frame_count):
            raw = rng.uniform(-1.0, 1.0)
            if lowpass > 0.0:
                smoothed = (smoothed * lowpass) + (raw * (1.0 - lowpass))
                raw = smoothed
            envelope = min(1.0, index / max(1, frame_count // 8))
            envelope *= min(1.0, (frame_count - index) / max(1, frame_count // 8))
            value = int(32767 * amplitude * raw * envelope)
            frames.extend(int(value).to_bytes(2, byteorder="little", signed=True))
        wav_file.writeframes(bytes(frames))


def write_padded_noise_wave(path: Path, total_seconds: float, active_seconds: float, amplitude: float, seed: int) -> None:
    sample_rate = 16_000
    frame_count = int(sample_rate * total_seconds)
    active_frame_count = int(sample_rate * active_seconds)
    active_start = max(0, (frame_count - active_frame_count) // 2)
    active_end = min(frame_count, active_start + active_frame_count)
    rng = random.Random(seed)
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        frames = bytearray()
        for index in range(frame_count):
            raw = 0.0
            if active_start <= index < active_end:
                raw = rng.uniform(-1.0, 1.0)
                fade = min(1.0, (index - active_start + 1) / max(1, active_frame_count // 6))
                fade *= min(1.0, (active_end - index) / max(1, active_frame_count // 6))
                raw *= fade
            value = int(32767 * amplitude * raw)
            frames.extend(int(value).to_bytes(2, byteorder="little", signed=True))
        wav_file.writeframes(bytes(frames))


def write_empty_wave(path: Path) -> None:
    with wave.open(str(path), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(16_000)


def run_tools(*args: str) -> dict:
    result = subprocess.run(
        [sys.executable, str(TOOLS_SCRIPT), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def test_analyze_reports_expected_metrics(tmp_path: Path) -> None:
    clip = tmp_path / "clip.wav"
    write_wave(clip, seconds=1.0, amplitude=0.25)

    report = run_tools("analyze", "--input", str(clip))

    assert report["sample_rate_hz"] == 16000
    assert 950 <= report["duration_ms"] <= 1050
    assert report["rms_norm"] > 0.05
    assert report["peak_norm"] > 0.2


def test_summarize_reports_ready_when_minimum_samples_exist(tmp_path: Path) -> None:
    positive_dir = tmp_path / "positive"
    negative_dir = tmp_path / "negative"
    positive_dir.mkdir()
    negative_dir.mkdir()

    for index in range(12):
        write_wave(positive_dir / f"positive-{index}.wav", seconds=1.0, amplitude=0.2)
    for index in range(9):
        write_wave(negative_dir / f"negative-{index}.wav", seconds=1.0, amplitude=0.05)

    report = run_tools(
        "summarize",
        "--phrase",
        "dragon dragon",
        "--positive-dir",
        str(positive_dir),
        "--negative-dir",
        str(negative_dir),
    )

    assert report["phrase"] == "dragon dragon"
    assert report["backend_engine"] == "logmel-softmax"
    assert report["positive_count"] == 12
    assert report["cancel_count"] == 0
    assert report["negative_count"] == 9
    assert report["ready"] is True
    assert report["min_rms_norm"] >= 0.003
    assert set(report["class_names"]) == {"background", "toggle"}
    assert report["class_thresholds"]["toggle"] >= 0.4
    assert len(report["weights"]) > 0
    assert report["listener_start_rms_norm"] >= report["min_rms_norm"]
    assert report["idle_listener_start_rms_norm"] >= report["listener_start_rms_norm"]
    assert report["idle_start_chunk_count"] >= 2
    assert report["idle_toggle_score_threshold"] >= report["class_thresholds"]["toggle"]
    assert report["idle_toggle_prototype_threshold"] > 0
    assert report["active_cue_gap_min"] > 0
    assert report["skipped_invalid_count"] == 0
    assert report["summary"]["augmentation"]["positive_per_sample"] >= 8
    assert "background_mix" in report["summary"]["augmentation"]["transforms"]


def test_summarize_skips_invalid_wavs(tmp_path: Path) -> None:
    positive_dir = tmp_path / "positive"
    negative_dir = tmp_path / "negative"
    positive_dir.mkdir()
    negative_dir.mkdir()

    for index in range(12):
        write_wave(positive_dir / f"positive-{index}.wav", seconds=1.0, amplitude=0.2)
    for index in range(9):
        write_wave(negative_dir / f"negative-{index}.wav", seconds=1.0, amplitude=0.05)

    write_empty_wave(positive_dir / "broken-positive.wav")
    write_empty_wave(negative_dir / "broken-negative.wav")

    report = run_tools(
        "summarize",
        "--phrase",
        "dragon dragon",
        "--positive-dir",
        str(positive_dir),
        "--negative-dir",
        str(negative_dir),
    )

    assert report["positive_count"] == 12
    assert report["negative_count"] == 9
    assert report["ready"] is True
    assert report["skipped_invalid_count"] == 2
    skipped_files = {Path(item["file_path"]).name for item in report["skipped_invalid_files"]}
    assert skipped_files == {"broken-positive.wav", "broken-negative.wav"}


def test_detect_accepts_matching_clip_and_rejects_decoy(tmp_path: Path) -> None:
    positive_dir = tmp_path / "positive"
    negative_dir = tmp_path / "negative"
    positive_dir.mkdir()
    negative_dir.mkdir()

    for index in range(12):
        write_noise_wave(positive_dir / f"positive-{index}.wav", seconds=0.55, amplitude=0.24, seed=100 + index, lowpass=0.0)
    for index in range(9):
        write_wave(negative_dir / f"negative-{index}.wav", seconds=0.8, amplitude=0.18, frequency_hz=220.0 + (index * 15.0))

    model_path = tmp_path / "calibration.json"
    model = run_tools(
        "summarize",
        "--phrase",
        "dragon dragon",
        "--positive-dir",
        str(positive_dir),
        "--negative-dir",
        str(negative_dir),
    )
    model_path.write_text(json.dumps(model), encoding="utf-8")

    candidate_match = tmp_path / "candidate-match.wav"
    candidate_decoy = tmp_path / "candidate-decoy.wav"
    write_noise_wave(candidate_match, seconds=0.58, amplitude=0.24, seed=999, lowpass=0.0)
    write_wave(candidate_decoy, seconds=0.92, amplitude=0.2, frequency_hz=440.0)

    match_report = run_tools("detect", "--model", str(model_path), "--input", str(candidate_match))
    decoy_report = run_tools("detect", "--model", str(model_path), "--input", str(candidate_decoy))

    assert match_report["accepted"] is True
    assert match_report["action"] == "toggle"
    assert match_report["top_class"] == "toggle"
    assert decoy_report["accepted"] is False
    assert any(
        reason in decoy_report["reasons"]
        for reason in [
            "classified_as_background",
            "score_below_threshold",
            "margin_too_small",
        ]
    )


def test_summarize_uses_trimmed_cue_duration_profile(tmp_path: Path) -> None:
    positive_dir = tmp_path / "positive"
    negative_dir = tmp_path / "negative"
    positive_dir.mkdir()
    negative_dir.mkdir()

    for index in range(12):
        write_padded_noise_wave(
            positive_dir / f"positive-{index}.wav",
            total_seconds=1.4,
            active_seconds=0.42,
            amplitude=0.22,
            seed=200 + index,
        )
    for index in range(9):
        write_wave(negative_dir / f"negative-{index}.wav", seconds=0.9, amplitude=0.16, frequency_hz=240.0 + (index * 20.0))

    report = run_tools(
        "summarize",
        "--phrase",
        "double hiss",
        "--positive-dir",
        str(positive_dir),
        "--negative-dir",
        str(negative_dir),
    )
    model_path = tmp_path / "calibration.json"
    model_path.write_text(json.dumps(report), encoding="utf-8")

    assert report["summary"]["median_positive_duration_ms"] < 700
    assert report["min_segment_duration_ms"] < 600

    candidate = positive_dir / "positive-0.wav"
    candidate_report = run_tools("detect", "--model", str(model_path), "--input", str(candidate))
    assert candidate_report["accepted"] is True


def test_detect_accepts_slightly_drifted_cue_shape(tmp_path: Path) -> None:
    positive_dir = tmp_path / "positive"
    negative_dir = tmp_path / "negative"
    positive_dir.mkdir()
    negative_dir.mkdir()

    for index in range(12):
        write_padded_noise_wave(
            positive_dir / f"positive-{index}.wav",
            total_seconds=1.4,
            active_seconds=0.42,
            amplitude=0.22,
            seed=400 + index,
        )
    for index in range(9):
        write_wave(negative_dir / f"negative-{index}.wav", seconds=0.9, amplitude=0.16, frequency_hz=260.0 + (index * 18.0))

    model = run_tools(
        "summarize",
        "--phrase",
        "double hiss",
        "--positive-dir",
        str(positive_dir),
        "--negative-dir",
        str(negative_dir),
    )
    model_path = tmp_path / "calibration.json"
    model_path.write_text(json.dumps(model), encoding="utf-8")

    candidate = tmp_path / "candidate-drift.wav"
    write_padded_noise_wave(
        candidate,
        total_seconds=1.4,
        active_seconds=0.58,
        amplitude=0.20,
        seed=999,
    )

    report = run_tools("detect", "--model", str(model_path), "--input", str(candidate))

    assert report["candidate"]["duration_ms"] > model["summary"]["median_positive_duration_ms"]
    assert "too_long" not in report["reasons"]
    assert report["accepted"] is True


def test_detect_accepts_quieter_noisier_and_faster_cue_variant(tmp_path: Path) -> None:
    positive_dir = tmp_path / "positive"
    negative_dir = tmp_path / "negative"
    positive_dir.mkdir()
    negative_dir.mkdir()

    for index in range(12):
        write_padded_noise_wave(
            positive_dir / f"positive-{index}.wav",
            total_seconds=1.3,
            active_seconds=0.44,
            amplitude=0.24,
            seed=520 + index,
        )
    for index in range(9):
        write_noise_wave(
            negative_dir / f"negative-{index}.wav",
            seconds=0.85,
            amplitude=0.12,
            seed=810 + index,
            lowpass=0.82,
        )

    model = run_tools(
        "summarize",
        "--phrase",
        "double hiss",
        "--positive-dir",
        str(positive_dir),
        "--negative-dir",
        str(negative_dir),
    )
    model_path = tmp_path / "calibration.json"
    model_path.write_text(json.dumps(model), encoding="utf-8")

    candidate = tmp_path / "candidate-variant.wav"
    write_padded_noise_wave(
        candidate,
        total_seconds=1.0,
        active_seconds=0.31,
        amplitude=0.16,
        seed=1305,
    )

    report = run_tools("detect", "--model", str(model_path), "--input", str(candidate))

    assert report["candidate"]["duration_ms"] < model["summary"]["median_positive_duration_ms"]
    assert report["analysis"]["rms_norm"] < model["summary"]["median_positive_rms_norm"]
    assert report["accepted"] is True


def test_detect_supports_optional_cancel_cue(tmp_path: Path) -> None:
    positive_dir = tmp_path / "positive"
    cancel_dir = tmp_path / "cancel"
    negative_dir = tmp_path / "negative"
    positive_dir.mkdir()
    cancel_dir.mkdir()
    negative_dir.mkdir()

    for index in range(12):
        write_noise_wave(positive_dir / f"toggle-{index}.wav", seconds=0.55, amplitude=0.24, seed=700 + index, lowpass=0.0)
        write_wave(cancel_dir / f"cancel-{index}.wav", seconds=0.55, amplitude=0.22, frequency_hz=190.0 + index)
    for index in range(9):
        write_wave(negative_dir / f"negative-{index}.wav", seconds=0.9, amplitude=0.18, frequency_hz=280.0 + (index * 14.0))

    model = run_tools(
        "summarize",
        "--phrase",
        "double hiss",
        "--cancel-phrase",
        "double puff",
        "--positive-dir",
        str(positive_dir),
        "--cancel-dir",
        str(cancel_dir),
        "--negative-dir",
        str(negative_dir),
    )
    model_path = tmp_path / "calibration.json"
    model_path.write_text(json.dumps(model), encoding="utf-8")

    toggle_candidate = tmp_path / "toggle-candidate.wav"
    cancel_candidate = tmp_path / "cancel-candidate.wav"
    write_noise_wave(toggle_candidate, seconds=0.57, amplitude=0.23, seed=1201, lowpass=0.0)
    write_wave(cancel_candidate, seconds=0.57, amplitude=0.22, frequency_hz=196.0)

    toggle_report = run_tools("detect", "--model", str(model_path), "--input", str(toggle_candidate))
    cancel_report = run_tools("detect", "--model", str(model_path), "--input", str(cancel_candidate))

    assert model["cancel_count"] == 12
    assert set(model["class_names"]) == {"background", "toggle", "cancel"}
    assert model["idle_toggle_rival_gap_min"] > model["active_cue_gap_min"]
    assert toggle_report["accepted"] is True
    assert toggle_report["action"] == "toggle"
    assert cancel_report["accepted"] is True
    assert cancel_report["action"] == "cancel"
