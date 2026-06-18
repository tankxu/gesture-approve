"""用 Vision 提取的 HaGRID 关键点训练一个小手势分类器，导出 Core ML。
类别: like->thumbUp, palm->openPalm, 其余->other
特征: 21 关节(x,y) 以手腕为中心、按手掌大小归一化 -> 42 维（推理端 Swift 用同一套）。
增强: 旋转±35°、水平翻转、缩放、抖动 -> 对相机角度/倾斜鲁棒。
"""
import sys
import numpy as np
import torch
import torch.nn as nn
import coremltools as ct

CSV, OUT = sys.argv[1], sys.argv[2]
CLASSES = ["thumbUp", "openPalm", "other"]
LABEL_MAP = {"like": 0, "palm": 1}   # 其余 -> 2

rows = [l.split(",") for l in open(CSV).read().splitlines() if l.strip()]
X, Y = [], []
for r in rows:
    if len(r) < 43:
        continue
    pts = np.array(list(map(float, r[1:43])), dtype=np.float32).reshape(21, 2)
    X.append(pts)
    Y.append(LABEL_MAP.get(r[0], 2))
X = np.array(X, dtype=np.float32)
Y = np.array(Y, dtype=np.int64)
print("样本:", X.shape, "类别分布:", {c: int((Y == i).sum()) for i, c in enumerate(CLASSES)})


def normalize(pts):  # pts: (N,21,2) -> (N,42) 以手腕为中心 + 手掌尺度归一
    wrist = pts[:, 0:1, :]
    c = pts - wrist
    s = np.sqrt((c ** 2).sum(-1)).mean(-1, keepdims=True)[..., None]
    s = np.maximum(s, 1e-6)
    return (c / s).reshape(pts.shape[0], -1)


def augment(pts):  # pts: (N,21,2)
    n = pts.shape[0]
    out = pts.copy()
    wrist = out[:, 0:1, :].copy()
    out -= wrist
    # 旋转 ±35°
    ang = (np.random.rand(n) * 2 - 1) * (35 * np.pi / 180)
    cos, sin = np.cos(ang), np.sin(ang)
    x, y = out[..., 0].copy(), out[..., 1].copy()
    out[..., 0] = x * cos[:, None] - y * sin[:, None]
    out[..., 1] = x * sin[:, None] + y * cos[:, None]
    # 缩放 ±15%
    out *= (1 + (np.random.rand(n, 1, 1) * 2 - 1) * 0.15)
    # 水平翻转 50%
    flip = np.random.rand(n) < 0.5
    out[flip, :, 0] *= -1
    # 抖动
    out += np.random.randn(*out.shape).astype(np.float32) * 0.02
    out += wrist
    return out


# 划分
idx = np.random.permutation(len(X))
X, Y = X[idx], Y[idx]
nval = max(1, len(X) // 6)
Xtr, Ytr, Xva, Yva = X[nval:], Y[nval:], X[:nval], Y[:nval]

Xva_t = torch.tensor(normalize(Xva))
Yva_t = torch.tensor(Yva)


class MLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(42, 128), nn.ReLU(), nn.Dropout(0.3),
            nn.Linear(128, 64), nn.ReLU(), nn.Dropout(0.2),
            nn.Linear(64, 3),
        )

    def forward(self, x):
        return self.net(x)


model = MLP()
opt = torch.optim.Adam(model.parameters(), lr=1e-3, weight_decay=1e-4)
lossf = nn.CrossEntropyLoss()
best = 0.0
best_state = None
for epoch in range(120):
    model.train()
    perm = np.random.permutation(len(Xtr))
    for i in range(0, len(perm), 256):
        b = perm[i:i + 256]
        xb = torch.tensor(normalize(augment(Xtr[b])))
        yb = torch.tensor(Ytr[b])
        opt.zero_grad()
        loss = lossf(model(xb), yb)
        loss.backward()
        opt.step()
    model.eval()
    with torch.no_grad():
        acc = (model(Xva_t).argmax(1) == Yva_t).float().mean().item()
    if acc > best:
        best, best_state = acc, {k: v.clone() for k, v in model.state_dict().items()}
    if epoch % 20 == 0 or epoch == 119:
        print(f"epoch {epoch}: val_acc={acc:.3f}")
print(f"最佳 val_acc={best:.3f}")
model.load_state_dict(best_state)
model.eval()

# 加 softmax 一起导出
export_model = nn.Sequential(model.net, nn.Softmax(dim=1))
export_model.eval()
ex = torch.rand(1, 42)
traced = torch.jit.trace(export_model, ex)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="landmarks", shape=(1, 42))],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS13,
)
mlmodel.short_description = "HaGRID hand gesture (thumbUp/openPalm/other) from Vision landmarks"
mlmodel.user_defined_metadata["classes"] = ",".join(CLASSES)
mlmodel.save(OUT)
print("导出 ->", OUT)
