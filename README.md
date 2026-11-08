# BRAM AI Chip

A tiny text intent classifier, trained in Python and implemented in Verilog so it can run on an FPGA with its weights stored in block RAM (BRAM).

The design is a small-scale study of the idea behind Cerebras' wafer-scale inference hardware: **keep every weight in on-chip memory, right next to the compute**, so inference is never stalled waiting on off-chip memory.

Given a sentence, the model sorts it into one of four classes:

| Index | Class |
|---|---|
| 0 | `book_flight` |
| 1 | `book_hotel` |
| 2 | `calories` |
| 3 | `unknown` (any other intent, or a low-confidence prediction) |

## Inspiration: Cerebras and the memory wall

On GPUs, inference speed is often limited by memory bandwidth rather than arithmetic. To produce each output, the model's weights have to be streamed in from off-chip DRAM (HBM), and the compute units wait for them. This is known as the *memory wall*.

Cerebras takes a different approach. Its Wafer-Scale Engine is a single wafer-sized chip with hundreds of thousands of cores, each with its own local SRAM. The weights sit in on-chip memory next to the cores that use them, so they're read at on-chip speed and never cross a slow external bus. This is a large part of why Cerebras reports very fast token generation.

This project applies the same principle to a model small enough for one FPGA:

| Cerebras idea | In this project |
|---|---|
| Weights stored in on-chip SRAM, not off-chip DRAM | The full model (2048 × 32-bit weights, 8 KB) sits in FPGA block RAM (`rtl/weight_rom.v`) |
| Memory placed next to the compute that uses it | The weight ROM is inside the accumulator module and feeds the adders directly (`rtl/accum.v`) |
| Wide on-chip memory bandwidth | Each BRAM read returns all 4 class weights at once (one 32-bit word), with one lookup per clock cycle |
| Dataflow: data streams through a fixed pipeline | Bytes stream in one per cycle: normalize → window → hash → lookup → accumulate, with no instruction fetch and no cache misses |
| Low precision for speed and capacity | int8 weights and hashing with XOR only, so no multipliers or DSP blocks are needed |

The result is predictable latency: the answer is ready a fixed 10 clock cycles after the last byte of a sentence. No step ever waits on external memory.

This is a learning project at a vastly smaller scale.

## How it works

1. **Normalize:** lowercase the text and drop ASCII punctuation.
2. **Trigrams:** slide a 3-byte window over the text.
3. **Hash:** map each trigram to one of 2048 buckets with an H3 hash, which uses only XOR gates (no multipliers).
4. **Accumulate:** each bucket stores four int8 weights, one per class. Add them to four 32-bit accumulators that start at the class biases.
5. **Decide:** the largest accumulator is the candidate class. If its softmax confidence is below 0.8, the answer is `unknown`. The confidence check uses an exp lookup table, so no division is needed.

