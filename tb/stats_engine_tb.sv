// =============================================================================
// stats_engine_tb.sv
// Testbench for stats_engine. Drives clk/reset, streams a Q8.24 tensor,
// checks min/max/count against hand-computed golden values, and covers two
// edge cases: an all-zero tensor and a single-element tensor.
//
// Q8.24 CONVERSION (mirrors the RTL header comment):
//   raw_int32 = round(real_value * 2^24),   2^24 = 16,777,216
//
// Main test array: [0.73, -0.15, 0.92, 0.0, -0.88, 0.44, 0.05, -0.02, 0.0, 0.0]
//   0.73  -> 12,247,368
//  -0.15  ->  -2,516,582
//   0.92  ->  15,435,039   <-- expected MAX
//   0.00  ->           0
//  -0.88  -> -14,763,950   <-- expected MIN
//   0.44  ->   7,381,975
//   0.05  ->     838,861
//  -0.02  ->    -335,544
//   0.00  ->           0
//   0.00  ->           0
//   count = 10
//
// Verify by hand: e.g. -14,763,950 / 16,777,216.0 = -0.8800000... -> -0.88 (OK)
//                       15,435,039 / 16,777,216.0 =  0.9200000... ->  0.92 (OK)
// =============================================================================

`timescale 1ns/1ps

module stats_engine_tb;

    logic                clk;
    logic                rst_n;
    logic signed [31:0]  data_in;
    logic                valid_in;
    logic                last_in;

    logic signed [31:0]  min_val;
    logic signed [31:0]  max_val;
    logic        [15:0]  count;
    logic                stats_valid;

    int pass_count = 0;
    int fail_count = 0;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    stats_engine dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .data_in     (data_in),
        .valid_in    (valid_in),
        .last_in     (last_in),
        .min_val     (min_val),
        .max_val     (max_val),
        .count       (count),
        .stats_valid (stats_valid)
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
        rst_n    = 1'b0;
        valid_in = 1'b0;
        last_in  = 1'b0;
        data_in  = 32'sd0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
    endtask

    // ------------------------------------------------------------------
    // Stream a tensor (array of raw Q8.24 ints) in, one value/cycle,
    // asserting last_in on the final element. Returns after the cycle
    // the last valid sample was accepted (does NOT wait for stats_valid;
    // caller does that separately).
    // ------------------------------------------------------------------
    task automatic stream_tensor(input logic signed [31:0] vals[], input int n);
        int i;
        for (i = 0; i < n; i++) begin
            @(negedge clk);
            valid_in = 1'b1;
            data_in  = vals[i];
            last_in  = (i == n-1);
        end
        @(negedge clk);
        valid_in = 1'b0;
        last_in  = 1'b0;
        data_in  = 32'sd0;
    endtask

    // ------------------------------------------------------------------
    // Wait for the stats_valid pulse (with a timeout guard)
    // ------------------------------------------------------------------
    // -------------------------------------------------------------------
    // Background capture queue for stats_valid pulses.
    //
    // WHY THIS EXISTS: with back-to-back tensors and zero idle cycles in
    // between, a stats_valid pulse can fire *while the driving code is
    // still mid-stream* (e.g. tensor A's pulse lands on the very cycle
    // tensor B's data is being clocked in). A simple "drive stream, then
    // wait for stats_valid" sequencing races against that: whichever pulse
    // happens to be visible at the moment the checking code looks is not
    // necessarily the one you meant to check, and stats_engine's
    // nonblocking-assignment outputs are only guaranteed settled in the NBA
    // region, one delta after the triggering posedge.
    //
    // The robust fix is to decouple capture from consumption: a background
    // process watches every clock edge, waits #1 for NBA to settle, and if
    // stats_valid is high, pushes a snapshot of min_val/max_val/count into
    // a FIFO. Test code then just pops the FIFO in order, regardless of
    // how the pulses were spaced relative to the driving sequence.
    // -------------------------------------------------------------------
    logic signed [31:0] q_min[$];
    logic signed [31:0] q_max[$];
    logic        [15:0] q_cnt[$];

    initial begin
        forever begin
            @(posedge clk);
            #1; // let NBA updates commit before sampling
            if (stats_valid === 1'b1) begin
                q_min.push_back(min_val);
                q_max.push_back(max_val);
                q_cnt.push_back(count);
            end
        end
    end

    task automatic pop_stats(output bit timed_out, output logic signed [31:0] mn,
                              output logic signed [31:0] mx, output logic [15:0] cnt);
        int guard;
        bit done;
        timed_out = 1'b0;
        done = 1'b0;
        guard = 0;
        while (!done) begin
            if (q_min.size() > 0) begin
                mn   = q_min.pop_front();
                mx   = q_max.pop_front();
                cnt  = q_cnt.pop_front();
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

    task automatic check_eq(input string name, input logic signed [31:0] got,
                             input logic signed [31:0] exp);
        if (got === exp) begin
            $display("  PASS: %s = %0d (0x%08h)", name, got, got);
            pass_count++;
        end else begin
            $display("  FAIL: %s = %0d (0x%08h), expected %0d (0x%08h)",
                      name, got, got, exp, exp);
            fail_count++;
        end
    endtask

    task automatic check_eq16(input string name, input logic [15:0] got,
                               input logic [15:0] exp);
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
        logic signed [31:0] got_min, got_max;
        logic        [15:0] got_cnt;

        // Main tensor: [0.73, -0.15, 0.92, 0.0, -0.88, 0.44, 0.05, -0.02, 0.0, 0.0]
        logic signed [31:0] main_tensor[];

        // Edge case 1: all-zero tensor (5 elements)
        logic signed [31:0] zero_tensor[];

        // Edge case 2: single-element tensor, value 0.5 -> 0.5*16777216 = 8388608
        logic signed [31:0] single_tensor[];

        main_tensor = new[10];
        zero_tensor = new[5];
        single_tensor = new[1];

        main_tensor[0] = 32'sd12247368;   // 0.73
        main_tensor[1] = -32'sd2516582;   // -0.15
        main_tensor[2] = 32'sd15435039;   // 0.92  <- expected max
        main_tensor[3] = 32'sd0;          // 0.0
        main_tensor[4] = -32'sd14763950;  // -0.88 <- expected min
        main_tensor[5] = 32'sd7381975;    // 0.44
        main_tensor[6] = 32'sd838861;     // 0.05
        main_tensor[7] = -32'sd335544;    // -0.02
        main_tensor[8] = 32'sd0;          // 0.0
        main_tensor[9] = 32'sd0;          // 0.0

        zero_tensor[0] = 32'sd0;
        zero_tensor[1] = 32'sd0;
        zero_tensor[2] = 32'sd0;
        zero_tensor[3] = 32'sd0;
        zero_tensor[4] = 32'sd0;

        single_tensor[0] = 32'sd8388608; // 0.5

        $display("=========================================================");
        $display(" stats_engine testbench starting");
        $display("=========================================================");

        do_reset();

        // ---------------- Test 1: main tensor ----------------
        $display("");
        $display("--- Test 1: main tensor (10 elements) ---");
        stream_tensor(main_tensor, 10);
        pop_stats(timed_out, got_min, got_max, got_cnt);
        if (timed_out) begin
            $display("  FAIL: stats_valid timeout");
            fail_count++;
        end else begin
            check_eq("min_val",  got_min,  -32'sd14763950); // -0.88
            check_eq("max_val",  got_max,   32'sd15435039); //  0.92
            check_eq16("count",  got_cnt,   16'd10);
        end

        // ---------------- Test 2: all-zero tensor ----------------
        $display("");
        $display("--- Test 2 (edge case): all-zero tensor (5 elements) ---");
        stream_tensor(zero_tensor, 5);
        pop_stats(timed_out, got_min, got_max, got_cnt);
        if (timed_out) begin
            $display("  FAIL: stats_valid timeout");
            fail_count++;
        end else begin
            check_eq("min_val",  got_min,  32'sd0);
            check_eq("max_val",  got_max,  32'sd0);
            check_eq16("count",  got_cnt,  16'd5);
        end

        // ---------------- Test 3: single-element tensor ----------------
        $display("");
        $display("--- Test 3 (edge case): single-element tensor (0.5) ---");
        stream_tensor(single_tensor, 1);
        pop_stats(timed_out, got_min, got_max, got_cnt);
        if (timed_out) begin
            $display("  FAIL: stats_valid timeout");
            fail_count++;
        end else begin
            check_eq("min_val",  got_min,  32'sd8388608);
            check_eq("max_val",  got_max,  32'sd8388608);
            check_eq16("count",  got_cnt,  16'd1);
        end

        // ---------------- Test 4: back-to-back tensor (no idle gap) ----
        // Regression check for the min_base/max_base hazard: start a new
        // tensor on the very same cycle the previous one's last_in fired.
        // The two resulting stats_valid pulses land on consecutive cycles
        // with no gap between them; the background capture queue (see
        // pop_stats above) is what makes checking this reliable.
        $display("");
        $display("--- Test 4 (regression): back-to-back tensors, zero idle gap ---");
        begin : run_back_to_back
            // stream main_tensor again but drop the trailing de-assert
            // gap by immediately feeding a fresh single-element tensor
            int i;
            for (i = 0; i < 10; i++) begin
                @(negedge clk);
                valid_in = 1'b1;
                data_in  = main_tensor[i];
                last_in  = (i == 9);
            end
            // Immediately (same negedge cadence, no idle bubble) start
            // a new tensor: single value -0.5 -> -8388608
            @(negedge clk);
            valid_in = 1'b1;
            data_in  = -32'sd8388608;
            last_in  = 1'b1;
            @(negedge clk);
            valid_in = 1'b0;
            last_in  = 1'b0;
            data_in  = 32'sd0;
        end

        // First queued pulse corresponds to the main_tensor repeat (tensor A)
        pop_stats(timed_out, got_min, got_max, got_cnt);
        if (timed_out) begin
            $display("  FAIL: stats_valid timeout (tensor A)");
            fail_count++;
        end else begin
            check_eq("tensorA min_val", got_min, -32'sd14763950);
            check_eq("tensorA max_val", got_max,  32'sd15435039);
            check_eq16("tensorA count", got_cnt,  16'd10);
        end

        // Second queued pulse corresponds to the immediately-following
        // single-element tensor (-0.5). If the base-value mux were broken,
        // this would incorrectly show max_val = old leftover value instead
        // of -8388608.
        pop_stats(timed_out, got_min, got_max, got_cnt);
        if (timed_out) begin
            $display("  FAIL: stats_valid timeout (tensor B)");
            fail_count++;
        end else begin
            check_eq("tensorB min_val", got_min, -32'sd8388608);
            check_eq("tensorB max_val", got_max, -32'sd8388608);
            check_eq16("tensorB count", got_cnt,  16'd1);
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
