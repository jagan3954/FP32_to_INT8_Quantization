//=============================================================================
// quant_engine.v
// Synchronous quantization pipeline module
// Target: Xilinx PYNQ-Z2 (xc7z020)
//
// q_data = saturate( round_half_away_from_zero(data_in / scale) + zero_point )
//
// data_in, scale : Q8.24 signed fixed point (32-bit)
//
// KEY INSIGHT ON THE DIVIDE:
//   data_in and scale share the same Q24 fractional scaling, so
//   (data_in_raw / 2^24) / (scale_raw / 2^24) = data_in_raw / scale_raw.
//   The 2^24 factors cancel exactly, so the *raw integers* can be divided
//   directly to get the real-valued ratio data_in/scale -- no fractional
//   re-normalization/shifting is required. This also means the division
//   can be done as an exact integer division with an exact remainder,
//   which makes round-half-away-from-zero trivial and exact (no precision
//   loss), unlike shifting into a wider fixed-point quotient first.
//
// DIVIDER:
//   A sequential 32-cycle shift/subtract *restoring* divider operates on
//   the unsigned magnitudes of data_in and scale. This mirrors the kind
//   of small-footprint, multi-cycle divider block reused elsewhere in the
//   precision-control datapath (e.g. precision_controller), rather than
//   inferring a huge combinational 56b divider. The FSM is NOT fully
//   pipelined: a new valid_in sample is only accepted while state==S_IDLE.
//   Latency from valid_in to valid_out is:
//       1 (load into S_DIVIDE) + 32 (divide iterations) + 1 (round/sat) +
//       1 (register into q_data/valid_out) = 35 cycles.
//   A downstream/upstream agent must track this with a shift register or,
//   as here, simply wait for valid_out before issuing the next valid_in.
//
// EDGE CASES HANDLED:
//   - data_in == 0            -> quotient forced to 0 (bypasses divider),
//                                 guarantees q_data == zero_point (clamped),
//                                 regardless of scale.
//   - scale == 0               -> defensively forces quotient to 0 rather
//                                 than propagating X's (division by zero is
//                                 not defined by the spec; this keeps the
//                                 datapath X-free in simulation/hardware).
//   - most-negative Q8.24 value (32'h8000_0000) -> its magnitude (2^31)
//                                 is computed correctly in unsigned 32-bit
//                                 arithmetic (mag32 uses two's-complement
//                                 negate-and-reinterpret-as-unsigned, which
//                                 is exact for this corner case).
//   - round-half-away-from-zero is evaluated on the *exact* integer
//                                 remainder (2*|r| vs |D|), so an exact
//                                 .5 boundary always rounds away from zero,
//                                 even when that pushes the value past the
//                                 saturation range (rounding happens BEFORE
//                                 saturation, matching typical golden
//                                 quantization references).
//=============================================================================

