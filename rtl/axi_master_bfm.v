// axis_master_bfm.v
`timescale 1ns/1ps

module axis_master_bfm #(
    parameter DATA_WIDTH = 32,
    parameter FILE_PATH = "tensor_data.hex"
) (
    input  wire                    clk,
    input  wire                    rst_n,
    output reg  [DATA_WIDTH-1:0]   tdata,
    output reg                     tvalid,
    output reg                     tlast,
    input  wire                    tready,
    output reg                     done
);

    reg [DATA_WIDTH-1:0] data_mem [0:2047];
    integer file_handle;
    integer num_samples;
    integer idx;
    integer scan_status;
    
    localparam S_IDLE = 2'd0,
               S_READ = 2'd1,
               S_SEND = 2'd2,
               S_DONE = 2'd3;
    
    reg [1:0] state;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            tdata       <= 0;
            tvalid      <= 1'b0;
            tlast       <= 1'b0;
            done        <= 1'b0;
            idx         <= 0;
            num_samples <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    done  <= 1'b0;
                    state <= S_READ;
                end
                
                S_READ: begin
                    file_handle = $fopen(FILE_PATH, "r");
                    if (file_handle == 0) begin
                        $error("CRITICAL ERROR: Failed to open path: %s", FILE_PATH);
                        state <= S_DONE;
                    end else begin
                        idx = 0;
                        scan_status = $fscanf(file_handle, "%h\n", data_mem[idx]);
                        while (scan_status == 1 && idx < 2048) begin
                            idx = idx + 1;
                            scan_status = $fscanf(file_handle, "%h\n", data_mem[idx]);
                        end
                        num_samples = idx;
                        $fclose(file_handle);
                        $display("SUCCESS: axis_master_bfm parsed %0d elements out of %s", num_samples, FILE_PATH);
                        state <= S_SEND;
                        idx   <= 0;
                    end
                end
                
                S_SEND: begin
                    if (idx < num_samples) begin
                        tdata  <= data_mem[idx];
                        tvalid <= 1'b1;
                        tlast  <= (idx == num_samples - 1);
                        
                        if (tready) begin
                            idx <= idx + 1;
                            if (idx == num_samples - 1) begin
                                state <= S_DONE;
                            end
                        end
                    end else begin
                        state <= S_DONE;
                    end
                end
                
                S_DONE: begin
                    tvalid <= 1'b0;
                    tlast  <= 1'b0;
                    done   <= 1'b1;
                    state  <= S_DONE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
    
endmodule