"""Runs a Vision Transformer from Hugging Face with MLX: a nudity classifier or a face-embedding model.

Started by Photo Organizer as:  python vit_mlx.py <model snapshot folder> [embed]

Protocol (binary stdin, text stdout):
  -> one line of JSON once the model is loaded: {"ready": true, "size": N} or {"error": "..."}
  <- N*N*3 bytes: one RGB image, 8 bits per channel, already resized (and, for faces, aligned) by the app
  -> one line: the probability (0..1) that the image is NSFW,
     or with "embed": the L2-normalised embedding scaled to -127..127, as comma-separated integers
Understands both weight layouts found on Hugging Face: timm (Marqo, the ArcFace model) and transformers
(Falconsai, AdamCodd).
"""
import json
import os
import re
import sys

import numpy as np
import mlx.core as mx
import mlx.nn as nn


def load(folder, embed):
    with open(os.path.join(folder, "config.json")) as f:
        config = json.load(f)
    weights = mx.load(os.path.join(folder, "model.safetensors"))
    p = {}

    if "architecture" in config:  # timm
        blocks = 1 + max(int(m.group(1)) for k in weights if (m := re.match(r"blocks\.(\d+)\.", k)))
        dim = weights["cls_token"].shape[-1]
        heads = {192: 3, 384: 6, 768: 12, 1024: 16}[dim]
        eps = 1e-6
        labels = [name.lower() for name in config.get("label_names", [])]
        cfg = config.get("pretrained_cfg", {})
        mean, std = cfg.get("mean", [0.5] * 3), cfg.get("std", [0.5] * 3)
        p["cls"], p["pos"] = weights["cls_token"], weights["pos_embed"]
        p["patch_w"], p["patch_b"] = weights["patch_embed.proj.weight"], weights["patch_embed.proj.bias"]
        for i in range(blocks):
            src = f"blocks.{i}."
            for name, key in [("n1", "norm1"), ("qkv", "attn.qkv"), ("proj", "attn.proj"), ("n2", "norm2"),
                              ("fc1", "mlp.fc1"), ("fc2", "mlp.fc2")]:
                p[f"{i}.{name}_w"], p[f"{i}.{name}_b"] = weights[src + key + ".weight"], weights[src + key + ".bias"]
        p["norm_w"], p["norm_b"] = weights["norm.weight"], weights["norm.bias"]
        p["head_w"], p["head_b"] = weights["head.weight"], weights["head.bias"]
    else:  # transformers ViTForImageClassification
        blocks, heads = config["num_hidden_layers"], config["num_attention_heads"]
        eps = config.get("layer_norm_eps", 1e-12)
        labels = [config["id2label"][str(i)].lower() for i in range(len(config["id2label"]))]
        mean, std = [0.5] * 3, [0.5] * 3
        pre = os.path.join(folder, "preprocessor_config.json")
        if os.path.exists(pre):
            with open(pre) as f:
                pre = json.load(f)
            mean, std = pre.get("image_mean", mean), pre.get("image_std", std)
        e = "vit.embeddings."
        p["cls"], p["pos"] = weights[e + "cls_token"], weights[e + "position_embeddings"]
        p["patch_w"], p["patch_b"] = weights[e + "patch_embeddings.projection.weight"], weights[e + "patch_embeddings.projection.bias"]
        for i in range(blocks):
            src = f"vit.encoder.layer.{i}."
            a = src + "attention.attention."
            p[f"{i}.qkv_w"] = mx.concatenate([weights[a + n + ".weight"] for n in ("query", "key", "value")], axis=0)
            p[f"{i}.qkv_b"] = mx.concatenate([weights[a + n + ".bias"] for n in ("query", "key", "value")], axis=0)
            for name, key in [("n1", "layernorm_before"), ("proj", "attention.output.dense"), ("n2", "layernorm_after"),
                              ("fc1", "intermediate.dense"), ("fc2", "output.dense")]:
                p[f"{i}.{name}_w"], p[f"{i}.{name}_b"] = weights[src + key + ".weight"], weights[src + key + ".bias"]
        p["norm_w"], p["norm_b"] = weights["vit.layernorm.weight"], weights["vit.layernorm.bias"]
        p["head_w"], p["head_b"] = weights["classifier.weight"], weights["classifier.bias"]

    nsfw = None if embed else next(i for i, name in enumerate(labels) if name in ("nsfw", "porn", "explicit"))
    patch = p["patch_w"].shape[-1]
    # The patch convolution has stride == kernel, so it is a linear layer over flattened patches (channels last).
    p["patch_w"] = p["patch_w"].transpose(0, 2, 3, 1).reshape(p["patch_w"].shape[0], -1)
    side = int(round((p["pos"].shape[1] - 1) ** 0.5)) * patch
    meta = dict(blocks=blocks, heads=heads, eps=eps, patch=patch, size=side, nsfw=nsfw,
                mean=mx.array(mean) * 255.0, std=mx.array(std) * 255.0)
    return p, meta


