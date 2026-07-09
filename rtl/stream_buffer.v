// =============================================================================
// stream_buffer.v
// Synchronous FIFO, single write port / single read port, inferred BRAM
// Target: Xilinx PYNQ-Z2 (xc7z020)
//
// Read is registered (1-cycle latency from rd_en to valid rd_data) so that
// Vivado infers a true block-RAM read port rather than distributed RAM/LUTRAM.
// Write and read live in separate always blocks with independent address
// counters, which is the standard Xilinx-recommended coding style (UG901)
// for inferring simple dual-port BRAM.
//
// full/empty are derived from an explicit element counter, so DEPTH does not
// need to be a power of two.
// =============================================================================

module stream_buffer #(
    parameter DEPTH = 1024,
    parameter WIDTH = 32
)(
    input  wire               clk,
    input  wire                rst_n,

    input  wire [WIDTH-1:0]    wr_data,
    input  wire                 wr_en,
    output wire                 full,

    output wire [WIDTH-1:0]    rd_data,
    input  wire                 rd_en,
    output wire                 empty
);

    localparam AW  = (DEPTH > 1) ? $clog2(DEPTH)   : 1;
    localparam CW  = $clog2(DEPTH + 1);

    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    reg [AW-1:0] wr_ptr;
    reg [AW-1:0] rd_ptr;
    reg [CW-1:0] count;
    reg [WIDTH-1:0] rd_data_reg;

    assign full  = (count == DEPTH[CW-1:0]);
    assign empty = (count == {CW{1'b0}});

    wire wr_valid = wr_en && !full;
    wire rd_valid = rd_en && !empty;

    // -------------------------------------------------------------------
    // Write port
    // -------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {AW{1'b0}};
        end else if (wr_valid) begin
            mem[wr_ptr] <= wr_data;
            wr_ptr      <= (wr_ptr == DEPTH-1) ? {AW{1'b0}} : wr_ptr + 1'b1;
        end
    end

    // -------------------------------------------------------------------
    // Read port (registered output -> BRAM read latency = 1 cycle)
    // -------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr      <= {AW{1'b0}};
            rd_data_reg <= {WIDTH{1'b0}};
        end else if (rd_valid) begin
            rd_data_reg <= mem[rd_ptr];
            rd_ptr      <= (rd_ptr == DEPTH-1) ? {AW{1'b0}} : rd_ptr + 1'b1;
        end
    end

    // -------------------------------------------------------------------
    // Element counter (correct for simultaneous read+write: net change 0)
    // -------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= {CW{1'b0}};
        end else begin
            case ({wr_valid, rd_valid})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count; // 00 (idle) or 11 (push+pop, no net change)
            endcase
        end
    end

    assign rd_data = rd_data_reg;

endmodule
