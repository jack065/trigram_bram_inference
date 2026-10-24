import csv
import json
import string
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import confusion_matrix

NBUCKETS = 2048
NORMALIZE = True

# Tunable. Pick values using the CLINC150 val results, not data.csv or test.
C = 3.0              # inverse L2 regularization strength
OTHER_WEIGHT = 0.003  # sample weight of each 'other' training text relative to our intents
THRESHOLD = 0.8      # below this top-class confidence the prediction becomes unknown

# The model has 4 outputs: these three CLINC150 intents plus an 'other' class trained on
# every remaining intent and out-of-scope. Predicting 'other', or any class below
# THRESHOLD confidence, means unknown.
INTENTS = ['book_flight', 'book_hotel', 'calories']
UNKNOWN = len(INTENTS)  # index of the 'other' output, reported as unknown
LABEL_NAMES = INTENTS + ['unknown']

# H3 hash: each of the 24 input bits selects a fixed 11-bit constant, XOR of the
# selected constants is the bucket. Pure XOR trees in hardware, no DSPs.
H3_Q = [1161, 1606, 867, 1845, 1806, 1088, 261, 120,
        1531, 779, 460, 483, 1691, 1412, 807, 1238,
        1120, 1523, 29, 1938, 1879, 1423, 1467, 622]
PUNCTUATION_TABLE = str.maketrans('', '', string.punctuation)

def hash_trigram(b0, b1, b2):
    x = (b0 << 16) | (b1 << 8) | b2
    h = 0
    for i in range(24):
        if (x >> i) & 1:
            h ^= H3_Q[i]
    return h

def featurize(text):
    if NORMALIZE:
        text = text.lower().translate(PUNCTUATION_TABLE)
    data = text.encode('utf-8')
    x = np.zeros(NBUCKETS, dtype=np.float32)
    for i in range(len(data) - 2):
        x[hash_trigram(data[i], data[i + 1], data[i + 2])] += 1
    return x

def quantize_int8(clf):
    # Symmetric per-tensor scale. Features are integer counts, so the bias is
    # quantized to the accumulator scale (int32); logits = acc * scale.
    scale = np.abs(clf.coef_).max() / 127
    W_q = np.clip(np.round(clf.coef_ / scale), -127, 127).astype(np.int8)
    b_q = np.round(clf.intercept_ / scale).astype(np.int32)
    return W_q, b_q, scale

def predict_int8(W_q, b_q, scale, X, threshold=THRESHOLD):
    acc = X.astype(np.int32) @ W_q.T.astype(np.int32) + b_q
    z = (acc - acc.max(axis=1, keepdims=True)) * scale
    conf = 1 / np.exp(z).sum(axis=1)  # softmax probability of the top class
    pred = acc.argmax(axis=1)
    pred[conf < threshold] = UNKNOWN
    return pred, conf

def load_clinc(split_names, path='clinc150/data_full.json'):
    # Our three intents keep their index; every other intent and out-of-scope is 'other'.
    with open(path, 'r', encoding='utf-8') as f:
        clinc = json.load(f)
    rows = [r for s in split_names for r in clinc[s]]
    return [t for t, _ in rows], np.array([INTENTS.index(i) if i in INTENTS else UNKNOWN for _, i in rows])

def load_data(path='data.csv'):
    text, labels = [], []
    with open(path, 'r', encoding='utf-8') as f:
        for row in csv.DictReader(f):
            text.append(row['text'])
            labels.append(int(row['label']))
    return text, np.array(labels)

def report(name, Y, pred):
    known = Y != UNKNOWN
    print(f"\n== {name}: {len(Y)} texts ({known.sum()} known, {(~known).sum()} unknown) ==")
    print(f"Accuracy: {(pred == Y).mean():.3f}")
    print(f"Known texts classified correctly: {(pred[known] == Y[known]).mean():.3f}")
    print(f"Unknown texts rejected:           {(pred[~known] == UNKNOWN).mean():.3f}")
    print("Confusion matrix (rows = truth, cols = predicted):")
    print("             " + " ".join(f"{n:>12s}" for n in LABEL_NAMES))
    for n, row in zip(LABEL_NAMES, confusion_matrix(Y, pred, labels=range(len(LABEL_NAMES)))):
        print(f"{n:>12s} " + " ".join(f"{v:12d}" for v in row))

def train_model():
    tr_text, Y_tr = load_clinc(['train', 'oos_train'])
    X_tr = np.stack([featurize(t) for t in tr_text])
    sample_weight = np.where(Y_tr == UNKNOWN, OTHER_WEIGHT, 1.0)
    clf = LogisticRegression(max_iter=3000, C=C).fit(X_tr, Y_tr, sample_weight=sample_weight)
    return clf, Y_tr

if __name__ == '__main__':
    clf, Y_tr = train_model()
    W_q, b_q, scale = quantize_int8(clf)
    print(f"C={C}, OTHER_WEIGHT={OTHER_WEIGHT}, THRESHOLD={THRESHOLD}")
    print(f"Trained on {len(Y_tr)} CLINC150 texts: "
          f"{dict(zip(INTENTS + ['other'], np.bincount(Y_tr).tolist()))}")
    print(f"Weight memory: int8 {W_q.size} B + {b_q.size * 4} B bias, scale {scale:.6f}")

    va_text, va_Y = load_clinc(['val', 'oos_val'])
    X_va = np.stack([featurize(t) for t in va_text])
    pred_va, _ = predict_int8(W_q, b_q, scale, X_va)
    report("CLINC150 val (use this for tuning)", va_Y, pred_va)

    print("\nThreshold sweep on CLINC150 val (known correct / unknown rejected / accepted that are correct):")
    known = va_Y != UNKNOWN
    for th in [0.5, 0.6, 0.7, 0.8, 0.9, 0.95]:
        p, _ = predict_int8(W_q, b_q, scale, X_va, th)
        accepted = p != UNKNOWN
        print(f"  {th:.2f}: {(p[known] == va_Y[known]).mean():.3f} / {(p[~known] == UNKNOWN).mean():.3f}"
              f" / {(p[accepted] == va_Y[accepted]).mean():.3f}")

    text, Y = load_data()
    X = np.stack([featurize(t) for t in text])
    pred, conf = predict_int8(W_q, b_q, scale, X)
    report("data.csv", Y, pred)
    print("\nMistakes:")
    for t, y, p, c in zip(text, Y, pred, conf):
        if y != p:
            print(f"  {LABEL_NAMES[y]:>11s} -> {LABEL_NAMES[p]:<11s} conf {c:.2f}  {t}")

    te_text, te_Y = load_clinc(['test', 'oos_test'])
    X_te = np.stack([featurize(t) for t in te_text])
    pred_te, _ = predict_int8(W_q, b_q, scale, X_te)
    report("CLINC150 test (final check only)", te_Y, pred_te)
