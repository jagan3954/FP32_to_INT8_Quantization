// axis_slave_bfm.v
`timescale 1ns/1ps

module axis_slave_bfm #(
    parameter DATA_WIDTH = 9,
    parameter FILE_PATH = "output_tokens.hex"
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [DATA_WIDTH-1:0]   tdata,
    input  wire                    tvalid,
    input  wire                    tlast,  // Added missing port here
    output reg                     tready,
    output reg                     done
);
    
    integer file_handle;
    integer idx;
    
    localparam S_IDLE    = 2'd0,
               S_CAPTURE = 2'd1,
               S_DONE    = 2'd2;
    
    reg [1:0] state;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            tready      <= 1'b0;
            done        <= 1'b0;
            idx         <= 0;
            file_handle <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    tready      <= 1'b1;
                    idx         <= 0;
                    done        <= 1'b0;
                    file_handle = $fopen(FILE_PATH, "w");
                    if (file_handle == 0) begin
                        $error("CRITICAL ERROR: Failed to create output capture file: %s", FILE_PATH);
                        state <= S_DONE;
                    end else begin
                        state <= S_CAPTURE;
                    end
                end
                
                S_CAPTURE: begin
                    tready <= 1'b1;
                    if (tvalid && tready) begin
                        $fwrite(file_handle, "%03h\n", tdata);
                        idx <= idx + 1;
                        if (tlast) begin
                            $fflush(file_handle);
                            $fclose(file_handle);
                            $display("SUCCESS: axis_slave_bfm safely committed %0d tokens via TLAST edge to %s", idx, FILE_PATH);
                            state <= S_DONE;
                        end
                    end
                end
                
                S_DONE: begin
                    tready <= 1'b0;
                    done   <= 1'b1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
    
endmodule