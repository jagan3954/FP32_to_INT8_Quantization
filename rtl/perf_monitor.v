// =============================================================================
// perf_monitor.v
// Synchronous performance monitor for the quantization pipeline
// Target: Xilinx PYNQ-Z2 (xc7z020)
//
// Function 1: counts clock cycles between pipeline_start and pipeline_done
//             -> latency_cycles
// Function 2: computes compression_ratio_x100 = (input_count*8*100) /
//             (token_count*9) using a simple 32-cycle restoring divider
//             (bits-before vs bits-after, fixed-point *100 percentage-style)
// Both results are latched together and monitor_valid pulses for one cycle
// once both are ready.
// =============================================================================

module perf_monitor (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] input_count,     // element count from stats_engine
    input  wire [15:0] token_count,     // token count from zrle_encoder

    input  wire        pipeline_start,  // pulse: tensor processing begins
    input  wire        pipeline_done,   // pulse: last output token emitted

    output reg  [31:0] latency_cycles,
    output reg  [15:0] compression_ratio_x100,
    output reg         monitor_valid
);

    // -------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------
    localparam S_IDLE   = 3'd0,
               S_COUNT   = 3'd1,
               S_LATCH   = 3'd2,
               S_DIVIDE  = 3'd3,
               S_VALID   = 3'd4;

    reg [2:0]  state;
    reg [31:0] cycle_cnt;

    // -------------------------------------------------------------------
    // Divider registers: classic 32-cycle shift/restore division
    // rq = {remainder[31:0], quotient[31:0]}, shifted left 1 bit/cycle
    // -------------------------------------------------------------------
    reg [31:0] divisor;
    reg [63:0] rq;
    reg [5:0]  bit_cnt;
    reg        div_by_zero;

    // Top 32 bits of {rq,1'b0} i.e. remainder candidate after 1-bit shift
    wire [31:0] rem_shifted = rq[62:31];
    // Trial subtraction (33-bit to catch borrow/sign)
    wire [32:0] trial_sub   = {1'b0, rem_shifted} - {1'b0, divisor};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                   <= S_IDLE;
            cycle_cnt               <= 32'd0;
            latency_cycles          <= 32'd0;
            compression_ratio_x100  <= 16'd0;
            monitor_valid           <= 1'b0;
            divisor                 <= 32'd0;
            rq                      <= 64'd0;
            bit_cnt                 <= 6'd0;
            div_by_zero             <= 1'b0;
        end else begin
            monitor_valid <= 1'b0; // default deasserted; pulses only in S_VALID

            case (state)
                // -------------------------------------------------------
                S_IDLE: begin
                    cycle_cnt <= 32'd0;
                    if (pipeline_start)
                        state <= S_COUNT;
                end

                // -------------------------------------------------------
                S_COUNT: begin
                    cycle_cnt <= cycle_cnt + 32'd1;
                    if (pipeline_done)
                        state <= S_LATCH;
                end

                // -------------------------------------------------------
                S_LATCH: begin
                    latency_cycles <= cycle_cnt;

                    // dividend = input_count * 8 * 100 = input_count * 800
                    rq          <= {32'd0, (input_count * 32'd800)};
                    divisor     <= token_count * 32'd9;
                    div_by_zero <= (token_count == 16'd0);
                    bit_cnt     <= 6'd32;
                    state       <= S_DIVIDE;
                end

                // -------------------------------------------------------
                S_DIVIDE: begin
                    if (div_by_zero) begin
                        // token_count == 0 -> undefined ratio, saturate high
                        rq[31:0] <= 32'hFFFF_FFFF;
                        state    <= S_VALID;
                    end else if (bit_cnt == 6'd0) begin
                        state <= S_VALID;
                    end else begin
                        if (trial_sub[32]) begin
                            // negative -> restore remainder, quotient bit = 0
                            rq <= {rem_shifted, rq[30:0], 1'b0};
                        end else begin
                            // non-negative -> quotient bit = 1
                            rq <= {trial_sub[31:0], rq[30:0], 1'b1};
                        end
                        bit_cnt <= bit_cnt - 6'd1;
                    end
                end

                // -------------------------------------------------------
                S_VALID: begin
                    if (rq[31:0] > 32'h0000_FFFF)
                        compression_ratio_x100 <= 16'hFFFF; // saturate
                    else
                        compression_ratio_x100 <= rq[15:0];

                    monitor_valid <= 1'b1;
                    state         <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
