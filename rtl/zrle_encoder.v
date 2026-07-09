// =============================================================================
// zrle_encoder.v
// Zero-Run-Length Encoder for a quantized (int8) tensor stream.
// Target: Xilinx PYNQ-Z2 (xc7z020), fully synchronous, single clock domain.
//
// Token format (comp_data[8:0]):
//   bit[8] = 0 -> literal token,  payload = signed 8-bit value  (bits[7:0])
//   bit[8] = 1 -> zero-run token, payload = run length 1..255   (bits[7:0])
//
// Protocol notes (IMPORTANT for integration):
//   - This module has NO ready/backpressure output. It accepts one q_data
//     sample per cycle whenever valid_in=1, EXCEPT while it is internally
//     flushing a queued run-token + literal-token pair (FSM state FLUSH).
//     The producer must not assert valid_in again until the module has
//     finished flushing. In this simple design that means: after sending a
//     sample that terminates a zero-run (a non-zero sample, or a sample with
//     last_in=1), wait for comp_valid to have pulsed for every expected
//     output token before sending the next sample. The included testbenches
//     do this with generous fixed idle gaps.
// =============================================================================
`timescale 1ns/1ps

module zrle_encoder (
    input  wire              clk,
    input  wire              rst_n,
    input  wire signed [7:0] q_data,
    input  wire              valid_in,
    input  wire              last_in,     // final element of the tensor

    output reg  [8:0]        comp_data,   // {flag, payload}
    output reg               comp_valid,
    output reg  [15:0]       token_count  // running count of emitted tokens
);

    localparam [1:0] IDLE  = 2'd0,
                      ZEROS = 2'd1,
                      FLUSH = 2'd2;

    reg [1:0]  state;
    reg [15:0] zero_count;   // uncapped consecutive-zero counter (accumulation phase)
    reg [15:0] remaining;    // zeros left to flush as run-tokens (post-cap splitting)
    reg [7:0]  pending_data; // non-zero literal waiting to be emitted after a run flush
    reg        pending_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            comp_data     <= 9'd0;
            comp_valid    <= 1'b0;
            token_count   <= 16'd0;
            zero_count    <= 16'd0;
            remaining     <= 16'd0;
            pending_data  <= 8'd0;
            pending_valid <= 1'b0;
        end else begin
            comp_valid <= 1'b0; // default: de-assert unless a branch below emits a token

            case (state)
                // ---------------------------------------------------------
                IDLE: begin
                    if (valid_in) begin
                        if (q_data == 8'sd0) begin
                            zero_count <= 16'd1;
                            if (last_in) begin
                                // single zero that is also the last element:
                                // must flush a run of length 1, nothing after it.
                                remaining     <= 16'd1;
                                pending_valid <= 1'b0;
                                state         <= FLUSH;
                            end else begin
                                state <= ZEROS;
                            end
                        end else begin
                            // non-zero literal passes straight through
                            comp_data   <= {1'b0, q_data};
                            comp_valid  <= 1'b1;
                            token_count <= token_count + 16'd1;
                            // stays IDLE (whether or not last_in - nothing more to do)
                        end
                    end
                end

                // ---------------------------------------------------------
                ZEROS: begin
                    if (valid_in) begin
                        if (q_data == 8'sd0) begin
                            zero_count <= zero_count + 16'd1;
                            if (last_in) begin
                                // run terminated by end-of-tensor: flush only,
                                // no literal follows.
                                remaining     <= zero_count + 16'd1;
                                pending_valid <= 1'b0;
                                state         <= FLUSH;
                            end
                            // else: keep accumulating, stay in ZEROS
                        end else begin
                            // non-zero sample ends the run: flush run, then literal
                            remaining     <= zero_count;
                            pending_data  <= q_data;
                            pending_valid <= 1'b1;
                            state         <= FLUSH;
                        end
                    end
                end

                // ---------------------------------------------------------
                FLUSH: begin
                    if (remaining != 16'd0) begin
                        // emit one run-token per cycle, capped at 255 payload
                        if (remaining > 16'd255) begin
                            comp_data <= {1'b1, 8'd255};
                            remaining <= remaining - 16'd255;
                        end else begin
                            comp_data <= {1'b1, remaining[7:0]};
                            remaining <= 16'd0;
                        end
                        comp_valid  <= 1'b1;
                        token_count <= token_count + 16'd1;
                        // stay in FLUSH: next cycle re-checks remaining/pending
                    end else if (pending_valid) begin
                        comp_data     <= {1'b0, pending_data};
                        comp_valid    <= 1'b1;
                        token_count   <= token_count + 16'd1;
                        pending_valid <= 1'b0;
                        state         <= IDLE;
                    end else begin
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
