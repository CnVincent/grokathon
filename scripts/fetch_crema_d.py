"""Download a CREMA-D sample (ODbL, acted emotional speech) for tone evaluation.

Clips go to the gitignored data/ folder; never commit them.
"""

import argparse
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen

BASE_URL = (
    "https://media.githubusercontent.com/media/CheyneyComputerScience/CREMA-D/master/AudioWAV"
)
ACTORS = range(1001, 1092)
# IEO is the only sentence recorded at several intensities; the rest are "XX".
SENTENCES = ("DFA", "IOM", "ITH", "ITS", "IWL", "IWW", "MTI", "TAI", "TIE", "TSI", "WSI")
EMOTIONS = ("ANG", "DIS", "FEA", "HAP", "NEU", "SAD")


def fetch(name: str, out: Path, timeout: float) -> str:
    path = out / name
    if path.exists():
        return "cached"
    try:
        with urlopen(f"{BASE_URL}/{name}", timeout=timeout) as response:
            data = response.read()
    except HTTPError as error:
        if error.code == 404:
            return "missing"  # A few actor/sentence/emotion combinations were never recorded.
        raise
    path.write_bytes(data)
    return "downloaded"


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=Path("data/crema-d"), help="Output folder.")
    parser.add_argument(
        "--actors", type=int, default=20, help="Actors to sample, spread across all 91."
    )
    parser.add_argument("--timeout", type=float, default=30, help="Per-file timeout (seconds).")
    args = parser.parse_args(argv)
    if not 1 <= args.actors <= len(ACTORS):
        parser.error(f"--actors must be between 1 and {len(ACTORS)}")

    # Spread the sample across actor IDs so it isn't one age/gender group.
    step = len(ACTORS) / args.actors
    actors = [ACTORS[int(i * step)] for i in range(args.actors)]
    names = [
        f"{actor}_{sentence}_{emotion}_XX.wav"
        for actor in actors
        for sentence in SENTENCES
        for emotion in EMOTIONS
    ]
    args.out.mkdir(parents=True, exist_ok=True)

    counts: dict[str, int] = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for status in pool.map(lambda name: fetch(name, args.out, args.timeout), names):
            counts[status] = counts.get(status, 0) + 1
    print(
        f"{len(actors)} actors, {len(names)} clips: "
        + ", ".join(f"{count} {status}" for status, count in sorted(counts.items()))
        + f" -> {args.out}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
