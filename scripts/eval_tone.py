"""Measure tone-tag accuracy of the server's audEERING backend on labeled clips.

Labels come from filenames: CREMA-D names (1001_DFA_ANG_XX.wav) or A4's prefix convention
(excited_*, upset_*, calm_*, none_* / neutral_*). Clips are read into memory only.
"""

import argparse
import csv
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

from app.audeering import SAMPLE_RATE, AudeeringToneBackend
from app.tone import map_tag

TAGS = ("excited", "upset", "calm")
SCORED = (*TAGS, "none")
CREMA_D = re.compile(r"^\d{4}_[A-Z]{3}_(?P<emotion>[A-Z]{3})_[A-Z]{2}$")
# Only clear matches are scored. Sad, fear, and disgust have no matching tag, so the
# report shows what the model says for them without counting them as right or wrong.
CREMA_D_LABELS = {
    "ANG": "upset",
    "HAP": "excited",
    "NEU": "none",
    "SAD": "sad",
    "FEA": "fear",
    "DIS": "disgust",
}
AUDIO_SUFFIXES = {".wav", ".mp3", ".flac", ".ogg"}


def label_for(path: Path) -> str:
    if match := CREMA_D.match(path.stem):
        return CREMA_D_LABELS.get(match["emotion"], match["emotion"].lower())
    prefix = path.stem.split("_")[0].lower()
    return "none" if prefix == "neutral" else prefix


def load_pcm16(path: Path) -> bytes:
    """Read any soundfile format as 16 kHz mono PCM16, like the phone sends."""
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    audio = audio.mean(axis=1)
    if sample_rate != SAMPLE_RATE:
        audio = resample_poly(audio, SAMPLE_RATE, sample_rate)
    return (np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()


def percent(part: int, whole: int) -> str:
    return f"{100 * part / whole:5.1f}%" if whole else "    –"


def report(rows: list[dict]) -> None:
    scored = [row for row in rows if row["label"] in SCORED]
    labels = sorted({row["label"] for row in rows}, key=lambda x: (x not in SCORED, x))
    table = Counter((row["label"], row["tag"]) for row in rows)

    print("\nRows: true label. Columns: tag the model returned.\n")
    print(f"{'label':<10}" + "".join(f"{tag:>9}" for tag in SCORED) + f"{'clips':>8}")
    for label in labels:
        counts = [table[label, tag] for tag in SCORED]
        marker = "" if label in SCORED else "  (not scored)"
        print(f"{label:<10}" + "".join(f"{c:>9}" for c in counts) + f"{sum(counts):>8}{marker}")

    if not scored:
        print("\nNo clips with a scored label (excited, upset, calm, none).")
        return

    correct = sum(row["tag"] == row["label"] for row in scored)
    wrong_tag = sum(row["tag"] != "none" and row["tag"] != row["label"] for row in scored)
    tone_clips = [row for row in scored if row["label"] != "none"]
    missed = sum(row["tag"] == "none" for row in tone_clips)
    always_none = sum(row["label"] == "none" for row in scored)

    print(f"\nScored clips: {len(scored)}")
    print(f"  Accuracy              {percent(correct, len(scored))}  ({correct})")
    print(f"  Wrong tag shown       {percent(wrong_tag, len(scored))}  ({wrong_tag})  <- worst")
    print(f"  Tone missed (null)    {percent(missed, len(tone_clips))}  of clips with a tone")
    print(f"  'Always null' gets    {percent(always_none, len(scored))}  (baseline to beat)")

    print(f"\n{'tag':<10}{'precision':>11}{'recall':>9}   precision = when shown, how often right")
    for tag in TAGS:
        shown = sum(row["tag"] == tag for row in scored)
        hits = sum(row["tag"] == tag == row["label"] for row in scored)
        actual = sum(row["label"] == tag for row in scored)
        print(f"{tag:<10}{percent(hits, shown):>11}{percent(hits, actual):>9}")

    print(f"\n{'label':<10}{'arousal':>9}{'valence':>9}   mean scores, for threshold tuning")
    by_label = defaultdict(list)
    for row in rows:
        if row["arousal"] is not None:
            by_label[row["label"]].append((row["arousal"], row["valence"]))
    for label in labels:
        if values := by_label[label]:
            arousal, valence = np.mean(values, axis=0)
            print(f"{label:<10}{arousal:>9.3f}{valence:>9.3f}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("folder", type=Path, help="Folder of labeled audio clips.")
    parser.add_argument("--csv", type=Path, help="Also write per-clip scores and tags here.")
    parser.add_argument("--limit", type=int, help="Only evaluate the first N clips.")
    args = parser.parse_args(argv)

    files = sorted(p for p in args.folder.iterdir() if p.suffix.lower() in AUDIO_SUFFIXES)
    if args.limit:
        files = files[: args.limit]
    if not files:
        parser.error(f"no audio files ({', '.join(sorted(AUDIO_SUFFIXES))}) in {args.folder}")

    backend = AudeeringToneBackend()
    print(f"Evaluating {len(files)} clips on {backend.device}...", file=sys.stderr)
    started = time.perf_counter()
    rows = []
    for path in files:
        arousal, valence = backend.scores(load_pcm16(path), SAMPLE_RATE)
        tag = None if arousal is None else map_tag(arousal, valence, backend.thresholds)
        rows.append(
            {
                "file": path.name,
                "label": label_for(path),
                "arousal": arousal,
                "valence": valence,
                "tag": tag or "none",
            }
        )
    elapsed = time.perf_counter() - started
    print(
        f"{backend.model_version}: {len(rows)} clips in {elapsed:.1f} s "
        f"({1000 * elapsed / len(rows):.0f} ms each)"
    )
    report(rows)

    if args.csv:
        with args.csv.open("w", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        print(f"\nPer-clip results: {args.csv}")


if __name__ == "__main__":
    main()
