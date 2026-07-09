// =============================================================================
// precision_controller.v
// Computes a per-tensor quantization scale factor from running min/max stats.
// Target: Xilinx PYNQ-Z2 (xc7z020clg400-1), fully synthesizable.
// Plain Verilog-2001 (no `logic`, no `always_comb`/`always_ff`, no SV-only
// syntax). Testbench (precision_controller_tb.sv) is SystemVerilog.
//
// -----------------------------------------------------------------------------
// WHY A SHIFT-AND-SUBTRACT RESTORING DIVIDER (not Vivado's Divider Generator IP)
// -----------------------------------------------------------------------------
// Unlike stats_engine (which needed no division at all), this module's core
// job genuinely is division: scale = abs_max / divisor. Two realistic
// implementation choices, per the spec:
//
//   (a) Vivado's Divider Generator IP, pipelined mode
//   (b) A shift-and-subtract restoring-division FSM, multi-cycle
//
// This module uses (b). Reasoning, specific to the xc7z020:
//   - The 7z020 has only 220 DSP48E1 slices total. In a full quantization
//     pipeline, those slices are precious — they're needed for the actual
//     convolution/GEMM MACs in the CNN datapath, not for an occasional
//     per-tensor scale computation that only runs once per stats_valid pulse
//     (i.e. once per tensor, not once per sample). The Divider Generator IP,
//     even in "high performance" pipelined mode, typically maps its internal
//     subtractors onto DSP48E1 slices for area/speed reasons (or costs a
//     nontrivial LUT budget in fabric-only mode) — spending that budget on a
//     unit that fires this infrequently is a poor trade versus reserving DSPs
//     for the datapath.
//   - This division's DIVISOR is always one of exactly three small compile-
//     time-known values (127, 7, or 1) selected by mode_sel — never an
//     arbitrary runtime operand. A generic pipelined IP divider is built for
//     the general case (32-bit / 32-bit); we don't need that generality here.
//   - Latency is not a hard constraint: scale is computed once per tensor
//     (i.e. once every thousands of clock cycles, whenever stats_valid
//     pulses), so a 32-cycle multi-cycle FSM costs nothing in throughput.
//   - A shift-and-subtract restoring divider needs only a 32-bit adder/
//     subtractor and two 32-bit shift registers — pure LUT/FF fabric, zero
//     DSP slices, zero multipliers, small and easy to time-close at typical
//     FPGA clock rates on this device.
//
// If this were instead an inner-loop operation (e.g. dividing every single
// activation sample, not just once per tensor), the calculus would flip and
// a pipelined pipelined Divider Generator IP instance would be the right call
// to keep throughput up. That's not the case here.
// -----------------------------------------------------------------------------
//
// DIVISION ALGORITHM (unsigned restoring division, compare-then-subtract form)
// -----------------------------------------------------------------------------
//   32-bit unsigned dividend (abs_max magnitude), divisor <= 127 (needs only
//   7 bits), 32-bit quotient, computed 1 bit per clock cycle over 32 cycles.
//
//   rem <= 0, quot <= dividend
//   repeat 32 times:
//     {rem, quot} <<= 1                     // shift dividend's next MSB into rem
//     if (rem >= divisor):
//         rem  <= rem - divisor
//         quot[0] <= 1
//     else:
//         quot[0] <= 0                      // ("restore" is implicit: since we
//                                            //  only subtract when it doesn't
//                                            //  go negative, there is nothing
//                                            //  to add back — this is the
//                                            //  standard compare-subtract
//                                            //  formulation of restoring
//                                            //  division, functionally
//                                            //  identical to the classic
//                                            //  "subtract, check sign, add
//                                            //  back on borrow" formulation
//                                            //  but without the extra adder).
//
//   After 32 iterations, quot holds floor(dividend/divisor) and rem holds the
//   remainder. A final round-to-nearest step (compare 2*rem against divisor)
//   is applied before the result is presented, since the spec's tolerance
//   check (within 1 LSB of Q8.24) is comfortably met by round-to-nearest but
//   is much tighter if we merely truncate.
// -----------------------------------------------------------------------------
//
// FIXED-POINT SCALING NOTE
// -----------------------------------------------------------------------------
//   abs_max is Q8.24: abs_max_real = abs_max_raw / 2^24.
//   divisor is a plain integer (127, 7, or 1).
//   scale_real = abs_max_real / divisor = (abs_max_raw / divisor) / 2^24
//   => scale_raw (Q8.24) = abs_max_raw / divisor  (plain integer division on
//      the raw 32-bit word — the 2^24 factor cancels out, no extra shifting
//      needed to keep the result in Q8.24).
// -----------------------------------------------------------------------------
//
// BEHAVIOR
// -----------------------------------------------------------------------------
//   - On stats_valid (while IDLE): latch abs_max = max(|min_val|, |max_val|),
//     the mode-selected divisor, and the mode-selected bit_width; begin the
//     32-cycle division FSM.
//   - New stats_valid pulses arriving while busy (COMPUTE) are ignored —
//     the caller is expected to wait for scale_valid before issuing the next
//     request (matches the once-per-tensor usage pattern; no request queue).
//   - scale_valid pulses for exactly one cycle when the rounded result is
//     ready, alongside the latched bit_width for that same result.
//   - zero_point is fixed at 0 (symmetric quantization only).
//   - mode_sel == 2'b11 is reserved/undefined by the spec; this module
//     treats it as passthrough (divisor=1, bit_width=0) as a safe fallback.
// =============================================================================