module quant_engine (
    input  wire               clk,
    input  wire               rst_n,

    input  wire signed [31:0] data_in,    // Q8.24
    input  wire signed [31:0] scale,      // Q8.24
    input  wire        [7:0]  zero_point,
    input  wire        [3:0]  bit_width,  // 8 or 4
    input  wire               valid_in,

    output reg  signed [7:0]  q_data,
    output reg                valid_out
);

    //-------------------------------------------------------------------
    // FSM state encoding
    //-------------------------------------------------------------------
    localparam S_IDLE   = 2'd0;
    localparam S_DIVIDE = 2'd1;
    localparam S_ROUND  = 2'd2;

    reg [1:0] state;
    reg [5:0] iter_cnt;      // 0..31 iteration counter for the divider

    // Latched operands / control (captured at S_IDLE -> S_DIVIDE/S_ROUND)
    reg         dividend_sign;
    reg         divisor_sign;
    reg [31:0]  D_mag;          // |scale|
    reg [7:0]   zp_reg;
    reg [3:0]   bw_reg;

    // Restoring divider working register: {remainder[31:0], quotient[31:0]}
    reg [63:0]  rem_quot;

    //-------------------------------------------------------------------
    // Two's-complement magnitude helper.
    // Correct even for the most-negative value: mag32(32'h8000_0000)
    // computes ~v+1 = 32'h8000_0000, which reinterpreted as UNSIGNED is
    // exactly 2^31 -- the true magnitude (no overflow, since we stay in
    // a 32-bit *unsigned* container).
    //-------------------------------------------------------------------
    function [31:0] mag32;
        input signed [31:0] v;
        begin
            mag32 = v[31] ? (~v + 32'd1) : v;
        end
    endfunction

    //-------------------------------------------------------------------
    // Combinational restoring-division step (one bit per cycle)
    //-------------------------------------------------------------------
    wire [63:0] shifted_rq  = rem_quot << 1;
    wire [31:0] shifted_up  = shifted_rq[63:32];
    wire        do_subtract = (shifted_up >= D_mag);
    wire [31:0] next_upper  = do_subtract ? (shifted_up - D_mag) : shifted_up;
    wire        next_lsb    = do_subtract;
    wire [63:0] rem_quot_nxt = {next_upper, shifted_rq[31:1], next_lsb};

    //-------------------------------------------------------------------
    // Combinational round / add zero_point / saturate (consumed only in
    // S_ROUND, but always computed from the current rem_quot contents).
    //-------------------------------------------------------------------
    wire [31:0]        q_mag   = rem_quot[31:0];
    wire [31:0]        r_mag   = rem_quot[63:32];
    wire [32:0]        twice_r = {r_mag, 1'b0};
    wire [32:0]        d_ext   = {1'b0, D_mag};
    wire                round_up   = (D_mag != 32'd0) && (twice_r >= d_ext);
    wire                result_neg = dividend_sign ^ divisor_sign;

    wire signed [39:0] q_mag_ext     = {8'd0, q_mag};
    wire signed [39:0] q_rounded_mag = q_mag_ext + (round_up ? 40'sd1 : 40'sd0);
    wire signed [39:0] q_rounded     = result_neg ? -q_rounded_mag : q_rounded_mag;
    wire signed [39:0] with_zp       = q_rounded + $signed({32'd0, zp_reg});

    wire signed [39:0] sat_val =
        (bw_reg == 4'd4) ?
            ( (with_zp >  40'sd7)  ?  40'sd7  :
              (with_zp < -40'sd7)  ? -40'sd7  : with_zp )
          : ( (with_zp >  40'sd127) ?  40'sd127 :
              (with_zp < -40'sd127) ? -40'sd127 : with_zp );

    //-------------------------------------------------------------------
    // Main FSM
    //-------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            iter_cnt      <= 6'd0;
            rem_quot      <= 64'd0;
            D_mag         <= 32'd0;
            dividend_sign <= 1'b0;
            divisor_sign  <= 1'b0;
            zp_reg        <= 8'd0;
            bw_reg        <= 4'd8;
            q_data        <= 8'sd0;
            valid_out     <= 1'b0;
        end else begin

            valid_out <= 1'b0; // default; asserted for exactly 1 cycle below

            case (state)

                //-----------------------------------------------------
                S_IDLE: begin
                    if (valid_in) begin
                        dividend_sign <= data_in[31];
                        divisor_sign  <= scale[31];
                        zp_reg        <= zero_point;
                        bw_reg        <= bit_width;

                        if (data_in == 32'sd0) begin
                            // data_in==0 always yields quotient 0, regardless
                            // of scale -- skip the divider entirely.
                            rem_quot <= 64'd0;
                            D_mag    <= mag32(scale);
                            state    <= S_ROUND;
                        end else if (scale == 32'sd0) begin
                            // Defensive: undefined division, force quotient 0
                            // instead of propagating X.
                            rem_quot <= 64'd0;
                            D_mag    <= 32'd0;
                            state    <= S_ROUND;
                        end else begin
                            rem_quot <= {32'd0, mag32(data_in)};
                            D_mag    <= mag32(scale);
                            iter_cnt <= 6'd0;
                            state    <= S_DIVIDE;
                        end
                    end
                end

                //-----------------------------------------------------
                S_DIVIDE: begin
                    rem_quot <= rem_quot_nxt;
                    if (iter_cnt == 6'd31) begin
                        state <= S_ROUND; // rem_quot_nxt above is the FINAL
                                          // result; it lands in rem_quot on
                                          // this same edge, ready to be read
                                          // combinationally next cycle in
                                          // S_ROUND.
                    end
                    iter_cnt <= iter_cnt + 6'd1;
                end

                //-----------------------------------------------------
                S_ROUND: begin
                    q_data    <= sat_val[7:0];
                    valid_out <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
