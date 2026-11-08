"""Python driver for the BRAM AI chip with the AXI-Stream + DMA interface.

The DMA streams a whole batch of sentences into top_axis and the results
back into memory, so Python makes one transfer per batch instead of one
register write per byte.

Input stream (16 bits per byte):  [7:0] byte, [8] last byte of a sentence.
  The DMA sets TLAST on the last element of the buffer, which must be the
  last byte of the batch's last sentence.
Output stream (32 bits per sentence): [1:0] class, [3:2] argmax.
  top_axis sets TLAST on the last sentence's result, which completes the
  receive transfer.

One batch at a time: each batch must be fully received before the next
starts (top_axis resets its sentence counters at the end of a batch).
"""
import time
import numpy as np
from pynq import Overlay, allocate

LAST = 0x100
LABELS = ['book_flight', 'book_hotel', 'calories', 'unknown']


def encode_batch(texts):
    """Builds the 16-bit input stream for a list of sentences."""
    data = [t.encode('ascii') for t in texts]
    if not data or any(len(d) == 0 for d in data):
        raise ValueError('every sentence needs at least one byte')
    words = np.frombuffer(b''.join(data), dtype=np.uint8).astype(np.uint16)
    ends = np.cumsum([len(d) for d in data]) - 1
    words[ends] |= LAST
    return words


def decode_results(words):
    """Splits the 32-bit result words into (classes, argmaxes)."""
    words = np.asarray(words, dtype=np.uint32)
    return words & 3, (words >> 2) & 3


def _free(buf):
    # The method name differs between PYNQ versions.
    for name in ('freebuffer', 'free_buffer', 'close'):
        if hasattr(buf, name):
            getattr(buf, name)()
            return


class BramDma:
    def __init__(self, bitfile='bram_dma.bit'):
        self.overlay = Overlay(bitfile)
        self.dma = self.overlay.axi_dma_0
        self.inbuf = None
        self.outbuf = None

    def _buffer(self, current, n, dtype):
        """A physically contiguous buffer of exactly n elements, reused while
        the size stays the same. Exact sizes matter because older PYNQ versions
        always transfer the whole buffer."""
        if current is not None and len(current) == n:
            return current
        if current is not None:
            _free(current)
        return allocate(shape=(n,), dtype=dtype)

    def _wait(self, channel, timeout_s):
        deadline = time.monotonic() + timeout_s
        while not channel.idle:
            if time.monotonic() > deadline:
                raise TimeoutError(
                    'DMA did not finish: check that the last result has TLAST set '
                    'and that the previous batch completed')
        channel.wait()   # lets PYNQ finish its bookkeeping (returns at once when idle)

    def run_words(self, words, n_sentences, timeout_s=5.0):
        """Sends an already-encoded stream and returns the raw result words."""
        self.inbuf = self._buffer(self.inbuf, len(words), np.uint16)
        self.outbuf = self._buffer(self.outbuf, n_sentences, np.uint32)
        self.inbuf[:] = words
        self.inbuf.flush()

        # Start receiving first, so the chip's results always have somewhere to go.
        self.dma.recvchannel.transfer(self.outbuf)
        self.dma.sendchannel.transfer(self.inbuf)
        self._wait(self.dma.sendchannel, timeout_s)
        self._wait(self.dma.recvchannel, timeout_s)

        self.outbuf.invalidate()
        return np.array(self.outbuf)

    def classify_batch(self, texts, timeout_s=5.0):
        """Classifies a list of sentences in one DMA transfer.
        Returns (classes, argmaxes) as NumPy arrays."""
        words = encode_batch(texts)
        return decode_results(self.run_words(words, len(texts), timeout_s))

    def classify(self, text):
        """One sentence (a batch of one). Returns (class, argmax)."""
        cls, argmax = self.classify_batch([text])
        return int(cls[0]), int(argmax[0])
