# Quantization

This repository contains the RTL and test environment for "Quantixation," a hardware quantization pipeline developed for an FPGA hackathon. The design takes a stream of 32-bit fixed-point data, computes quantization parameters, performs symmetric INT8/INT4 quantization, and finally compresses the output stream using Zero Run-Length Encoding (ZRLE). The project targets a PYNQ-Z2 board, based on the Xilinx Zynq-7000 SoC (specifically, the `xc7z020clg400-1` part).

## Architecture

The core logic is encapsulated in the `quant_top.v` module. The datapath is a feed-forward pipeline designed for streaming data processing. Based on the RTL and the bit-accurate golden model, the data flow is as follows:

**Data Flow:**

`AXI-Stream In -> stream_buffer -> stats_engine -> precision_controller -> quant_engine -> zrle_encoder -> perf_monitor -> AXI-Stream Out`

### RTL Modules (`rtl/`)

* `quant_top.v`: The top-level module that integrates the entire quantization and compression pipeline.
* `stream_buffer.v`: An input buffer to handle backpressure and decouple the input stream from the downstream pipeline.
* `stats_engine.v`: Consumes the input tensor stream to find the minimum and maximum values, which are required to calculate the quantization scale.
* `precision_controller.v`: Takes the min/max values from `stats_engine` and computes the `scale` factor for quantization, mirroring the logic in `quant_golden.py`.
* `quant_engine.v`: Applies the calculated `scale` factor to each data element, quantizing it to the target bit-width (INT8 or INT4).
* `zrle_encoder.v`: Compresses the quantized data stream by replacing consecutive zeros with a compact run-length token.
* `perf_monitor.v`: An optional monitoring module that can measure pipeline throughput and cycle counts.
* `zrle_decoder.v`: An auxiliary module to decode a ZRLE stream. It is **not** instantiated in the main `quant_top` datapath but is available for testing or other purposes.
* `axi_slave.v`: An auxiliary AXI-Stream slave interface. It is used in the `quant_top_tb.v` testbench to receive and write the final output stream to a file.
* `axi_master_bfm.v`: An AXI-Stream Master Bus Functional Model (BFM) used in testbenches to drive stimulus into the design.

## Repository Layout

* `bitfiles/`: Contains generated bitstream files (`.bit`, `.bin`). These are build artifacts and are gitignored.
* `python/`: Python scripts for generating test vectors and a bit-accurate golden reference model.
* `rtl/`: All synthesizable Verilog source files for the hardware design.
* `tb/`: Verilog and SystemVerilog testbenches for simulating and verifying the RTL modules.
* `vivado/`: The Vivado project directory, containing the project file (`.xpr`) and all generated synthesis/implementation runs.
* `xdc/`: Xilinx Design Constraints files for pin assignments and timing.

## Prerequisites

* **Vivado:** The project was developed with a specific Vivado version. Check `vivado.log` for the exact version string.
* **Target Board:** PYNQ-Z2 or any board with a Xilinx Zynq `xc7z020clg400-1` part.
* **Python:**
  * Python 3.x is required to run the golden model scripts.
  * The `python/b.py` script requires `numpy`. Install it via pip: `pip install numpy`.
  * The primary golden model, `quant_golden.py`, and test generator `a.py` do not have external dependencies beyond the standard library.

## Running Simulation

The primary testbench is `quant_top_tb.v`, which verifies the full pipeline against the golden model. The verification flow is a multi-step process.

### 1. Generate Test Data

The testbench reads input data from `tensor_data.hex`. You can generate this file using the provided Python scripts.

```sh
cd python/
python a.py
```

This creates `python/tensor_data.hex`.

### 2. Run RTL Simulation

The testbench expects `tensor_data.hex` to be in the simulation run directory.

Copy the input data before running the simulation:

```sh
cp python/tensor_data.hex vivado/vivado.sim/sim_1/behav/xsim/
```

Run simulation in Vivado:

1. Open the Vivado project.
2. In the Flow Navigator, click **Run Simulation -> Run Behavioral Simulation**.
3. Set `quant_top_tb.v` as the top-level simulation module if it is not already.
4. The simulation will run, and the `axi_slave` instance in the testbench will write the compressed 9-bit output to `output_tokens.hex` inside the simulation directory (`vivado/vivado.sim/sim_1/behav/xsim/`).

### 3. Compare with Golden Model

The `quant_golden.py` script can directly compare the RTL's output with its own bit-accurate model.

Copy the RTL output:

```sh
cp vivado/vivado.sim/sim_1/behav/xsim/output_tokens.hex python/
```

Run the comparison:

```sh
cd python/
python quant_golden.py tensor_data.hex --mode int8 --compress --compare output_tokens.hex
```

The script will report `MATCH` if the Python model's output is identical to the RTL's output.

## Building the Bitstream

This project uses a standard Vivado project-based flow.

1. Launch Vivado.
2. Open the project file, likely located at `vivado/quantixation.xpr`.
3. In the Flow Navigator, click **Generate Bitstream**. Vivado will automatically run synthesis and implementation.
4. The output files (`.bit`, `.bin`) will be placed in the `bitfiles/` directory upon successful completion.

## Known Issues / TODO

* **Multiple Golden Models:** The `python/` directory contains several scripts (`a.py`, `b.py`, `quant_golden.py`) for modeling the pipeline. `quant_golden.py` is the most accurate and is documented as the bit-for-bit reference. The others may have been for initial exploration and could produce different results.
* **Hardcoded Paths:** The script `a.py` contains a hardcoded path variable `vivado_sim_path`. While it points to the `python/` directory, this indicates a potential for brittle file path dependencies if not managed carefully.
* **Build Status:** This README does not track the live build status. Check the Vivado project status or `vivado.log` for the most recent synthesis and implementation results.

## License / Attribution

_TODO: add license information._
