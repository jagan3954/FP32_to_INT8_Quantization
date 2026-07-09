// =============================================================================
// zrle_decoder.v
// Companion decoder for zrle_encoder. Reconstructs the original q_data stream
// from a token stream of {flag,payload} pairs.
//
// Token format (tok_data[8:0]) - same as encoder's comp_data:
//   bit[8] = 0 -> literal token,  payload = signed 8-bit value  (bits[7:0])
//   bit[8] = 1 -> zero-run token, payload = run length 1..255   (bits[7:0])
//
// Protocol notes (mirrors the encoder's no-backpressure simplicity):
//   - One token is consumed per cycle while in IDLE.
//   - A run token of length N expands into N samples over N cycles: the
//     first zero is emitted the same cycle the token is accepted, then the
//     module stays busy (state RUN) for N-1 further cycles before it will
//     accept the next token. The producer of tok_data must not assert
//     tok_in_valid again until that expansion is complete.
// =============================================================================
`timescale 1ns/1ps

module zrle_decoder (
    input  wire              clk,
    input  wire              rst_n,
    input  wire [8:0]        tok_data,
    input  wire              tok_in_valid,

    output reg  signed [7:0] q_data,
    output reg               out_valid
);

    localparam IDLE = 1'b0,
               RUN  = 1'b1;

    reg       state;
    reg [7:0] run_left;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            run_left  <= 8'd0;
            q_data    <= 8'sd0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= 1'b0; // default

            case (state)
                IDLE: begin
                    if (tok_in_valid) begin
                        if (tok_data[8]) begin
                            // run-length token: emit first zero now
                            q_data    <= 8'sd0;
                            out_valid <= 1'b1;
                            if (tok_data[7:0] > 8'd1) begin
                                run_left <= tok_data[7:0] - 8'd1;
                                state    <= RUN;
                            end
                            // count==1 -> single zero emitted, stay IDLE
                        end else begin
                            // literal token
                            q_data    <= tok_data[7:0];
                            out_valid <= 1'b1;
                        end
                    end
                end

                RUN: begin
                    q_data    <= 8'sd0;
                    out_valid <= 1'b1;
                    if (run_left > 8'd1) begin
                        run_left <= run_left - 8'd1;
                    end else begin
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
