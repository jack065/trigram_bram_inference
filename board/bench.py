"""ARM CPU vs FPGA accelerator, on the PYNQ-Z2.

Runs the same model three ways on every sentence in vectors.txt:
  1. plain Python on the ARM
  2. NumPy on the ARM
  3. the FPGA chip, driven from Python over AXI4-Lite
checks that all three give the expected answers, and times them.

Both CPU versions read the same files the hardware was built from
(weights.mem, bias.mem, exp_lut.mem, model_params.vh), so all three
compute exactly the same thing, bit for bit.
"""
import re
import statistics
import string
import time

import numpy as np

NBUCKETS = 2048
PUNCT = set(string.punctuation.encode())


class Model:
    """The exported fixed-point model, plus lookup tables for fast hashing."""

    def __init__(self, folder='.'):
        with open(f'{folder}/model_params.vh') as f:
            vh = f.read()
        q = [0] * 24
        for bit, val in re.findall(r"if \(x\[(\d+)\]\) h3 = h3 \^ \d+'d(\d+);", vh):
            q[int(bit)] = int(val)
        self.thresh_sum = int(re.search(r'THRESH_SUM\s*=\s*(\d+)', vh).group(1))

        words = [int(l, 16) for l in open(f'{folder}/weights.mem')]
        w = np.array(words, dtype='<u4').view(np.int8).reshape(NBUCKETS, 4)
        self.W = w.astype(np.int32)
        self.W_list = [tuple(int(v) for v in row) for row in self.W]
        bias = [int(l, 16) for l in open(f'{folder}/bias.mem')]
        self.bias = [b - (1 << 32) if b & 0x80000000 else b for b in bias]
        self.lut = [int(l, 16) for l in open(f'{folder}/exp_lut.mem')]

        # H3 is XOR-linear, so the hash of a trigram (b0, b1, b2) is
        # T0[b0] ^ T1[b1] ^ T2[b2]: three table lookups instead of 24 bit tests.
        def table(shift):
            out = []
            for b in range(256):
                h = 0
                for i in range(8):
                    if (b >> i) & 1:
                        h ^= q[i + shift]
                out.append(h)
            return out
        self.T = (table(16), table(8), table(0))
        self.T_np = tuple(np.array(t, dtype=np.int32) for t in self.T)

        # Per-byte normalization: drop ASCII punctuation, lowercase A-Z.
        self.keep = [b not in PUNCT for b in range(256)]
        self.norm = [b | 0x20 if 0x41 <= b <= 0x5A else b for b in range(256)]
        self.keep_np = np.array(self.keep)
        self.norm_np = np.array(self.norm, dtype=np.uint8)

    def decide(self, acc):
        """argmax (lowest index wins ties), exp LUT confidence, threshold."""
        argmax = max(range(4), key=lambda k: (acc[k], -k))
        last = len(self.lut) - 1
        s = sum(self.lut[min(acc[argmax] - acc[k], last)] for k in range(4) if k != argmax)
        cls = 3 if argmax == 3 or s > self.thresh_sum else argmax
        return cls, argmax


def cpu_python(text, m):
    """Plain Python: one byte at a time, like the hardware pipeline."""
    acc = list(m.bias)
    T0, T1, T2 = m.T
    keep, norm, W = m.keep, m.norm, m.W_list
    b0 = b1 = 0
    count = 0
    for c in text.encode('ascii'):
        if not keep[c]:
            continue
        b2 = norm[c]
        if count >= 2:
            w = W[T0[b0] ^ T1[b1] ^ T2[b2]]
            acc[0] += w[0]
            acc[1] += w[1]
            acc[2] += w[2]
            acc[3] += w[3]
        else:
            count += 1
        b0, b1 = b1, b2
    cls, argmax = m.decide(acc)
    return cls, argmax, acc


def cpu_numpy(text, m):
    """NumPy: every trigram of the sentence hashed and summed at once."""
    raw = np.frombuffer(text.encode('ascii'), dtype=np.uint8)
    n = m.norm_np[raw[m.keep_np[raw]]]
    acc = list(m.bias)
    if len(n) >= 3:
        h = m.T_np[0][n[:-2]] ^ m.T_np[1][n[1:-1]] ^ m.T_np[2][n[2:]]
        acc = [a + int(v) for a, v in zip(acc, m.W[h].sum(axis=0))]
    cls, argmax = m.decide(acc)
    return cls, argmax, acc


