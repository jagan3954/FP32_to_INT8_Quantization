// =============================================================================
// precision_controller_tb.sv
// Testbench for precision_controller. Drives clk/reset, pulses stats_valid
// with min/max stats in Q8.24, waits for scale_valid, and checks the
// resulting scale against a hand-computed golden reference within 1 LSB.
//
// Q8.24 CONVERSION (2^24 = 16,777,216):
//   raw_int32 = round(real_value * 2^24)
//   -0.88 -> -14,763,950   (see stats_engine_tb.sv for the full derivation)
//    0.92 ->  15,435,039
//
// GOLDEN REFERENCE (Python-equivalent, matching the RTL's integer division +
// round-to-nearest, since scale_raw = abs_max_raw / divisor exactly, no extra
// 2^24 scaling needed — see precision_controller.v header comment):
//   abs_max_raw = max(|-14763950|, |15435039|) = 15,435,039
//
//   INT8 (divisor=127):
//     15435039 / 127 = 121535 remainder 94
//     2*94 = 188 >= 127  -> round up -> scale_raw = 121536
//     scale_real = 121536 / 16777216 = 0.00724410...  (matches ~0.0072441 in spec)
//
//   INT4 (divisor=7):
//     15435039 / 7 = 2205005 remainder 4
//     2*4 = 8 >= 7  -> round up -> scale_raw = 2205006
//     scale_real = 2205006 / 16777216 = 0.13142859...  (matches 0.92/7 = 0.1314286)
//
//   Passthrough (divisor=1, bonus sanity check):
//     scale_raw = 15435039 (identity, no division), bit_width = 0 (sentinel)
// =============================================================================