def layer_norm(x, w, b, eps):
    mean = x.mean(axis=-1, keepdims=True)
    var = ((x - mean) ** 2).mean(axis=-1, keepdims=True)
    return (x - mean) * mx.rsqrt(var + eps) * w + b


def linear(x, w, b):
    return x @ w.T + b


def forward(p, m, image):
    size, patch, heads = m["size"], m["patch"], m["heads"]
    grid = size // patch
    x = (image.astype(mx.float32) - m["mean"]) / m["std"]
    x = x.reshape(grid, patch, grid, patch, 3).transpose(0, 2, 1, 3, 4).reshape(1, grid * grid, patch * patch * 3)
    x = linear(x, p["patch_w"], p["patch_b"])
    x = mx.concatenate([p["cls"], x], axis=1) + p["pos"]
    tokens, dim = x.shape[1], x.shape[2]
    scale = (dim // heads) ** -0.5
    for i in range(m["blocks"]):
        h = layer_norm(x, p[f"{i}.n1_w"], p[f"{i}.n1_b"], m["eps"])
        qkv = linear(h, p[f"{i}.qkv_w"], p[f"{i}.qkv_b"]).reshape(1, tokens, 3, heads, dim // heads).transpose(2, 0, 3, 1, 4)
        attention = mx.softmax((qkv[0] @ qkv[1].transpose(0, 1, 3, 2)) * scale, axis=-1)
        h = (attention @ qkv[2]).transpose(0, 2, 1, 3).reshape(1, tokens, dim)
        x = x + linear(h, p[f"{i}.proj_w"], p[f"{i}.proj_b"])
        h = layer_norm(x, p[f"{i}.n2_w"], p[f"{i}.n2_b"], m["eps"])
        x = x + linear(nn.gelu(linear(h, p[f"{i}.fc1_w"], p[f"{i}.fc1_b"])), p[f"{i}.fc2_w"], p[f"{i}.fc2_b"])
    x = layer_norm(x[:, 0], p["norm_w"], p["norm_b"], m["eps"])
    x = linear(x, p["head_w"], p["head_b"])
    if m["nsfw"] is None:
        return x[0] * mx.rsqrt((x[0] * x[0]).sum() + 1e-12)
    return mx.softmax(x, axis=-1)[0, m["nsfw"]]


def main():
    out = sys.stdout
    try:
        embed = len(sys.argv) > 2 and sys.argv[2] == "embed"
        params, meta = load(sys.argv[1], embed)
        size = meta["size"]
        mx.eval(forward(params, meta, mx.zeros((size, size, 3), dtype=mx.uint8)))  # warm-up; also proves the weights fit
    except Exception as error:  # reported to the app, which shows it to the user
        out.write(json.dumps({"error": f"{type(error).__name__}: {error}"}) + "\n")
        out.flush()
        return 1
    out.write(json.dumps({"ready": True, "size": size}) + "\n")
    out.flush()

    count = size * size * 3
    stdin = sys.stdin.buffer
    while True:
        data = stdin.read(count)
        if len(data) < count:
            return 0
        image = mx.array(np.frombuffer(data, dtype=np.uint8).reshape(size, size, 3))
        result = forward(params, meta, image)
        if embed:
            out.write(",".join(str(int(v)) for v in mx.round(result * 127).tolist()) + "\n")
        else:
            out.write(f"{result.item():.5f}\n")
        out.flush()


if __name__ == "__main__":
    sys.exit(main())
