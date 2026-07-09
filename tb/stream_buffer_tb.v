// =============================================================================
// stream_buffer_tb.v
// Testbench for stream_buffer
//   1. Write 20 known sequential values, confirm full never asserts early
//   2. Read all 20 back, confirm FIFO order (not LIFO)
//   3. Fill completely to DEPTH, confirm full asserts at exactly the right time
//   4. Drain completely, confirm empty asserts at exactly the right time
// Run with:
//   iverilog -o sim stream_buffer.v stream_buffer_tb.v && vvp sim
// =============================================================================

`timescale 1ns / 1ps

module stream_buffer_tb;

    localparam DEPTH = 1024;
    localparam WIDTH = 32;

    reg                  clk;
    reg                  rst_n;
    reg  [WIDTH-1:0]     wr_data;
    reg                  wr_en;
    wire                 full;
    wire [WIDTH-1:0]     rd_data;
    reg                  rd_en;
    wire                 empty;

    integer fail_count;
    integer pass_count;
    integer i;

    // -------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------
    stream_buffer #(
        .DEPTH (DEPTH),
        .WIDTH (WIDTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_data (wr_data),
        .wr_en   (wr_en),
        .full    (full),
        .rd_data (rd_data),
        .rd_en   (rd_en),
        .empty   (empty)
    );

    // -------------------------------------------------------------------
    // Clock: 100 MHz
    // -------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------
    // Tasks
    // -------------------------------------------------------------------
    task write_word(input [WIDTH-1:0] data);
        begin
            @(posedge clk);
            wr_data = data;
            wr_en   = 1'b1;
            @(posedge clk);   // wr_en sampled here; count/wr_ptr update (NBA)
            wr_en   = 1'b0;
            @(posedge clk);   // settle cycle: let the NBA update fully resolve
                              // before any caller reads full/count right after
        end
    endtask

    // Pops one word and checks it against the expected value.
    // Accounts for the 1-cycle registered-read latency of the DUT.
    task read_word(input [WIDTH-1:0] expected, input integer idx);
        begin
            @(posedge clk);
            rd_en = 1'b1;
            @(posedge clk);   // rd_data_reg updates (NBA) on this edge
            rd_en = 1'b0;
            @(posedge clk);   // settle cycle: let the NBA update fully resolve
                              // before sampling rd_data (avoids active-region
                              // vs NBA-region race on the previous edge)
            if (rd_data !== expected) begin
                $display("FAIL: read idx=%0d got %h expected %h", idx, rd_data, expected);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------
    initial begin
        fail_count = 0;
        pass_count = 0;
        rst_n      = 1'b0;
        wr_en      = 1'b0;
        rd_en      = 1'b0;
        wr_data    = {WIDTH{1'b0}};

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("=====================================================");
        $display("Test 1-3: write/read 20 sequential values, check order");
        $display("=====================================================");

        // ---- Write 20 known sequential values ----
        for (i = 0; i < 20; i = i + 1) begin
            write_word(32'hA000_0000 + i);
            if (full) begin
                $display("FAIL: full asserted prematurely after %0d/%0d writes", i+1, DEPTH);
                fail_count = fail_count + 1;
            end
        end
        if (!full) begin
            $display("PASS: full not asserted after 20/1024 writes");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: full incorrectly asserted after 20/1024 writes");
            fail_count = fail_count + 1;
        end

        // ---- Read all 20 back, verify FIFO order ----
        for (i = 0; i < 20; i = i + 1) begin
            read_word(32'hA000_0000 + i, i);
        end
        if (empty) begin
            $display("PASS: empty asserted after draining all 20 words");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: empty not asserted after draining all 20 words");
            fail_count = fail_count + 1;
        end

        $display("=====================================================");
        $display("Test 4: fill completely to DEPTH=%0d, check full timing", DEPTH);
        $display("=====================================================");

        for (i = 0; i < DEPTH; i = i + 1) begin
            write_word(32'hB000_0000 + i);
            if ((i < DEPTH-1) && full) begin
                $display("FAIL: full asserted prematurely at fill count=%0d/%0d", i+1, DEPTH);
                fail_count = fail_count + 1;
            end
        end
        if (full) begin
            $display("PASS: full asserted exactly at DEPTH capacity");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: full not asserted at DEPTH capacity");
            fail_count = fail_count + 1;
        end

        // Bonus: confirm a write while full is correctly ignored (no overflow/corruption)
        write_word(32'hDEAD_BEEF);
        if (full) begin
            $display("PASS: full still asserted after blocked write (no overflow)");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: full deasserted unexpectedly after blocked write");
            fail_count = fail_count + 1;
        end

        $display("=====================================================");
        $display("Test 5: drain completely, check empty timing");
        $display("=====================================================");

        for (i = 0; i < DEPTH; i = i + 1) begin
            read_word(32'hB000_0000 + i, i);
            if ((i < DEPTH-1) && empty) begin
                $display("FAIL: empty asserted prematurely at drain count=%0d/%0d", i+1, DEPTH);
                fail_count = fail_count + 1;
            end
        end
        if (empty) begin
            $display("PASS: empty asserted exactly after full drain");
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: empty not asserted after full drain");
            fail_count = fail_count + 1;
        end

        $display("=====================================================");
        if (fail_count == 0)
            $display("OVERALL: PASS - all %0d checks passed", pass_count);
        else
            $display("OVERALL: FAIL - %0d failed, %0d passed", fail_count, pass_count);
        $display("=====================================================");

        $finish;
    end

endmodule
