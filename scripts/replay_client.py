"""Replay PCM16 mono WAV chunks against P2, printing one JSON reply per chunk."""

import argparse
import base64
import json
import math
import os
import sys
import wave
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from uuid import uuid4

from websockets.exceptions import WebSocketException
from websockets.sync.client import connect


def positive_seconds(value: str) -> float:
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return seconds


def replay(args: argparse.Namespace) -> None:
    url = urlsplit(args.url)
    if url.scheme not in {"ws", "wss"} or not url.netloc or url.fragment:
        raise ValueError("--url must be a ws:// or wss:// URL without a fragment")
    query = [(key, value) for key, value in parse_qsl(url.query) if key != "session_id"]
    query.append(("session_id", args.session_id))
    endpoint = urlunsplit(url._replace(query=urlencode(query)))
    headers = {"Authorization": f"Bearer {args.token}"} if args.token else None

    with wave.open(str(args.wav), "rb") as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getcomptype() != "NONE":
            raise ValueError("WAV must be uncompressed PCM16 mono; convert the file first")
        sample_rate = audio.getframerate()
        frames_per_chunk = max(1, int(sample_rate * args.chunk_seconds))
        if audio.getnframes() == 0:
            raise ValueError("WAV contains no audio frames")
        with connect(endpoint, additional_headers=headers, open_timeout=args.timeout) as websocket:
            frame_offset = 0
            while chunk := audio.readframes(frames_per_chunk):
                if len(chunk) % 2:
                    raise ValueError("WAV contains an incomplete PCM16 sample")
                frame_count = len(chunk) // 2
                caption_id = str(uuid4())
                request = {
                    "type": "tone_request",
                    "session_id": args.session_id,
                    "schema_version": "1.2",
                    "caption_id": caption_id,
                    # Emulate phone session time using the WAV's sample timeline.
                    "t_start": frame_offset / sample_rate,
                    "t_end": (frame_offset + frame_count) / sample_rate,
                    "sample_rate": sample_rate,
                    "audio_b64": base64.b64encode(chunk).decode("ascii"),
                }
                websocket.send(json.dumps(request))
                reply = json.loads(websocket.recv(timeout=args.timeout))
                print(json.dumps(reply), flush=True)
                if reply.get("type") == "session_error":
                    raise ValueError(f"server rejected chunk: {reply.get('code', 'unknown')}")
                if (
                    reply.get("type") != "tone_result"
                    or reply.get("caption_id") != caption_id
                    or reply.get("session_id") != args.session_id
                ):
                    raise ValueError("server reply does not match the chunk")
                frame_offset += frame_count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", help="path to an uncompressed PCM16 mono WAV file")
    parser.add_argument("--url", default="ws://127.0.0.1:8000/ws/session")
    parser.add_argument("--session-id", default=str(uuid4()))
    parser.add_argument("--chunk-seconds", type=positive_seconds, default=1.0)
    parser.add_argument("--timeout", type=positive_seconds, default=30.0)
    parser.add_argument("--token", default=os.getenv("TONE_TOKEN"), help="defaults to TONE_TOKEN")
    args = parser.parse_args()
    if not args.session_id:
        parser.error("--session-id must not be empty")
    try:
        replay(args)
    except (OSError, EOFError, ValueError, wave.Error, TimeoutError, WebSocketException) as error:
        print(f"Replay failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
