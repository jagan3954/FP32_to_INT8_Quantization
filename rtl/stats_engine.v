// =============================================================================
// stats_engine.v
// Synchronous min/max/count tracker for a streaming Q8.24 fixed-point tensor.
// Target: Xilinx PYNQ-Z2 (xc7z020clg400-1), fully synthesizable.
// Plain Verilog-2001 (no `logic`, no `always_comb`/`always_ff`, no SV-only
// syntax) so it drops straight into any ASIC/FPGA flow without an SV-2012
// front end. Testbench (stats_engine_tb.sv) is SystemVerilog, since it
// needs queues/dynamic arrays for a robust FIFO-based checking approach.
//
// -----------------------------------------------------------------------------
// DESIGN CONSTRAINT (per spec): no combinational '/' operator anywhere.
// This module does not actually need division (min/max/count require only
// comparators and an adder), so there is nothing to change here. The
// constraint is documented for future maintainers: if this module is later
// extended to compute a running MEAN or VARIANCE, do NOT write
//   mean = sum / count;
// as combinational logic. Instead instantiate Vivado's Divider Generator IP
// (Tools -> IP Catalog -> "Divider Generator", pipelined mode, e.g. 16-24
// cycle latency for a 32-bit signed division) and feed sum/count into it as
// a multi-cycle pipelined operation, or implement an explicit shift-and-
// subtract restoring-division FSM that consumes one bit of quotient per
// clock cycle. Either approach keeps timing closure sane on the 7z020.
// -----------------------------------------------------------------------------
//
// Q8.24 FIXED-POINT FORMAT (for hand-verification against a Python golden ref)
// -----------------------------------------------------------------------------
//   32-bit signed word: [31] = sign, [30:24] = 7 integer magnitude bits,
//   [23:0] = 24 fractional bits. Total 8 integer bits (including sign) + 24
//   fractional bits = Q8.24.
//
//   real_value = raw_int32 / 2^24        (raw_int32 is a two's-complement signed int)
//   raw_int32  = round(real_value * 2^24)
//
//   2^24 = 16,777,216
//
//   Worked examples used in the testbench (round-half-away-from-zero):
//     0.73  * 16777216 =  12,247,367.68  -> round ->  12,247,368
//    -0.15  * 16777216 =  -2,516,582.4   -> round ->  -2,516,582
//     0.92  * 16777216 =  15,435,038.72  -> round ->  15,435,039
//     0.00  * 16777216 =           0.0   -> round ->           0
//    -0.88  * 16777216 = -14,763,950.08  -> round -> -14,763,950
//     0.44  * 16777216 =   7,381,975.04  -> round ->   7,381,975
//     0.05  * 16777216 =     838,860.8   -> round ->     838,861
//    -0.02  * 16777216 =    -335,544.32  -> round ->    -335,544
//
//   To go back from raw -> float by hand: raw_int32 / 16777216.0
//   e.g. 15435039 / 16777216.0 = 0.9200000...  (matches 0.92 to float rounding)
//
//   Range check: max representable magnitude is (2^31 - 1)/2^24 ~= +127.9999999
//   and -2^31/2^24 = -128.0 exactly. Fine for normalized tensor values.
// -----------------------------------------------------------------------------
//
// BEHAVIOR
// -----------------------------------------------------------------------------
//   - Every cycle with valid_in=1: compare data_in against the running
//     min/max, update on strict exceed, increment count.
//   - last_in=1 (same cycle as the final valid sample) arms a one-cycle-
//     delayed latch: on the NEXT clock, min_val/max_val/count outputs are
//     updated to the final tensor values and stats_valid pulses for exactly
//     one cycle.
//   - The running accumulators (min/max/count) are reset to init values
//     (min=+MAX, max=-MAX, count=0) either on rst_n low, or automatically
//     right after the stats_valid pulse — whichever comes first, whether or
//     not a new sample arrives on that exact same cycle (handled via the
//     min_base/max_base/cnt_base combinational mux below, so a same-cycle
//     back-to-back tensor start is never corrupted by stale values).
// =============================================================================

module stats_engine (
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [31:0]  data_in,   // Q8.24 fixed-point
    input  wire                valid_in,
    input  wire                last_in,   // asserted on final element of the tensor

    output reg  signed [31:0]  min_val,
    output reg  signed [31:0]  max_val,
    output reg          [15:0] count,
    output reg                 stats_valid // pulses 1 cycle when last_in was processed
);

    // Safe init values
    localparam signed [31:0] INIT_MIN = 32'h7FFFFFFF; // most positive
    localparam signed [31:0] INIT_MAX = 32'h80000000; // most negative

    // Running accumulators (updated every valid_in cycle)
    reg signed [31:0] min_reg, max_reg;
    reg        [15:0] count_reg;

    // Set on the cycle last_in is processed; consumed (and cleared) on the
    // very next cycle, whether that cycle has new valid data or is idle.
    reg pending_latch;

    // ---------------------------------------------------------------------
    // Combinational "base" mux: what min_reg/max_reg/count_reg should be
    // treated as *before* applying this cycle's update. Normally that's
    // just the current registered value. But if pending_latch is set, the
    // registered values are the just-finished tensor's FINAL numbers (about
    // to be latched to the outputs this same cycle) and must NOT be reused
    // as the comparison basis for a brand-new tensor's first sample — so we
    // substitute the reset/init values instead. This is the fix for the
    // zero-idle-cycle back-to-back-tensor hazard.
    // ---------------------------------------------------------------------
    reg signed [31:0] min_base, max_base;
    reg        [15:0] cnt_base;

    always @(*) begin
        min_base = pending_latch ? INIT_MIN : min_reg;
        max_base = pending_latch ? INIT_MAX : max_reg;
        cnt_base = pending_latch ? 16'd0    : count_reg;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            min_reg       <= INIT_MIN;
            max_reg       <= INIT_MAX;
            count_reg     <= 16'd0;
            min_val       <= INIT_MIN;
            max_val       <= INIT_MAX;
            count         <= 16'd0;
            stats_valid   <= 1'b0;
            pending_latch <= 1'b0;
        end else begin
            // default: single-cycle pulse
            stats_valid <= 1'b0;

            // ---- Latch stage: commit previous tensor's final numbers ----
            if (pending_latch) begin
                min_val     <= min_reg;
                max_val     <= max_reg;
                count       <= count_reg;
                stats_valid <= 1'b1;
            end

            // ---- Accumulate / reset stage ----
            if (valid_in) begin
                min_reg   <= (data_in < min_base) ? data_in : min_base;
                max_reg   <= (data_in > max_base) ? data_in : max_base;
                count_reg <= cnt_base + 16'd1;

                // Arm latch for next cycle if this was the last element;
                // otherwise this cycle consumes/clears any pending_latch
                // that was still set (handled implicitly since we overwrite
                // pending_latch below every valid_in cycle).
                pending_latch <= last_in;
            end else if (pending_latch) begin
                // No new sample this cycle: just perform the deferred reset
                // of the running accumulators for the next tensor.
                min_reg       <= INIT_MIN;
                max_reg       <= INIT_MAX;
                count_reg     <= 16'd0;
                pending_latch <= 1'b0;
            end
        end
    end

endmodule
