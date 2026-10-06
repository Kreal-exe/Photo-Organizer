"""Builds PhotoOrganizer/Resources/clip-labels.bin: the MobileCLIP text vectors of the labels the app tags photos with.

The labels are the macOS app's (the Vision identifiers with Russian names in Sources/POLabels.m). Computing their
vectors once here means the app needs only MobileCLIP's image half — no text model, no tokenizer.

    python Tools/make_clip_labels.py      (needs: numpy onnxruntime tokenizers huggingface_hub)

File layout (little-endian): "POCL", int32 count, int32 dimension, then per label a uint16 byte length and the UTF-8
identifier, then count × dimension float32, each vector of unit length.
"""
import os
import re
import struct

import numpy as np
import onnxruntime as ort
from huggingface_hub import hf_hub_download
from tokenizers import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "Xenova/mobileclip_s0"

# Vision's identifiers say little to a CLIP text encoder; these read like what is in the picture.
ENGLISH = {
    "interior_room": "a room indoors", "house_single": "a house", "water_body": "a body of water",
    "consumer_electronics": "electronics", "printed_page": "a printed page of text", "tea_drink": "a cup of tea",
    "illustrations": "an illustration", "land": "a landscape", "structure": "a structure", "outdoor": "outdoors",
    "sunset_sunrise": "a sunset or sunrise", "adult": "an adult", "cloudy": "a cloudy sky", "agriculture": "a farm field",
    "automobile": "a car", "night_sky": "the night sky",
}
TEMPLATES = ["a photo of {}.", "a photo of the {}.", "a picture of {}."]

# Labels the macOS app does not have (Vision does not need them): without them, a picture of nothing in particular — a
# blur of colours, a pattern — lands on whichever word is least unlike it ("screenshot", "rainbow").
EXTRA = {"abstract": "an abstract pattern of colors", "colorful": "colorful blurred shapes", "pattern": "a pattern",
         "texture": "a texture"}


def labels():
    source = open(os.path.join(HERE, "..", "..", "Sources", "POLabels.m"), encoding="utf-8").read()
    table = "".join(re.findall(r'@"([^"]*)"', source.split("POLabelAliases =")[1].split(";")[0]))
    return [entry.split("=")[0] for entry in table.split("|") if "=" in entry] + list(EXTRA)


def main():
    tokenizer = Tokenizer.from_file(hf_hub_download(REPO, "tokenizer.json"))
    text = ort.InferenceSession(hf_hub_download(REPO, "onnx/text_model.onnx"))
    names = labels()
    vectors = []
    for name in names:
        phrase = EXTRA.get(name) or ENGLISH.get(name, name.replace("_", " "))
        ids = [tokenizer.encode(t.format(phrase)).ids[:77] for t in TEMPLATES]
        ids = np.array([i + [0] * (77 - len(i)) for i in ids], dtype=np.int64)
        out = text.run(None, {"input_ids": ids})[0]
        out /= np.linalg.norm(out, axis=1, keepdims=True)
        mean = out.mean(axis=0)
        vectors.append(mean / np.linalg.norm(mean))
    vectors = np.array(vectors, dtype=np.float32)
    path = os.path.join(HERE, "..", "PhotoOrganizer", "Resources", "clip-labels.bin")
    with open(path, "wb") as f:
        f.write(b"POCL" + struct.pack("<ii", len(names), vectors.shape[1]))
        for name in names:
            data = name.encode("utf-8")
            f.write(struct.pack("<H", len(data)) + data)
        f.write(vectors.tobytes())
    print(f"{len(names)} labels -> {os.path.normpath(path)}")


if __name__ == "__main__":
    main()
