"""Builds Resources/clip-kinds.bin: MobileCLIP S0 text vectors of what a photo, a picture and a collage look like.

A picture (postcard, meme, icon, quote card) is told from a photo by asking CLIP which of these descriptions an image
is closest to — how it was made, not what is in it: a photo of a notebook page is a photo, a card with a photo of a
person and wishes on it is a picture. Computing the text vectors once here means the apps need only MobileCLIP's image
half: the macOS app runs Apple's Core ML export (apple/coreml-mobileclip), Windows the ONNX one (Xenova/mobileclip_s0) —
the same weights, the same vectors.

    python Tools/make_clip_kinds.py      (needs: numpy onnxruntime tokenizers huggingface_hub)

File layout (little-endian): "POCK", int32 dimension, int32 group count (3: photo, picture, collage), then per group an
int32 count and count × dimension float32, each vector of unit length.
"""
import os
import struct

import numpy as np
import onnxruntime as ort
from huggingface_hub import hf_hub_download
from tokenizers import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "Xenova/mobileclip_s0"

PHOTO = [
    "a photo", "a photo taken with a phone", "a photo of a person", "a photo of people", "a photo of a child",
    "a photo of a baby", "a selfie", "a photo of a family", "a photo of a handwritten notebook page", "a photo of a document",
    "a photo of a paper sheet", "a photo of a room", "a photo of flowers", "a photo of food", "a photo of a street",
    "a photo of nature", "a blurry photo", "a photo of a screen", "a photo of a pet", "a photo of a landscape",
    "a photo of a child drawing on a board", "a photo of a child playing", "a photo of a kid with toys", "a photo of a whiteboard",
    "a photo of a book page", "a photo of a person holding paper", "a photo of a tattoo",
    "a photo of a church service", "a photo of a priest in a church", "a photo of people in a church",
    "a photo of a person holding a picture",
    "a photo of a museum", "a photo of a celebration",
]
PICTURE = [
    "a greeting card", "a digital greeting card with text", "a postcard with flowers and text", "a meme", "an image with a quote",
    "a religious icon", "a digital illustration", "a cartoon", "computer graphics", "vector art", "clip art",
    "an advertisement banner", "a poster with text", "an animated sticker", "a text on a colorful background",
    "a greeting card with a photo of a person and text", "a congratulations card", "a quote card", "a happy birthday card",
    "a good morning card",
]
COLLAGE = [
    "a collage of several photos", "a grid of family photos", "a photo collage", "several photos arranged together",
    "a collage of photos of people", "a collage of photos in frames",
]


def main():
    tokenizer = Tokenizer.from_file(hf_hub_download(REPO, "tokenizer.json"))
    session = ort.InferenceSession(hf_hub_download(REPO, "onnx/text_model.onnx"))
    groups = []
    for texts in (PHOTO, PICTURE, COLLAGE):
        ids = []
        for text in texts:
            encoded = tokenizer.encode(text).ids[:77]
            ids.append(encoded + [0] * (77 - len(encoded)))
        vectors = session.run(None, {session.get_inputs()[0].name: np.array(ids, dtype=np.int64)})[0]
        groups.append((vectors / np.linalg.norm(vectors, axis=1, keepdims=True)).astype("<f4"))
    out = os.path.join(HERE, "..", "Resources", "clip-kinds.bin")
    with open(out, "wb") as f:
        f.write(b"POCK" + struct.pack("<ii", groups[0].shape[1], len(groups)))
        for vectors in groups:
            f.write(struct.pack("<i", len(vectors)) + vectors.tobytes())
    print("wrote", out, [len(g) for g in groups])


if __name__ == "__main__":
    main()
