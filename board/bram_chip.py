"""Python driver for the BRAM AI chip on the PYNQ-Z2.

Talks to top_axi over AXI4-Lite using the register map in rtl/top_axi.v:

    0x00  DATA     write  [7:0] byte, [8] last byte of the sentence
    0x04  STATUS   read   [0] result ready, [2:1] class, [4:3] argmax
    0x08  ACC0     read   class 0 score (signed)
    0x0C  ACC1     read   class 1 score (signed)
    0x10  ACC2     read   class 2 score (signed)
    0x14  ACC3     read   class 3 score (signed)
    0x18  CONTROL  write  [0] soft reset, [1] clear result ready
    0x1C  CYCLES   read   clock cycles from the first byte to the result
"""
import time
from pynq import MMIO, Overlay

DATA, STATUS, ACC0, CONTROL, CYCLES = 0x00, 0x04, 0x08, 0x18, 0x1C
LAST = 0x100
LABELS = ['book_flight', 'book_hotel', 'calories', 'unknown']


def to_signed(v):
    return v - (1 << 32) if v & 0x80000000 else v


class BramChip:
    def __init__(self, bitfile='bram_chip.bit'):
        self.overlay = Overlay(bitfile)
        info = self.overlay.ip_dict['top_axi_0/s_axi']
        self.mmio = MMIO(info['phys_addr'], info['addr_range'])
        self.reset()

    def reset(self):
        self.mmio.write(CONTROL, 0x1)

    def classify(self, text, timeout_s=1.0, details=True):
        """Sends one sentence and returns (class, argmax, [acc0..acc3], cycles).

        With details=False it only returns the class, skipping the five extra
        register reads (used for timing the minimal inference path)."""
        data = text.encode('ascii')
        if not data:
            raise ValueError('the chip needs at least one byte')

        self.mmio.write(CONTROL, 0x2)  # clear "result ready" from the previous sentence
        for i, b in enumerate(data):
            self.mmio.write(DATA, b | (LAST if i == len(data) - 1 else 0))

        deadline = time.monotonic() + timeout_s
        status = self.mmio.read(STATUS)
        while not status & 1:
            if time.monotonic() > deadline:
                raise TimeoutError('no result from the chip')
            status = self.mmio.read(STATUS)

        cls = (status >> 1) & 3
        if not details:
            return cls
        argmax = (status >> 3) & 3
        accs = [to_signed(self.mmio.read(ACC0 + 4 * k)) for k in range(4)]
        cycles = self.mmio.read(CYCLES)
        return cls, argmax, accs, cycles


def load_vectors(path='vectors.txt'):
    """Reads hw/vectors.txt: len, bytes, acc0..acc3, argmax, class (all hex)."""
    vectors = []
    with open(path) as f:
        for line in f:
            t = [int(x, 16) for x in line.split()]
            n = t[0]
            text = bytes(t[1:1 + n]).decode('ascii')
            accs = [to_signed(v) for v in t[1 + n:5 + n]]
            vectors.append((text, accs, t[5 + n], t[6 + n]))
    return vectors


def run_regression(chip, path='vectors.txt'):
    """The tb_vectors regression on real hardware. Returns the number of errors."""
    errors = 0
    total_s = 0.0
    vectors = load_vectors(path)
    for i, (text, exp_accs, exp_argmax, exp_cls) in enumerate(vectors):
        t0 = time.perf_counter()
        cls, argmax, accs, _ = chip.classify(text)
        total_s += time.perf_counter() - t0
        if (cls, argmax, accs) != (exp_cls, exp_argmax, exp_accs):
            errors += 1
            print(f'Error at {i}: {text!r}')
            print(f'  got      cls {cls} argmax {argmax} acc {accs}')
            print(f'  expected cls {exp_cls} argmax {exp_argmax} acc {exp_accs}')
    n = len(vectors)
    print(f'{n} sentences, {errors} errors, {1e6 * total_s / n:.1f} us per sentence from Python')
    return errors