module precision_controller (
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [31:0]  min_val,    // Q8.24, from stats_engine
    input  wire signed [31:0]  max_val,    // Q8.24, from stats_engine
    input  wire                stats_valid,
    input  wire         [1:0]  mode_sel,   // 00=INT8, 01=INT4, 10=passthrough

    output reg  signed [31:0]  scale,      // Q8.24 fixed-point
    output wire          [7:0] zero_point, // fixed at 0 (symmetric quant)
    output reg           [3:0] bit_width,  // 8, 4, or 0 = passthrough sentinel
    output reg                 scale_valid
);

    // Symmetric quantization only: zero_point is always 0.
    assign zero_point = 8'd0;

    // -------------------------------------------------------------------
    // Combinational helpers: absolute value of min/max, and the mode ->
    // {divisor, bit_width} lookup. These are only ever *sampled* (latched
    // into registers) at the moment stats_valid is accepted in S_IDLE, so
    // they can safely be plain continuous assigns off the live inputs.
    // -------------------------------------------------------------------
    wire signed [31:0] abs_min_w     = min_val[31] ? (~min_val + 32'sd1) : min_val;
    wire signed [31:0] abs_maxval_w  = max_val[31] ? (~max_val + 32'sd1) : max_val;
    wire signed [31:0] abs_max_w     = (abs_min_w > abs_maxval_w) ? abs_min_w : abs_maxval_w;

    wire [7:0] divisor_w   = (mode_sel == 2'b00) ? 8'd127 :
                              (mode_sel == 2'b01) ? 8'd7   :
                                                     8'd1;   // 10 or 11 -> passthrough
    wire [3:0] bitwidth_w  = (mode_sel == 2'b00) ? 4'd8 :
                              (mode_sel == 2'b01) ? 4'd4 :
                                                     4'd0;   // passthrough sentinel

    // -------------------------------------------------------------------
    // FSM state
    // -------------------------------------------------------------------
    localparam [1:0] S_IDLE    = 2'd0,
                      S_COMPUTE = 2'd1,
                      S_DONE    = 2'd2;

    reg [1:0] state;
    reg [5:0] iter_cnt;   // counts 0..31 across the 32 division iterations

    reg [31:0] rem_reg;   // restoring-division remainder accumulator
    reg [31:0] quot_reg;  // dividend in, quotient out (shift register)
    reg [7:0]  divisor_reg;
    reg [3:0]  bw_reg;

    // -------------------------------------------------------------------
    // One shift-and-subtract iteration's combinational next-value logic
    // -------------------------------------------------------------------
    wire [31:0] shifted_rem  = {rem_reg[30:0], quot_reg[31]};
    wire [31:0] shifted_quot = {quot_reg[30:0], 1'b0};
    wire [31:0] divisor_ext  = {24'd0, divisor_reg};
    wire        can_subtract = (shifted_rem >= divisor_ext);

    wire [31:0] next_rem  = can_subtract ? (shifted_rem - divisor_ext) : shifted_rem;
    wire [31:0] next_quot = can_subtract ? {shifted_quot[31:1], 1'b1} : {shifted_quot[31:1], 1'b0};

    // -------------------------------------------------------------------
    // Round-to-nearest on the final iteration's remainder/quotient
    // -------------------------------------------------------------------
    wire [32:0] rem_x2       = {next_rem, 1'b0};
    wire        round_up     = (rem_x2 >= {25'd0, divisor_reg});
    wire [31:0] rounded_quot = round_up ? (next_quot + 32'd1) : next_quot;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            iter_cnt    <= 6'd0;
            rem_reg     <= 32'd0;
            quot_reg    <= 32'd0;
            divisor_reg <= 8'd0;
            bw_reg      <= 4'd0;
            scale       <= 32'sd0;
            bit_width   <= 4'd0;
            scale_valid <= 1'b0;
        end else begin
            case (state)
                // -------------------------------------------------------
                S_IDLE: begin
                    scale_valid <= 1'b0;
                    if (stats_valid) begin
                        rem_reg     <= 32'd0;
                        quot_reg    <= abs_max_w;   // unsigned magnitude, dividend
                        divisor_reg <= divisor_w;
                        bw_reg      <= bitwidth_w;
                        iter_cnt    <= 6'd0;
                        state       <= S_COMPUTE;
                    end
                end

                // -------------------------------------------------------
                S_COMPUTE: begin
                    if (iter_cnt == 6'd31) begin
                        // Final iteration: apply this step's shift-subtract
                        // AND round-to-nearest in the same cycle, then move
                        // straight to S_DONE with the finished result ready
                        // to be presented next cycle.
                        rem_reg  <= next_rem;
                        quot_reg <= rounded_quot;
                        state    <= S_DONE;
                    end else begin
                        rem_reg  <= next_rem;
                        quot_reg <= next_quot;
                        iter_cnt <= iter_cnt + 6'd1;
                    end
                end

                // -------------------------------------------------------
                S_DONE: begin
                    scale       <= quot_reg;  // rounded quotient from S_COMPUTE
                    bit_width   <= bw_reg;
                    scale_valid <= 1'b1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
