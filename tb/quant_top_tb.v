`timescale 1ns/1ps

// =============================================================================
// FIX (this revision): the previous pass/fail check re-read the compressed
// token stream back from output_tokens.hex (written by axis_slave_bfm) and
// compared THAT against golden_tokens.hex. In practice that file round-trip
// was coming back all-X (see waveform: rtl_tokens[8:0] = XXX,XXX,... for
// every entry, while direct_capture and golden_tokens both showed real,
// matching data) - almost certainly a simulator working-directory / relative
// path mismatch, or a write-not-yet-flushed race between axis_slave_bfm
// finishing its file write and this testbench's $readmemh call. That's a
// bug in the auxiliary file-based verification path, not in the RTL: the
// pipeline's actual output, captured live at the m_tdata/m_tvalid/m_tlast
// boundary via direct_capture, already matched golden_tokens exactly.
//
// Fix: direct_capture is now the SOLE authority for pass/fail. It watches
// the AXI4-Stream master interface directly, every cycle it's valid, so it
// cannot be broken by any downstream BFM's file path, working directory, or
// write-flush timing - if the DUT's output is wrong, this array is wrong;
// if the DUT is right, so is this. axis_slave_bfm is still instantiated
// (so output_tokens.hex still gets written, useful for external diffing/
// logging if you want it), but nothing about pass/fail depends on reading
// it back anymore.
//
// Also removed: a hierarchical dot-path peek (u_dut.u_zrle_enc.token_count)
// that was dead code - its result was unconditionally overwritten before
// ever being used or displayed. Harmless in sim, but not needed either.
// =============================================================================

module tb_quant_pipeline_top;

    reg clk;
    reg rst_n;

    // slave-side interface wires
    wire [31:0] s_tdata;
    wire        s_tvalid;
    wire        s_tlast;
    wire        s_tready;
    wire        bfm_in_done;

    // master-side interface wires
    wire [8:0]  m_tdata;
    wire        m_tvalid;
    wire        m_tlast;
    wire        bfm_out_done;

    reg  [1:0]  mode_sel;

    // Performance monitor metrics
    wire [31:0] latency_cycles;
    wire [15:0] compression_ratio_x100;
    wire        monitor_valid;

    // --- Direct RTL-Wire Capture: AUTHORITATIVE source of truth for pass/fail ---
    // Sized to MAX_LEN (1024) worst case, not just the small test tensors.
    reg [9:0] direct_capture [0:1023];
    integer   direct_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            direct_idx <= 0;
        end else if (m_tvalid) begin
            direct_capture[direct_idx] <= {m_tlast, m_tdata};
            direct_idx <= direct_idx + 1;
        end
    end

    reg [8:0]   golden_tokens [0:2047];
    integer     i, errors;

    // 100 MHz Clock Generator
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Upstream AXI4-Stream Master Driver BFM
    axis_master_bfm #(
        .DATA_WIDTH (32),
        .FILE_PATH  ("tensor_data.hex")
    ) u_master_bfm (
        .clk    (clk),
        .rst_n  (rst_n),
        .tdata  (s_tdata),
        .tvalid (s_tvalid),
        .tlast  (s_tlast),
        .tready (s_tready),
        .done   (bfm_in_done)
    );

    // Device Under Test (DUT)
    quant_pipeline_top #(
        .MAX_LEN (1024)
    ) u_dut (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .s_tdata                (s_tdata),
        .s_tvalid               (s_tvalid),
        .s_tlast                (s_tlast),
        .s_tready               (s_tready),
        .mode_sel               (mode_sel),
        .m_tdata                (m_tdata),
        .m_tvalid               (m_tvalid),
        .m_tlast                (m_tlast),
        .m_tready               (1'b1), // Tied High
        .latency_cycles         (latency_cycles),
        .compression_ratio_x100 (compression_ratio_x100),
        .monitor_valid          (monitor_valid)
    );

    // Downstream AXI4-Stream Slave Capture BFM. Kept for logging/external
    // diffing (still writes output_tokens.hex) but no longer gates pass/fail
    // - see header comment above for why.
    axis_slave_bfm #(
        .DATA_WIDTH (9),
        .FILE_PATH  ("output_tokens.hex")
    ) u_slave_bfm (
        .clk    (clk),
        .rst_n  (rst_n),
        .tdata  (m_tdata),
        .tvalid (m_tvalid),
        .tlast  (m_tlast),
        .tready (),
        .done   (bfm_out_done)
    );

    initial begin
        $readmemh("golden_tokens.hex", golden_tokens);

        rst_n    = 1'b0;
        mode_sel = 2'b00;
        errors   = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // Process until hardware pipeline asserts termination metrics
        wait (monitor_valid == 1'b1);
        // Settle past this same edge's NBA commits before sampling
        // direct_idx/direct_capture for the diagnostic trace below (same
        // race class documented in stats_engine_tb.sv / precision_controller_tb.sv:
        // reading a DUT register in the same delta as the triggering edge
        // can catch it one cycle early). This only affects the diagnostic
        // print's count; the actual pass/fail comparison further below
        // already runs after additional settle cycles and is unaffected.
        @(posedge clk);
        #1;

        $display("\n=========================================================");
        $display("   DIAGNOSTIC TRACE: DIRECT HOOK WIRE CAPTURE STATUS");
        $display("=========================================================");
        $display("Captured direct_idx count value: %0d", direct_idx);
        $display("Printing raw {tlast, tdata} array from wire monitors:");
        for (i = 0; i < direct_idx; i = i + 1) begin
            $display("  direct_capture[%0d] = tlast=%b token=0x%h",
                     i, direct_capture[i][9], direct_capture[i][8:0]);
        end
        $display("=========================================================\n");

        // Let the downstream slave BFM finish flushing its log file too
        // (informational only - see header comment; not required for the
        // pass/fail verdict below).
        wait (bfm_out_done == 1'b1);
        repeat (10) @(posedge clk);

        // ---- AUTHORITATIVE comparison: live direct_capture vs golden ----
        for (i = 0; i < direct_idx; i = i + 1) begin
            if (direct_capture[i][8:0] !== golden_tokens[i]) begin
                $display("FAIL token %0d: RTL=%h EXPECTED=%h",
                           i, direct_capture[i][8:0], golden_tokens[i]);
                errors = errors + 1;
            end
        end

        // tlast sanity: must be asserted on exactly the final captured
        // token, and nowhere earlier.
        if (direct_idx > 0 && direct_capture[direct_idx-1][9] !== 1'b1) begin
            $display("FAIL: tlast not asserted on final token (index %0d)", direct_idx-1);
            errors = errors + 1;
        end
        for (i = 0; i < direct_idx-1; i = i + 1) begin
            if (direct_capture[i][9] !== 1'b0) begin
                $display("FAIL: unexpected early tlast at token %0d", i);
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("=== TOP-LEVEL TEST PASSED (%0d tokens, live AXI capture vs golden) ===", direct_idx);
        end else begin
            $display("=== TOP-LEVEL TEST FAILED (%0d mismatches) ===", errors);
        end

        $finish;
    end

endmodule