def load_vectors(path='vectors.txt'):
    """Reads vectors.txt: len, bytes, acc0..acc3, argmax, class (all hex)."""
    vectors = []
    with open(path) as f:
        for line in f:
            t = [int(x, 16) for x in line.split()]
            n = t[0]
            text = bytes(t[1:1 + n]).decode('ascii')
            accs = [v - (1 << 32) if v & 0x80000000 else v for v in t[1 + n:5 + n]]
            vectors.append((text, accs, t[5 + n], t[6 + n]))
    return vectors


def check(name, fn, vectors):
    errors = 0
    for i, (text, exp_accs, exp_argmax, exp_cls) in enumerate(vectors):
        cls, argmax, accs = fn(text)
        if (cls, argmax, list(accs)) != (exp_cls, exp_argmax, exp_accs):
            errors += 1
            if errors <= 3:
                print(f'  {name} mismatch at {i}: got {cls} {argmax} {accs}, '
                      f'expected {exp_cls} {exp_argmax} {exp_accs}')
    print(f'{name:16s} {len(vectors)} sentences, {errors} errors')
    return errors


def time_per_sentence(fn, texts, repeats=3):
    """Median time of one call, per sentence, over several passes (microseconds)."""
    per_sentence = []
    for text in texts:
        best = float('inf')
        for _ in range(repeats):
            t0 = time.perf_counter()
            fn(text)
            best = min(best, time.perf_counter() - t0)
        per_sentence.append(best * 1e6)
    return per_sentence


def time_mmio_write(chip, n=10000):
    """Cost of one AXI4-Lite register write from Python (microseconds)."""
    from bram_chip import CONTROL
    t0 = time.perf_counter()
    for _ in range(n):
        chip.mmio.write(CONTROL, 0x2)   # harmless: clears "result ready"
    return (time.perf_counter() - t0) * 1e6 / n


def run(chip=None, folder='.', clock_mhz=142.857, repeats=3):
    m = Model(folder)
    vectors = load_vectors(f'{folder}/vectors.txt')
    texts = [v[0] for v in vectors]
    total_bytes = sum(len(t) for t in texts)

    print('== Correctness ==')
    check('ARM Python', lambda t: cpu_python(t, m), vectors)
    check('ARM NumPy', lambda t: cpu_numpy(t, m), vectors)
    if chip is not None:
        check('FPGA', lambda t: chip.classify(t)[:3], vectors)

    print('\n== Timing (per sentence, best of %d runs) ==' % repeats)
    results = {
        'ARM Python': time_per_sentence(lambda t: cpu_python(t, m), texts, repeats),
        'ARM NumPy': time_per_sentence(lambda t: cpu_numpy(t, m), texts, repeats),
    }
    if chip is not None:
        results['FPGA via AXI-Lite'] = time_per_sentence(
            lambda t: chip.classify(t, details=False), texts, repeats)

    # The chip's own pipeline time if bytes arrived every clock: length + 9 cycles.
    core = [(len(t) + 9) / clock_mhz for t in texts]
    results['FPGA core only'] = core

    base = statistics.median(results['ARM Python'])
    print(f"{'Version':20s} {'median us':>10s} {'mean us':>10s} {'MB/s':>8s} {'vs Python':>10s}")
    for name, us in results.items():
        med = statistics.median(us)
        mbps = total_bytes / sum(us)   # bytes per microsecond = MB/s
        print(f'{name:20s} {med:10.2f} {statistics.mean(us):10.2f} {mbps:8.2f} {base / med:9.1f}x')

    if chip is not None:
        w = time_mmio_write(chip)
        avg_len = total_bytes / len(texts)
        print(f'\nOne AXI4-Lite write from Python: {w:.2f} us')
        print(f'Average sentence: {avg_len:.1f} bytes -> about {avg_len * w:.0f} us '
              f'spent just writing bytes over AXI4-Lite')
        cycles = [chip.classify(t)[3] for t in texts[:50]]
        print(f'CYCLES register (first byte -> result), median: '
              f'{statistics.median(cycles):.0f} cycles = '
              f'{statistics.median(cycles) / clock_mhz:.1f} us at {clock_mhz} MHz')
    return results
