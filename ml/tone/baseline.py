#command-line interface, processing a folder of clips, and saving CSV results
#argparse lets us specify an audio folder and output CSV from terminal
#csv lets us save predictions in a structured file
#Path will help us find and organize audio files
#soundfile loads in the audio files + reads their sample rate
#AudeeringBackend gives us access to model functionality we moved into backend.py

import argparse
import csv
from pathlib import Path

import soundfile as sf

from ml.tone.backend import AudeeringBackend

# Defines the CSV columns so even an empty folder produces a correctly
# structured results file.
FIELDNAMES = [
    "file",
    "speaker",
    "label",
    "arousal",
    "valence",
    "dominance",
    "tag",
    "latency_ms",
]

def load_audio(audio_file):
    #read in the audio file which contains sound samples and "sample_rate"
    #tells us how many samples occur in each second
    audio, sample_rate = sf.read(audio_file)

    #if there are multiple channels, average them to create 1 mono signal
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    return audio, sample_rate

#extract intended category from filename
def extract_tag(audio_file):
    #use first part of filename as the intended category
    #this is bc filenames are organized as calm_clip_one.mp3
    filename = Path(audio_file).name
    #category first part of the filename
    category = filename.split("_")[0]
    #Convert "none" from the filename into Python's None value
    if category == "none":
        return None
    return category

#function that runs the model on one clip and measures its inference time
def analyze_clip(audio_file, backend):
    audio, sample_rate = load_audio(audio_file)
    result = backend.predict(audio, sample_rate)

    return {
        "file": Path(audio_file).name,
        "arousal": round(result["arousal"], 5),
        "valence": round(result["valence"], 5),
        "dominance": round(result["dominance"], 5),
        "tag": result["tag"],
        "latency_ms": round(result["latency_ms"], 5),
    }

#Lets baseline.py accept an audio folder and an output CSV path from the terminal
#replaces A4's concept of a local, hard-coded folder
#main() groups the script's main workflow in one function
def main():
    parser = argparse.ArgumentParser(
        description= "Run tone predictions on audio files."
    )

    #audio_dir points towards the specific folder with the audio files
    parser.add_argument("audio_dir", help= "Folder containing audio files")
    parser.add_argument(
        "--out", #specifies where to save the CSV
        default= "results.csv",
        help= "Path for the output CSV file",
    )

    #reads the arguments from the command line
    args = parser.parse_args()
    output_path = Path(args.out)
    output_path.parent.mkdir(parents=True, exist_ok = True)
    #turns the folder that the Path supplied in terminal to a path that object Python can work with
    audio_dir = Path(args.audio_dir)

    #Checks that the supplied path exists and points to a directory
    #provides clear error instead of failing and iterating over an invalid path
    if not audio_dir.exists():
        parser.error(f"Audio directory does not exist: {audio_dir}")

    if not audio_dir.is_dir():
        parser.error(f"Audio path is not a directory: {audio_dir}")

    #looks at the files inside and checks file extension to only include audio files
    audio_files = sorted(path for path in audio_dir.iterdir()
                         if path.suffix.lower() in {".wav", ".mp3"}
    )

    #tells us how many supported audio files were found
    print(f"Found {len(audio_files)} audio files.")

    #Load and warm up the model only when there are clips to process
    backend = None

    #checks the folder to see if the folder contains at least one supported audio file
    if audio_files:
        #loads tone model once so we can reuse for subsequent clips
        backend = AudeeringBackend()
        warmup_audio, warmup_sample_rate = load_audio(audio_files[0])
        #runs one prediction to warm up the model
        backend.predict(warmup_audio, warmup_sample_rate)

    #process each audio file and collect results
    #empty list to store the results from all clips
    results = []
    for audio_file in audio_files:
        #splits the filename into parts based on underscore delimiter
        parts = audio_file.stem.split("_")

        #Expects that every audio filename follows the label_clip_name pattern
        #The first part is the label, the last part is the numeric clip identifier
        #and any parts in between the speaker
        #checks if filename has at least 3 underscore-separated parts
        if (
            len(parts) < 3
            or not parts[0]
            or not parts[-1].isdigit()
            or any(not part for part in parts)):
            raise ValueError(
                f"Unexpected filename format: {audio_file.stem}"
                "Expected label_speaker_NN such as calm_speaker_01.wav."
            )

        #send clip to backend + retrieves predicted scores/tag
        result = analyze_clip(audio_file, backend)
        #stores the part after the label as clip identifier
        result["speaker"] = "_".join(parts[1:-1])
        #extracts the label from the filename
        result["label"] = extract_tag(audio_file)
        #stores completed result for CSV later
        results.append(result)

    #Write results into CSV file or overwrites it if it exists
    with open(
        output_path,"w", newline="", encoding="utf-8"
    ) as csvfile:
        #converts each result dictionary into a CSV row
        writer = csv.DictWriter(csvfile, fieldnames=FIELDNAMES)
        writer.writeheader() #writes the column names as the first row
        writer.writerows(results) #saves all collected predictions
    print(f"Results written to {output_path}") #tells us where the results were saved


#This is the entry point for the script
#Ensures that main() is only called when the script is run directly
if __name__ == "__main__":
    main()
