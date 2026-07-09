// =============================================================================
// perf_monitor_tb.v
// Testbench for perf_monitor
//   Test 1: input_count=10,  token_count=7   (ZRLE example, short array,
//           overhead > savings -> ratio < 2x)
//   Test 2: input_count=300, token_count=20  (longer array, realistic >2x)
// Run with, e.g.:
//   iverilog -o sim perf_monitor.v perf_monitor_tb.v && vvp sim
// =============================================================================

`timescale 1ns / 1ps

module perf_monitor_tb;

    reg         clk;
    reg         rst_n;
    reg  [15:0] input_count;
    reg  [15:0] token_count;
    reg         pipeline_start;
    reg         pipeline_done;

    wire [31:0] latency_cycles;
    wire [15:0] compression_ratio_x100;
    wire        monitor_valid;

    integer fail_count;

    // -------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------
    perf_monitor dut (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .input_count             (input_count),
        .token_count             (token_count),
        .pipeline_start          (pipeline_start),
        .pipeline_done           (pipeline_done),
        .latency_cycles          (latency_cycles),
        .compression_ratio_x100  (compression_ratio_x100),
        .monitor_valid           (monitor_valid)
    );

    // -------------------------------------------------------------------
    // Clock: 100 MHz (10 ns period)
    // -------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------
    // Test task
    //   tc_wait_cycles = number of clock edges between the start pulse
    //   edge and the done pulse edge -> expected latency_cycles value
    // -------------------------------------------------------------------
    task run_test(
        input [15:0] tc_input_count,
        input [15:0] tc_token_count,
        input integer tc_wait_cycles,
        input integer test_num
    );
        integer golden_ratio;
        integer timeout;
        begin
            input_count = tc_input_count;
            token_count = tc_token_count;

            // Pulse pipeline_start for one cycle
            @(posedge clk);
            pipeline_start = 1'b1;
            @(posedge clk);
            pipeline_start = 1'b0;

            // Wait the remaining cycles, then pulse pipeline_done
            repeat (tc_wait_cycles - 1) @(posedge clk);
            pipeline_done = 1'b1;
            @(posedge clk);
            pipeline_done = 1'b0;

            // Wait for monitor_valid (guard against hang)
            timeout = 0;
            while ((monitor_valid !== 1'b1) && (timeout < 200)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            golden_ratio = (tc_input_count * 8 * 100) / (tc_token_count * 9);

            $display("---------------------------------------------------");
            $display("Test %0d: input_count=%0d token_count=%0d expected_latency=%0d",
                       test_num, tc_input_count, tc_token_count, tc_wait_cycles);

            if (timeout >= 200) begin
                $display("Test %0d: FAIL - monitor_valid never asserted (timeout)", test_num);
                fail_count = fail_count + 1;
            end else begin
                if (latency_cycles !== tc_wait_cycles) begin
                    $display("Test %0d: FAIL - latency_cycles = %0d, expected %0d",
                               test_num, latency_cycles, tc_wait_cycles);
                    fail_count = fail_count + 1;
                end else begin
                    $display("Test %0d: PASS - latency_cycles = %0d", test_num, latency_cycles);
                end

                if (compression_ratio_x100 !== golden_ratio) begin
                    $display("Test %0d: FAIL - compression_ratio_x100 = %0d, expected %0d",
                               test_num, compression_ratio_x100, golden_ratio);
                    fail_count = fail_count + 1;
                end else begin
                    $display("Test %0d: PASS - compression_ratio_x100 = %0d (%0d.%02dx)",
                               test_num, compression_ratio_x100,
                               compression_ratio_x100 / 100, compression_ratio_x100 % 100);
                end
            end

            // let FSM settle back to idle before the next test
            repeat (4) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------
    initial begin
        fail_count     = 0;
        rst_n          = 1'b0;
        pipeline_start = 1'b0;
        pipeline_done  = 1'b0;
        input_count    = 16'd0;
        token_count    = 16'd0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Test 1: ZRLE short-array example, 10 elements -> 7 tokens
        // golden = (10*8*100)/(7*9) = 8000/63 = 126 (~1.27x, overhead-dominated)
        run_test(16'd10, 16'd7, 50, 1);

        // Test 2: longer array, realistic >2x compression
        // golden = (300*8*100)/(20*9) = 240000/180 = 1333 (~13.33x)
        run_test(16'd300, 16'd20, 80, 2);

        $display("---------------------------------------------------");
        if (fail_count == 0)
            $display("OVERALL: PASS - all checks passed");
        else
            $display("OVERALL: FAIL - %0d check(s) failed", fail_count);
        $display("---------------------------------------------------");

        $finish;
    end

endmodule
