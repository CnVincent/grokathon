import argparse
import json
import math
from pathlib import Path

import cv2
import mediapipe as mp


def matrix_to_list(matrix):
    """Convert a MediaPipe matrix to ordinary Python lists for JSON."""
    if matrix is None:
        return None
    if hasattr(matrix, "tolist"):
        return matrix.tolist()
    return matrix


def main():
    parser = argparse.ArgumentParser(
        description = "Save MediaPipe Face Landmarker results for each video frame."
    )
    parser.add_argument("--video", required = True, help = "Path to the input video")
    parser.add_argument(
        "--model",
        default = "ml/common/models/face_landmarker.task",
        help = "Path to the Face Landmarker model",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output JSONL path; defaults to ml/asd/<video_name>_landmarks.jsonl",
    )
    args = parser.parse_args()

    video_path = Path(args.video)
    model_path = Path(args.model)

    if not video_path.is_file():
        raise FileNotFoundError(f"Video not found: {video_path}")
    if not model_path.is_file():
        raise FileNotFoundError(f"Model file not found: {model_path}")

    output_path = (
        Path(args.output)
        if args.output
        else Path("ml/asd") / f"{video_path.stem}_landmarks.jsonl"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)

    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise RuntimeError(f"Could not open video: {video_path}")

    fps = capture.get(cv2.CAP_PROP_FPS)
    if not math.isfinite(fps) or fps <= 0:
        fps = 30.0  # Fallback if the video does not report its frame rate.

    # VIDEO mode requires a timestamp for each frame. Timestamps must increase.
    frame_index = 0
    previous_timestamp_ms = -1
    frames_with_faces = 0
    most_faces_in_a_frame = 0

    options = mp.tasks.vision.FaceLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(model_path)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO,
        num_faces=5,
        output_face_blendshapes=True,
        output_facial_transformation_matrixes=True,
    )

    try:
        with mp.tasks.vision.FaceLandmarker.create_from_options(options) as landmarker:
            with output_path.open("w", encoding="utf-8") as output_file:
                while True:
                    success, bgr_frame = capture.read()
                    if not success:
                        break

                    height, width = bgr_frame.shape[:2]
                    rgb_frame = cv2.cvtColor(bgr_frame, cv2.COLOR_BGR2RGB)

                    timestamp_ms = max(
                        previous_timestamp_ms + 1,
                        round(frame_index * 1000 / fps),
                    )
                    previous_timestamp_ms = timestamp_ms

                    mp_image = mp.Image(
                        image_format=mp.ImageFormat.SRGB,
                        data=rgb_frame,
                    )
                    result = landmarker.detect_for_video(mp_image, timestamp_ms)

                    faces = []
                    for face_index, landmarks in enumerate(result.face_landmarks):
                        face = {
                            "face_index": face_index,
                            # These are MediaPipe normalized coordinates.
                            # Keep them raw for now; do not make the 96 features yet.
                            "landmarks": [
                                {
                                    "x": float(point.x),
                                    "y": float(point.y),
                                    "z": float(point.z),
                                }
                                for point in landmarks
                            ],
                        }

                        if face_index < len(result.face_blendshapes):
                            face["blendshapes"] = [
                                {
                                    "name": category.category_name,
                                    "score": float(category.score),
                                }
                                for category in result.face_blendshapes[face_index]
                            ]

                        if face_index < len(result.facial_transformation_matrixes):
                            face["facial_transformation_matrix"] = matrix_to_list(
                                result.facial_transformation_matrixes[face_index]
                            )

                        faces.append(face)

                    if faces:
                        frames_with_faces += 1
                    most_faces_in_a_frame = max(most_faces_in_a_frame, len(faces))

                    # One JSON object per video frame.
                    record = {
                        "frame_index": frame_index,
                        "timestamp_ms": timestamp_ms,
                        "width": width,
                        "height": height,
                        "faces": faces,
                    }
                    output_file.write(json.dumps(record) + "\n")

                    frame_index += 1
    finally:
        capture.release()

    print(f"Processed {frame_index} frames.")
    print(f"Frames with at least one detected face: {frames_with_faces}.")
    print(f"Most faces detected in one frame: {most_faces_in_a_frame}.")
    print(f"Saved results to: {output_path}")

    if frames_with_faces == 0:
        print("Warning: no faces were detected. Try a brighter clip with a clear face.")


if __name__ == "__main__":
    main()