`timescale 1ns/1ps

module precision_controller_tb;

    logic                clk;
    logic                rst_n;
    logic signed [31:0]  min_val;
    logic signed [31:0]  max_val;
    logic                stats_valid;
    logic        [1:0]   mode_sel;

    logic signed [31:0]  scale;
    logic        [7:0]   zero_point;
    logic        [3:0]   bit_width;
    logic                scale_valid;

    int pass_count = 0;
    int fail_count = 0;

    // Allowed rounding tolerance: within 1 LSB of Q8.24, per spec.
    localparam int TOLERANCE = 1;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    precision_controller dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .min_val     (min_val),
        .max_val     (max_val),
        .stats_valid (stats_valid),
        .mode_sel    (mode_sel),
        .scale       (scale),
        .zero_point  (zero_point),
        .bit_width   (bit_width),
        .scale_valid (scale_valid)
    );

    // ------------------------------------------------------------------
    // Clock: 100 MHz
    // ------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------
    // Reset task
    // ------------------------------------------------------------------
    task automatic do_reset();
        rst_n       = 1'b0;
        stats_valid = 1'b0;
        min_val     = 32'sd0;
        max_val     = 32'sd0;
        mode_sel    = 2'b00;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // ------------------------------------------------------------------
    // Background capture queue for scale_valid pulses. Same rationale as
    // stats_engine_tb.sv: sampling DUT outputs right at a clock edge races
    // its nonblocking-assignment updates (which only commit in the NBA
    // region), so a background process settles #1 past the edge before
    // snapshotting, and consumers just pop the FIFO in order.
    // ------------------------------------------------------------------
    logic signed [31:0] q_scale[$];
    logic        [3:0]  q_bw[$];

    initial begin
        forever begin
            @(posedge clk);
            #1;
            if (scale_valid === 1'b1) begin
                q_scale.push_back(scale);
                q_bw.push_back(bit_width);
            end
        end
    end

    task automatic pop_scale(output bit timed_out, output logic signed [31:0] got_scale,
                              output logic [3:0] got_bw);
        int guard;
        bit done;
        timed_out = 1'b0;
        done = 1'b0;
        guard = 0;
        while (!done) begin
            if (q_scale.size() > 0) begin
                got_scale = q_scale.pop_front();
                got_bw    = q_bw.pop_front();
                done = 1'b1;
            end else begin
                @(posedge clk);
                guard++;
                if (guard > 2000) begin
                    timed_out = 1'b1;
                    done = 1'b1;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Drive one stats_valid request for exactly one cycle.
    // ------------------------------------------------------------------
    task automatic issue_request(input logic signed [31:0] mn, input logic signed [31:0] mx,
                                   input logic [1:0] mode);
        @(negedge clk);
        min_val     = mn;
        max_val     = mx;
        mode_sel    = mode;
        stats_valid = 1'b1;
        @(negedge clk);
        stats_valid = 1'b0;
    endtask

    task automatic check_scale(input string name, input logic signed [31:0] got,
                                 input logic signed [31:0] exp);
        int diff;
        diff = got - exp;
        if (diff < 0) diff = -diff;
        if (diff <= TOLERANCE) begin
            $display("  PASS: %s = %0d (0x%08h), expected %0d (0x%08h), diff=%0d",
                       name, got, got, exp, exp, diff);
            pass_count++;
        end else begin
            $display("  FAIL: %s = %0d (0x%08h), expected %0d (0x%08h), diff=%0d (tolerance=%0d)",
                       name, got, got, exp, exp, diff, TOLERANCE);
            fail_count++;
        end
    endtask

    task automatic check_bw(input string name, input logic [3:0] got, input logic [3:0] exp);
        if (got === exp) begin
            $display("  PASS: %s = %0d", name, got);
            pass_count++;
        end else begin
            $display("  FAIL: %s = %0d, expected %0d", name, got, exp);
            fail_count++;
        end
    endtask

    // ------------------------------------------------------------------
    // Main test sequence
    // ------------------------------------------------------------------
    initial begin
        bit timed_out;
        logic signed [31:0] got_scale;
        logic        [3:0]  got_bw;

        // min_val = -0.88 -> -14,763,950 ; max_val = 0.92 -> 15,435,039
        localparam logic signed [31:0] MIN_Q824 = -32'sd14763950;
        localparam logic signed [31:0] MAX_Q824 =  32'sd15435039;

        $display("=========================================================");
        $display(" precision_controller testbench starting");
        $display("=========================================================");

        do_reset();

        // ---------------- Test 1: INT8 (mode_sel = 00, divisor 127) ----
        $display("");
        $display("--- Test 1: INT8 quantization (mode_sel=00) ---");
        issue_request(MIN_Q824, MAX_Q824, 2'b00);
        pop_scale(timed_out, got_scale, got_bw);
        if (timed_out) begin
            $display("  FAIL: scale_valid timeout");
            fail_count++;
        end else begin
            check_scale("scale (INT8)", got_scale, 32'sd121536);
            check_bw("bit_width (INT8)", got_bw, 4'd8);
        end

        // ---------------- Test 2: INT4 (mode_sel = 01, divisor 7) ------
        $display("");
        $display("--- Test 2: INT4 quantization (mode_sel=01) ---");
        issue_request(MIN_Q824, MAX_Q824, 2'b01);
        pop_scale(timed_out, got_scale, got_bw);
        if (timed_out) begin
            $display("  FAIL: scale_valid timeout");
            fail_count++;
        end else begin
            check_scale("scale (INT4)", got_scale, 32'sd2205006);
            check_bw("bit_width (INT4)", got_bw, 4'd4);
        end

        // ---------------- Test 3 (bonus): passthrough (mode_sel = 10) --
        $display("");
        $display("--- Test 3 (bonus): fixed passthrough (mode_sel=10) ---");
        issue_request(MIN_Q824, MAX_Q824, 2'b10);
        pop_scale(timed_out, got_scale, got_bw);
        if (timed_out) begin
            $display("  FAIL: scale_valid timeout");
            fail_count++;
        end else begin
            check_scale("scale (passthrough)", got_scale, 32'sd15435039);
            check_bw("bit_width (passthrough)", got_bw, 4'd0);
        end

        // ---------------- Summary ----------------
        $display("");
        $display("=========================================================");
        if (fail_count == 0) begin
            $display(" OVERALL RESULT: PASS  (%0d checks passed)", pass_count);
        end else begin
            $display(" OVERALL RESULT: FAIL  (%0d passed, %0d failed)",
                       pass_count, fail_count);
        end
        $display("=========================================================");

        $finish;
    end

endmodule
