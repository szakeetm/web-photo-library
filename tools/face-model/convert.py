"""Builds the face-embedding model used by the server (FaceNet, Inception-ResNet-v1 trained on
VGGFace2, MIT-licensed weights from facenet-pytorch) as a Core ML package.

Input:  "face" float32 [1, 3, 160, 160], RGB, (pixel - 127.5) / 128, aligned face crop.
Output: "embedding" float32 [1, 512], L2-normalised (cosine similarity = dot product).
Run via make.sh.
"""
import sys
import numpy as np
import torch
import coremltools as ct
from facenet_pytorch import InceptionResnetV1

out = sys.argv[1] if len(sys.argv) > 1 else "FaceNet.mlpackage"
model = InceptionResnetV1(pretrained="vggface2").eval()
example = torch.rand(1, 3, 160, 160) * 2 - 1
traced = torch.jit.trace(model, example)
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="face", shape=(1, 3, 160, 160), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS13,
)
ml.short_description = "FaceNet (Inception-ResNet-v1, VGGFace2) face embeddings, 512-d, L2-normalised"
ml.license = "MIT (facenet-pytorch weights)"
ml.save(out)

# sanity: Core ML output matches PyTorch
ref = model(example).detach().numpy()
got = ml.predict({"face": example.numpy()})["embedding"]
cos = float((ref * got).sum() / (np.linalg.norm(ref) * np.linalg.norm(got)))
print(f"saved {out}; cosine(torch, coreml) = {cos:.5f}")
assert cos > 0.999