The model is a logistic regression trained on the [CLINC150](https://github.com/clinc/oos-eval) dataset, then quantized to int8. The weight memory is 2048 × 32 bits (8 KB).

```
in_byte ─► [trigram] ─tri_valid, bucket─► [accum + weight_rom] ─done, acc0..3─► [classify + 4× exp_rom] ─► cls
           normalize                       BRAM weight lookup                    argmax
           3-byte window                   int8 sign extension                   exp LUT on score gaps
           H3 hash                         4 accumulators                        confidence threshold
```

The full RTL matches the Python model bit for bit: on all 514 sentences in `hw/vectors.txt`, the four scores, the argmax, and the final class are identical, including when sentences stream back to back at one byte per clock.

### Timing of one sentence

The sender raises `in_valid` with each byte, and `in_last` with the final byte. Counting the edge that takes in the last byte as edge 1:

| Clock edge | Event |
|---|---|
| 1 | `trigram` takes in the last byte and outputs the final bucket |
| 2 | the weight ROM returns its word |
| 3 | the accumulators add it, and `done` goes high. The accumulators reload the biases on the next edge, ready for the next sentence. |
| 4 | `classify` S1: pairwise compares, and a copy of the four scores is saved |
| 5 | S2: final compare → argmax |
| 6 | S3a: differences from the winning score |
| 7 | S3b: clamp the differences into exp LUT addresses |
| 8 | exp LUT read |
| 9 | exp LUT output register (inside the block RAM) |
| 10 | S5: sum and threshold. `cls_valid` goes high with the answer on `cls` and `argmax`. |

The decision is spread over 7 pipeline stages so that each clock cycle does only a little work, which is what lets the design run at 150 MHz. Every value a later stage needs travels along with its sentence, one stage per edge. So a new sentence can start immediately: while `classify` decides one sentence, `trigram` and `accum` are already working on the next.

## Repository layout

| Path | Contents |
|---|---|
| `train.py` | Trains and quantizes the model, then reports accuracy on CLINC150 and `data.csv` |
| `export.py` | Exports the hardware files into `hw/`, plus a bit-exact Python model of the RTL (`hw_predict`). Its edge cases include directed tests for overlapping sentences. |
| `hw/` | Generated by `export.py`: `weights.mem`, `bias.mem`, `exp_lut.mem`, `model_params.vh`, `vectors.txt` |
| `rtl/trigram.v` | Byte normalization, 3-byte window, H3 hash → `bucket`; passes the end-of-sentence flag along |
| `rtl/weight_rom.v` | 2048 × 32-bit weight ROM with a synchronous read, mapped to block RAM |
| `rtl/accum.v` | Weight lookup, int8 sign extension, four signed accumulators, `done` flag, automatic bias reload between sentences |
| `rtl/exp_rom.v` | 2048 × 16-bit exp lookup table ROM, using the block RAM's output register (2-cycle read) |
| `rtl/classify.v` | 7-stage decision pipeline: argmax, exp LUT confidence, threshold → `cls` |
| `rtl/top.v` | Connects `trigram`, `accum` and `classify` |
| `rtl/top_axi.v` | AXI4-Lite wrapper around `top`, so the Zynq's ARM processor can send text and read results (see [Register map](#register-map)) |
| `rtl/top_axis.v` | AXI-Stream wrapper around `top` for use with a DMA: bytes stream in, one result word per sentence streams out (see [Stream formats](#stream-formats)) |
| `rtl/fifo.v` | 64-entry result FIFO used by `top_axis`, so results wait when the receiving DMA isn't ready |
| `tb/` | One testbench per module, plus `tb_vectors.v` (full regression, one sentence at a time), `tb_stream.v` (full regression with sentences streaming back to back), `tb_axi.v` (the AXI4-Lite wrapper, driven like the ARM would), `tb_fifo.v` (the FIFO against a reference queue) and `tb_axis.v` (the stream wrapper, driven like the two DMA channels, with random stalls) |
| `board/bram_chip.py` | Python driver for the AXI4-Lite version: loads the bitstream, sends sentences, reads results, runs the regression on hardware |
| `board/bram_dma.py` | Python driver for the AXI-Stream + DMA version: classifies a whole batch of sentences in one DMA transfer |
| `board/bench.py` | Benchmark: the same model in plain Python, in NumPy, and on the FPGA (both versions), checked for identical answers and timed |
| `build.tcl` | Recreates the Vivado project: part, sources, include directory, constraint, out-of-context synthesis |
| `timing.xdc` | Clock constraint (150 MHz) |
| `clinc150/` | CLINC150 dataset |
| `data.csv` | Small hand-written test set |

## Getting started

### Requirements

- Python 3 with `numpy` and `scikit-learn`
- [Icarus Verilog](https://bleyer.org/icarus/) (`iverilog`, `vvp`). GTKWave comes with it and is optional, for viewing waveforms.
- For synthesis only: AMD Vivado (built with 2025.2). The free ML Standard edition supports the XC7Z020. In the installer, Zynq-7000 device support is the only device family you need.

### 1. Train and export the model

```
python train.py     # train and print accuracy reports
python export.py    # retrain and write the hardware files into hw/
```

`hw/` is already committed, so you only need `export.py` after changing the model.

### 2. Run the simulations

Run these from the repository root: the testbenches load `hw/*.mem` by relative path. All code is plain Verilog-2005.

```
# Trigram front end (self-checking: prints ALL TESTS PASSED)
iverilog -o sim_tri rtl/trigram.v tb/tb_trigram.v
vvp sim_tri

# Weight ROM
iverilog -o sim_rom rtl/weight_rom.v tb/tb_weight_rom.v
vvp sim_rom

# Accumulator
iverilog -o sim_acc rtl/weight_rom.v rtl/accum.v tb/tb_accum.v
vvp sim_acc

# Decision logic (self-checking: prints Error count: 0)
iverilog -o sim_cls rtl/exp_rom.v rtl/classify.v tb/tb_classify.v
vvp sim_cls

# Full chip on a few hand-picked sentences
iverilog -o sim_top rtl/trigram.v rtl/weight_rom.v rtl/accum.v rtl/exp_rom.v rtl/classify.v rtl/top.v tb/tb_top.v
vvp sim_top

# Full regression: every sentence in hw/vectors.txt, one at a time
iverilog -o sim_vec rtl/trigram.v rtl/weight_rom.v rtl/accum.v rtl/exp_rom.v rtl/classify.v rtl/top.v tb/tb_vectors.v
vvp sim_vec

# Streaming regression: the same sentences sent back to back without waiting
iverilog -o sim_str rtl/trigram.v rtl/weight_rom.v rtl/accum.v rtl/exp_rom.v rtl/classify.v rtl/top.v tb/tb_stream.v
vvp sim_str

# AXI4-Lite wrapper (self-checking: prints ALL TESTS PASSED)
iverilog -o sim_axi rtl/trigram.v rtl/weight_rom.v rtl/accum.v rtl/exp_rom.v rtl/classify.v rtl/top.v rtl/top_axi.v tb/tb_axi.v
vvp sim_axi

# Result FIFO (self-checking: prints ALL TESTS PASSED)
iverilog -o sim_fifo rtl/fifo.v tb/tb_fifo.v
vvp sim_fifo

# AXI-Stream wrapper (self-checking: prints ALL TESTS PASSED)
iverilog -o sim_axis rtl/trigram.v rtl/weight_rom.v rtl/accum.v rtl/exp_rom.v rtl/classify.v rtl/top.v rtl/fifo.v rtl/top_axis.v tb/tb_axis.v
vvp sim_axis
```

`tb_axis` acts like both DMA channels. It sends all 514 sentences as one batch at full speed, then in batches of 1, 2, 7, 50 and the rest with random stalls on both sides, then stalls the receiver for 2000 cycles while 100 one-byte sentences arrive, which forces backpressure. It checks every result word and that `TLAST` lands on exactly the last result of each batch. Deliberately broken versions of the wrapper (no backpressure, no `TLAST`, input not gated by `TREADY`, a FIFO count bug) all fail it.

The two regressions are the main checks. Expected output:

```
514 sentences, 0 errors                      (tb_vectors)
514 sent, 514 done, 514 cls, 0 errors        (tb_stream)
```

`tb_stream` has a sender and a checker running in parallel. The sender pushes bytes in at full speed (one per clock, across sentence boundaries), and the checker compares each `done` and `cls_valid` against the expected results in order. That puts several sentences inside the pipeline at once. The last six vectors are directed tests: a confident `book_flight`, `book_hotel` or `calories` sentence followed immediately by a 1–2 byte sentence. These are the cases where a pipeline stage could mix up two sentences' data. A deliberately broken design (an `argmax` copy taken one stage too early) passes the other 508 sentences but fails these.

Most of the expected answers in `vectors.txt` are `unknown` (482 of 514), because most of the CLINC150 test sentences belong to other intents. The rest are 7 `book_flight`, 11 `book_hotel` and 14 `calories`. The regressions check that the hardware matches the Python model exactly. The model's accuracy is reported separately by `train.py`.

Expected scores from the hand-picked test (`tb_top`):

| Input | acc0 | acc1 | acc2 | acc3 |
|---|---|---|---|---|
| `abc` | -242 | -212 | -191 | 645 |
| `Hi, Bob!` | -244 | -197 | -200 | 641 |
| `!!!` | -240 | -212 | -191 | 643 |
| `ab` | -240 | -212 | -191 | 643 |

To view waveforms, open the `.vcd` file a testbench writes (for example `gtkwave tri.vcd`).

### 3. Synthesize in Vivado (optional)

`build.tcl` recreates the Vivado project from the files in this repository. It finds the source files relative to its own location, and creates the project in the folder Vivado is running from. Run it from the repository root, so the project lands in the git-ignored `vivado_bram_chip/`:

```
vivado -mode batch -source build.tcl
```

Or, in the Vivado GUI: **Tools → Run Tcl Script…** and choose `build.tcl`.

This creates `vivado_bram_chip/` with:
- the part (`xc7z020clg400-1`). No board files are needed for out-of-context synthesis.
- the design sources from `rtl/`, and the `.mem` files and `model_params.vh` from `hw/`
- the repository root as the Verilog include directory, so `` `include "hw/model_params.vh" `` resolves
- `timing.xdc` as the constraint
- synthesis in out-of-context mode (`-mode out_of_context`)
- the testbenches as simulation sources

Then run synthesis and implementation from the GUI (**Run Implementation**), or in the Tcl console:

```
launch_runs impl_1 -jobs 4
wait_on_run impl_1
open_run impl_1
report_timing_summary
report_utilization -hierarchical
```

`vivado_bram_chip/` is generated output: logs, checkpoints, caches. It can always be rebuilt from `build.tcl`, so it's listed in `.gitignore`.

### 4. Run on the PYNQ-Z2

There are two board versions of the chip. They share the same core (`rtl/top.v`) and differ only in how the ARM processor gets data in and out:

| Version | Wrapper | How data moves | Best for |
|---|---|---|---|
| AXI4-Lite | `top_axi` | Python writes one byte per register write, then reads the result | one sentence at a time, reading the scores |
| AXI-Stream + DMA | `top_axis` | a DMA engine streams a whole batch from memory and writes the results back | throughput: many sentences per call |

#### AXI4-Lite version: build the board design in Vivado

A separate Vivado project, targeting the **PYNQ-Z2 board** (the PYNQ-Z2 board files are needed for this one):

1. Add the files from `rtl/` (including `top_axi.v`) and `hw/`, and set the repository root as the Verilog include directory. Don't add `timing.xdc`: the clock comes from the processor.
2. Create a block design and add the **ZYNQ7 Processing System**. Run **Block Automation** with the board preset.
3. In the Zynq settings, set **FCLK_CLK0** to 150 MHz. The processor derives it from its 1000 MHz IO PLL, so the actual clock is **142.857 MHz** (÷7).
4. **Add Module → `top_axi`**, then **Run Connection Automation**. This adds an AXI SmartConnect between the processor's `M_AXI_GP0` port and `top_axi`'s `s_axi` interface, plus a reset block.
5. Validate the design, **Create HDL Wrapper**, set the wrapper as top, and generate the bitstream.

"Add Module" reports that it can't open `hw/model_params.vh`. That only affects how the block is drawn; synthesis itself uses the include directory and finds the file.

#### Copy the files to the board

Two files from the Vivado project, renamed to the same base name:
- `<project>.runs/impl_1/design_1_wrapper.bit` → `bram_chip.bit`
- `<project>.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh` → `bram_chip.hwh`

Then copy them into one folder on the board, together with `board/bram_chip.py`, `board/bench.py` and the files in `hw/` (`vectors.txt`, `weights.mem`, `bias.mem`, `exp_lut.mem`, `model_params.vh`). Use Jupyter's Upload button, or the network share `\\<board IP>\xilinx` (user and password `xilinx`).

With the board's Ethernet port plugged into your router, Jupyter is at `http://<board IP>:9090` (password `xilinx`). Your router's list of connected devices shows the board's address.

#### Use it from Python

```python
from bram_chip import BramChip, run_regression, LABELS

chip = BramChip("bram_chip.bit")      # programs the FPGA and soft-resets the chip
cls, argmax, accs, cycles = chip.classify("Book me a flight from Boston to Denver next Friday.")
print(LABELS[cls], accs)              # book_flight [674, -71, -557, -49]

run_regression(chip)                  # 514 sentences, 0 errors on real hardware
```

Loading the bitstream programs the FPGA directly from Python, with no separate flashing step. The FPGA forgets the design when the board loses power, so create `BramChip` again after a restart.

To compare the ARM CPU with the FPGA (see [Performance](#performance-on-the-board)):

```python
import bench
results = bench.run(chip)
```

#### Register map

`top_axi` appears to the processor as eight 32-bit registers. PYNQ finds its base address from the `.hwh` file (`ip_dict['top_axi_0/s_axi']`).

| Offset | Access | Contents |
|---|---|---|
| `0x00` | write | **DATA:** [7:0] byte, [8] last byte of the sentence. Each write sends one byte into the chip. |
| `0x04` | read | **STATUS:** [0] result ready, [2:1] class, [4:3] argmax |
| `0x08`–`0x14` | read | the four class scores (signed, 32-bit), captured when the sentence finishes |
| `0x18` | write | **CONTROL:** [0] soft reset, [1] clear "result ready" |
| `0x1C` | read | **CYCLES:** clock cycles from the first byte to the result |

The chip's `cls_valid` lasts only one clock cycle, so the wrapper latches each result and holds "result ready" until Python clears it. A sentence goes: clear, write each byte, poll STATUS, read the result.

#### AXI-Stream + DMA version: build the board design in Vivado

Another PYNQ-Z2 board project, set up like the AXI4-Lite one (files from `rtl/` including `fifo.v` and `top_axis.v`, files from `hw/`, the repository root as include directory, no `timing.xdc`):

1. Add the **ZYNQ7 Processing System** and run **Block Automation** with **Apply Board Preset** ticked. In its settings, set **FCLK_CLK0** to 150 MHz, and enable **PS-PL Configuration → HP Slave AXI Interface → S AXI HP0**, the high-speed port the DMA uses to reach DDR memory.
2. Add **AXI Direct Memory Access**: scatter-gather **off**, **width of buffer length register 26 bits** (the default 14 bits limits a transfer to 16 KB), MM2S stream width **16**, S2MM stream width **32**.
3. **Add Module → `top_axis`**, and connect the streams by hand: DMA `M_AXIS_MM2S` → `top_axis` `s_axis`, and `top_axis` `m_axis` → DMA `S_AXIS_S2MM`.
4. **Run Connection Automation** with every option ticked. Then check that **both** of the DMA's memory ports, `M_AXI_MM2S` **and** `M_AXI_S2MM`, connect to `S_AXI_HP0`, and that both have an `HP0_DDR_LOWOCM` entry in the **Address Editor**. If `M_AXI_S2MM` is left unconnected, the DMA can read the text but never write results back: the receive transfer hangs, and `top_axis`'s FIFO fills until backpressure stops the input too.
5. Validate, **Create HDL Wrapper**, set it as top, generate the bitstream, and copy the `.bit` and `.hwh` to the board as **`bram_dma.bit`** and **`bram_dma.hwh`**, together with `board/bram_dma.py`.

#### Stream formats

| Stream | Width | Contents |
|---|---|---|
| Input (DMA → `top_axis`) | 16 bits per byte | [7:0] byte, [8] last byte of a sentence. The DMA sets `TLAST` on the last element of the buffer. |
| Output (`top_axis` → DMA) | 32 bits per sentence | [1:0] class, [3:2] argmax. `top_axis` sets `TLAST` on the last sentence's result, which completes the receive transfer. |

Sentence boundaries travel inside the data (bit 8) because the DMA only marks the end of a whole buffer. `top_axis` counts sentences in and results out to find which result gets `TLAST`. So each batch must be fully received before the next one starts, which the driver always does.

#### Use the DMA version from Python

```python
from bram_dma import BramDma, LABELS
import bench

dma = BramDma("bram_dma.bit")
cls, argmax = dma.classify("Book me a flight from Boston to Denver next Friday.")
print(LABELS[cls])                                   # book_flight

classes, argmaxes = dma.classify_batch(list_of_sentences)   # one DMA transfer for the whole batch
rows = bench.run_dma(dma)                            # correctness + timing by batch size
```

The driver allocates DMA buffers of exactly the batch's size and reuses them while the size stays the same. PYNQ 2.5's DMA driver always transfers whole buffers.

## Status

- [x] Train and quantize the model, export the memory files
- [x] Load the `.mem` files in Verilog
- [x] Trigram front end: normalize, window, hash (`rtl/trigram.v`)
- [x] Weight ROM in BRAM style (`rtl/weight_rom.v`)
- [x] Signed accumulation starting from the biases (`rtl/accum.v`)
- [x] Top-level datapath matching Python bit for bit (`rtl/top.v`)
- [x] End of sentence: `in_last` input, carried through the pipeline to a `done` flag
- [x] Decision logic (`rtl/classify.v`): argmax (lowest index wins ties), exp LUT with clamped differences, confidence threshold
- [x] Full regression test (`tb/tb_vectors.v`): 514 sentences, 0 errors on scores, argmax and class
- [x] Back-to-back sentences: `accum` reloads the biases by itself after `done`, and every `classify` stage carries its own copy of the data it needs
- [x] Streaming regression (`tb/tb_stream.v`) at one byte per clock, with directed overlap tests and a mutation check
- [x] `` `default_nettype none `` in all RTL files, so a misspelled port connection is a compile error instead of a silent new wire
- [x] Synthesized and implemented for the PYNQ-Z2 (out-of-context): all ROMs in block RAM, timing met at 150 MHz (see [Synthesis results](#synthesis-results))
- [x] AXI4-Lite wrapper (`rtl/top_axi.v`), verified in simulation through the bus alone (`tb/tb_axi.v`)
- [x] Running on the PYNQ-Z2 with the Zynq's ARM processor: 514 sentences, 0 errors on real hardware
- [x] ARM vs FPGA benchmark on the board (`board/bench.py`)
- [x] AXI-Stream wrapper with result FIFO and backpressure (`rtl/top_axis.v`, `rtl/fifo.v`), verified with random stalls (`tb/tb_axis.v`, `tb/tb_fifo.v`)
- [x] AXI-Stream + DMA version running on the PYNQ-Z2: 0 errors, about 50× faster than the ARM for large batches

## TODO

- [ ] **Find sentence boundaries in hardware:** accept plain text with newlines as an 8-bit stream, so Python no longer builds the 16-bit array (82% of the time for large batches) and half as many bytes cross the DMA
- [ ] **Reduce the fixed cost per DMA call** (about 1.1 ms): buffers that bypass the CPU cache, or writing the DMA registers directly instead of going through PYNQ 2.5's driver
- [ ] Re-apply the board preset in the DMA project, so the logic clock is 142.857 MHz instead of 125 MHz
- [ ] Derive the backpressure threshold in `top_axis` (`fifo_count < 48`) from the pipeline depth, and check the worst case in simulation
- [ ] A build script for the board projects (block design, board files, include directory), like `build.tcl` for the out-of-context build
- [ ] **Try 200 MHz:** run at a 5 ns clock and fix the slowest paths (likely candidates: the weight BRAM output register, splitting S5, narrower accumulators)
- [ ] Make `tb_top.v` and `tb_accum.v` self-checking (PASS/FAIL instead of printed values)
- [ ] Cleanup: shrink `count` in `trigram.v` to 2 bits, and rename the instances in `top.v` (`rom1`/`rom2`/`rom3`)
- [ ] Stop tracking the simulation outputs that are already committed (`git rm --cached sim_acc sim_rom`)
- [ ] Scale the model up to use more of the PYNQ-Z2's BRAM (see [Scaling up](#scaling-up-using-more-of-the-pynq-z2))

## Scaling up: using more of the PYNQ-Z2

The current model is deliberately tiny. Its weights take **8 KB**, about **2 of the 140 BRAM36 blocks** (roughly 1%) on the PYNQ-Z2's Zynq XC7Z020. That chip has 140 × 36 Kb of block RAM, or about 560 KB when storing 8-bit data, plus 220 DSP multiplier slices that this design doesn't use yet.

So there's plenty of room for a bigger model, and a bigger model is also a better test of the "keep everything on-chip" idea. Possible directions, roughly from easiest to hardest:

### 1. More hash buckets

2048 buckets means many different trigrams share a bucket (hash collisions), which blurs the features. Going to 16,384 or 65,536 buckets reduces collisions.

- **Hardware change:** small. The bucket address gets wider, and the weight ROM gets deeper.
- **Software change:** set `NBUCKETS` in `train.py`, and regenerate `H3_Q` with constants that are `log2(NBUCKETS)` bits wide. `export.py` checks that every constant is smaller than `NBUCKETS`.

### 2. Longer n-grams: from 3 up to 7, 8, or more

Trigrams only see 3 characters at a time, so a word like "flight" is split into overlapping pieces (`fli`, `lig`, `igh`, ...). Longer n-grams capture more context. A 7- or 8-gram can hold a whole word plus its surrounding spaces (`" flight "`), or span two short words (`"to bost"`), so the model learns word-level and phrase-level patterns directly. **Word-level features** (hashing whole words split on spaces) are a related option.

**Hardware cost scales well:**

- **Window:** the 3-byte shift register becomes an n-byte one, which is just more registers.
- **Hash:** H3 takes `8 × n` input bits. That's 56 bits for a 7-gram and 64 bits for an 8-gram, so one XOR constant per input bit instead of 24. It's still pure XOR logic with no multipliers, and it still fits in a single clock cycle.
- **Throughput is unchanged:** one n-gram per byte, one byte per clock.

**Use several sizes together, not just the longest:**

- Long n-grams are **rare**. Most 8-character strings appear only once or twice in the training data, which leads to more distinct features, more hash collisions for the same bucket count, and a higher risk of overfitting. They need more buckets and benefit from more training data.
- A sentence shorter than n produces **no** n-grams of that size. With only 8-grams, `"hi"` or `"book it"` would get no features at all.
- So the practical design mixes sizes, for example 3-, 5-, and 8-grams. Short n-grams give robust, general features, and long ones give specific, high-confidence ones.

**Parallel tables, Cerebras-style:** each n-gram size gets **its own hash and its own table in its own BRAM**. On every byte, all windows (3, 5, 8, ...) produce a bucket in the same cycle, all tables are read at once, and their weights are added together into the same accumulators. Adding another n-gram size adds another memory bank next to the compute instead of slowing anything down. BRAMs are dual-port, so two sizes can also share one table if memory is tight.

**Software side:** `train.py` would hash every n-gram size into features, either into one shared space or into separate per-size spaces matching the hardware tables. The training sweep should compare which mix of sizes gives the best validation accuracy per KB of BRAM.

### 3. More classes

The model currently covers 3 intents plus "unknown". CLINC150 has **150 intents**. Covering all of them means each bucket stores 151 weights instead of 4.

- One BRAM port is at most 72 bits wide, so the weights are **split across several BRAMs used side by side (banks)**, each serving a group of classes, with all banks read in the same cycle. This parallel memory layout is the same idea as Cerebras', at a small scale.
- 151 accumulators instead of 4, and the argmax grows to match.

### 4. A hidden layer (fastText-style)

Instead of each bucket holding one weight per class, each bucket holds a small **embedding vector** (for example, 32 int8 values). The sentence's embeddings are added together, then passed through a small output layer to get the class scores. This is how [fastText](https://fasttext.cc/) classifiers work, and it's usually more accurate per byte of memory than a linear model.

- The embedding table goes in BRAM. The output layer (32 × 151 multiply-accumulates per sentence) maps naturally onto the **DSP slices**.
- This is the biggest change: a new training script, and a second compute stage after accumulation.

### Rough memory budget

These estimates assume int8 weights and ideal packing at about 4 KB of 8-bit data per BRAM36. Actual use after synthesis will be somewhat higher, because of port widths and banking.

| Configuration | Weight memory | BRAM36 blocks | Share of PYNQ-Z2 |
|---|---|---|---|
| **Current:** 2048 buckets × 4 classes | 8 KB | 2 | ~1% |
| 16,384 buckets × 4 classes | 64 KB | 16 | ~11% |
| 65,536 buckets × 4 classes | 256 KB | 64 | ~46% |
| 3-, 5-, 8-gram tables, 16,384 buckets each × 4 classes | 192 KB | 48 | ~34% |
| 3- to 8-gram tables (6 sizes), 16,384 buckets each × 4 classes | 384 KB | 96 | ~69% |
| 2048 buckets × 151 classes (all CLINC150 intents) | 302 KB | ~76 | ~54% |
| fastText-style: 8192 × 32-dim embeddings + 32 × 151 output layer | ~261 KB | ~66 | ~47% |

## Synthesis results

Target: the PYNQ-Z2's Zynq XC7Z020 (`xc7z020clg400-1`, the slowest speed grade), with Vivado 2025.2.

### The chip on its own (out of context)

`top` is built **out of context**: its ports stay internal, because its 146 ports are more than the board's user I/O. On the board it sits behind the AXI4-Lite wrapper instead (see [below](#full-system-on-the-board)). The only constraint is the clock:

```
create_clock -period 6.667 [get_ports clk]    # 150 MHz
```

To reproduce these results, see [Synthesize in Vivado](#3-synthesize-in-vivado-optional).

#### Timing (post-implementation)

| Check | Worst slack | Meaning |
|---|---|---|
| Setup (WNS) | **+0.445 ns** | the slowest path finishes with time to spare at 150 MHz |
| Hold (WHS) | +0.118 ns | no path is too fast |
| Pulse width (WPWS) | +2.833 ns | the clock suits every component |

All timing constraints are met at **150 MHz**. The slowest path takes about 6.2 ns, so roughly 160 MHz is the current limit.

#### Resources

| Resource | Used | Available | Share |
|---|---|---|---|
| Block RAM (RAMB36) | 4 | 140 | ~3% |
| LUTs | 482 | 53,200 | 0.9% |
| Flip-flops | 760 | 106,400 | 0.7% |
| DSP | 0 | 220 | 0% |

| Module | LUTs | Flip-flops | RAMB36 |
|---|---|---|---|
| `accum` (with the weight ROM) | 194 | 132 | 2 |
| `classify` (with the 4 exp ROMs) | 257 | 600 | 2 |
| `trigram` and top-level logic | ~31 | ~28 | 0 |

Most of the flip-flops are pipeline registers in `classify`: saved copies of the scores and the differences, so that each stage keeps its own sentence's data.

The 4 block RAMs hold the weight table (2 RAMB36) and the 4 exp LUT copies. Vivado packs those into 2 RAMB36 by serving two copies from each block RAM's two ports.

#### How timing was closed

The first full build reached only about 126 MHz. Each fix followed the same rule: shorten the slowest path, and keep every value moving one stage per edge.

1. **ROMs forced into block RAM** with `(* rom_style = "block" *)`. Vivado had first built the four exp tables from about 1,000 LUTs.
2. **Block RAM output register on the exp ROMs.** One extra register after the read lets Vivado use the RAM's built-in output register, which removes about 1.5 ns of BRAM clock-to-out from the sum-and-threshold stage. Cost: 1 cycle.
3. **Cheaper clamp.** Because the differences are never negative, `diff > 2047` is the same as "any of bits 31..11 is set", a small OR tree instead of a carry-chain compare.
4. **S3 split in two.** The subtraction and the clamp each get their own cycle. Cost: 1 cycle.

### Full system on the board

`top_axi` in a block design with the Zynq processor, an AXI SmartConnect and a reset block. The logic clock is `FCLK_CLK0`: requested 150 MHz, actual **142.857 MHz** (7.0 ns).

| Check | Worst slack |
|---|---|
| Setup (WNS) | **+0.253 ns** |
| Hold (WHS) | +0.011 ns |
| Pulse width (WPWS) | +2.520 ns |

All timing constraints are met at 142.857 MHz.

| Resource | Used | Available | Share |
|---|---|---|---|
| Block RAM (RAMB36) | 4 | 140 | 2.9% |
| LUTs | 1,038 | 53,200 | 2.0% |
| Flip-flops | 1,475 | 106,400 | 1.4% |
| DSP | 0 | 220 | 0% |
| User I/O pins | 0 | 125 | 0% |

About half the LUTs and flip-flops belong to the AXI SmartConnect rather than the chip. The chip needs no external pins: everything goes over the processor's internal AXI port.

### DMA system on the board

`top_axis` with an AXI DMA, two interconnects (one for the processor to control the DMA, one for the DMA to reach DDR memory through `S_AXI_HP0`) and a reset block. Vivado timed it at 150 MHz:

| Check | Worst slack |
|---|---|
| Setup (WNS) | **+0.035 ns** |
| Hold (WHS) | +0.051 ns |
| Pulse width (WPWS) | +2.083 ns |

On the board, PYNQ 2.5 sets the logic clock from the real 50 MHz crystal and runs it at **125 MHz**, slower than the 150 MHz that timing was checked at. (This project's Zynq block was configured without the board preset. With it applied, the clock would be 142.857 MHz.)

## Performance on the board

All numbers are measured on the PYNQ-Z2 with `board/bench.py`, on the 514 sentences in `vectors.txt` (average length 40 bytes). Every version reads the same exported model files:

- **ARM Python:** plain Python on the board's ARM Cortex-A9 (650 MHz), one byte at a time
- **ARM NumPy:** all trigrams of a sentence hashed and summed at once
- **FPGA via AXI-Lite:** the chip, driven from Python: one register write per byte, then polling for the result
- **FPGA via DMA:** the chip behind `top_axis`, with a whole batch of sentences in one DMA transfer

### Summary

| Version | Time per sentence | vs ARM Python |
|---|---|---|
| ARM Python | ≈ 440 µs | 1× |
| ARM NumPy | ≈ 490 µs | 0.9× |
| FPGA via AXI-Lite | 1,285 µs | **0.3×** |
| **FPGA via DMA**, batch of 4112 sentences | **8.9 µs** | **≈ 50×** |
| FPGA core alone | ≈ 0.3 µs | ≈ 1,300× |

The chip and the model are the same in both FPGA versions. Moving from one register write per byte to one DMA transfer per batch made it about **145× faster per sentence**.

### AXI4-Lite version

All three agree on every sentence (class, argmax and all four scores):

```
ARM Python       514 sentences, 0 errors
ARM NumPy        514 sentences, 0 errors
FPGA             514 sentences, 0 errors
```

Per sentence, best of 3 runs:

| Version | Median time | Throughput | vs ARM Python |
|---|---|---|---|
| ARM Python | 433 µs | 0.09 MB/s | 1.0× |
| ARM NumPy | 491 µs | 0.08 MB/s | 0.9× |
| **FPGA via AXI-Lite** (end to end, from Python) | **1,285 µs** | 0.03 MB/s | **0.3×** |
| **FPGA core** (length + 9 cycles at 142.857 MHz) | **0.34 µs** | 117 MB/s | **≈ 1,300×** |

**The chip computes about 1,300× faster than the ARM, but end to end it is about 3× slower.**

The FPGA's 1,285 µs per sentence works out to about **32 µs per byte**, while the chip itself needs **7 ns per byte** (one clock cycle). More than 99.9% of the time goes on Python writing one byte at a time to an AXI4-Lite register. The chip spends almost all of it idle, waiting for the next byte.

NumPy is slightly slower than plain Python here because the sentences are short. Its fixed cost per call (creating arrays, indexing) outweighs what it saves on about 40 bytes.

This is the memory wall from the [Inspiration](#inspiration-cerebras-and-the-memory-wall) section again, one level out. The weights are on-chip and the compute is fast, so the bottleneck has moved to **getting the input into the chip**. The design only pays off when data reaches it as fast as it can process it.

### AXI-Stream + DMA version

All batches give **0 errors** on class and argmax (the full 514, and batches of 1, 2, 7 and 50).

Timing by batch size, best of 5 runs, logic clock 125 MHz. The 4112-sentence batch is the vector set repeated 8 times.

| Batch | Bytes | ARM Python | ARM NumPy | FPGA via DMA | DMA per sentence | vs ARM Python | Chip alone |
|---|---|---|---|---|---|---|---|
| 1 | 51 | 533 µs | 976 µs | 1,143 µs | 1,143 µs | 0.5× | 0.5 µs |
| 10 | 494 | 5,086 µs | 4,864 µs | 1,209 µs | 121 µs | 4.2× | 4.0 µs |
| 100 | 4,237 | 45.4 ms | 48.4 ms | 1.92 ms | 19.2 µs | 24× | 34 µs |
| 514 | 20,551 | 224 ms | 248 ms | 5.31 ms | 10.3 µs | 42× | 165 µs |
| 4112 | 164,408 | 1,815 ms | 2,190 ms | 36.5 ms | 8.9 µs | **50×** | 1.3 ms |

The DMA time covers the whole call as a user makes it: encoding the batch in Python, both transfers, and decoding the results.

**Each call has a fixed cost of about 1.1 ms.** A batch of 1 and a batch of 10 take almost the same time, so nearly all of it is Python, PYNQ 2.5's DMA driver, cache maintenance and polling, not the chip. That makes a single sentence about 2× slower than the ARM. The DMA breaks even at about 3 sentences per call, and pulls further ahead as batches grow.

**For large batches, Python is now the bottleneck.** Breakdown of the 4112-sentence batch:

| Step | Time | Share |
|---|---|---|
| encoding the batch in Python (16-bit words, sentence-end flags) | 30.0 ms | 82% |
| DMA transfers, including driver overhead and cache flush | 6.2 ms | 17% |
| the chip itself | 1.3 ms | (overlaps the transfers) |

The transfers move 164 KB at 26.6 MB/s including the per-call overhead, against the chip's 125 MB/s limit at this clock. Building the input array in Python takes about 5× longer than everything else combined.

### What it shows

With AXI4-Lite, getting each byte into the chip was the bottleneck. The DMA removed that, and the bottleneck moved again, to preparing the data in Python. The pattern from the [Inspiration](#inspiration-cerebras-and-the-memory-wall) section repeats at each layer: fast compute only pays off when the data reaches it as fast as it can process it.

### Hardware limits (core only)

| Metric | Value at 142.857 MHz |
|---|---|
| Throughput | 1 byte per clock → **≈ 143 MB/s** of text |
| Latency after the last byte | 10 cycles → **70 ns** |
| Latency for a whole sentence | (length + 9) cycles. A 50-byte sentence takes ≈ 413 ns. |
| Weight reads | one 32-bit word (4 weights) per byte → ≈ 571 MB/s from block RAM |

### Next: closing the gap

- **Find sentence boundaries in hardware:** Python sends plain text with a newline between sentences, as an 8-bit stream. `top_axis` turns each newline into an end-of-sentence flag, so Python's encoding step becomes a single `join`, and half as many bytes cross the DMA.
- **Lower the fixed cost per call:** non-cacheable DMA buffers (no flush or invalidate), or programming the DMA's registers directly instead of through PYNQ 2.5's driver. This helps small batches most.
- **Run at 142.857 MHz** by re-applying the board preset in the DMA project (currently 125 MHz).
