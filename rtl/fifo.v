`timescale 1ns / 1ps
`default_nettype none

module fifo #(
    parameter WIDTH     = 33,
    parameter ADDR_BITS = 6
) (
    input wire clk,
    input wire reset,
    input wire wr_en,
    input wire [WIDTH-1:0] wr_data,
    input wire rd_en,

    output wire [WIDTH-1:0] rd_data,
    output reg [ADDR_BITS:0] count
);

    reg [WIDTH - 1:0] mem [0:(1 << ADDR_BITS) - 1];
    reg [ADDR_BITS - 1:0] wr_ptr, rd_ptr;

    wire full;
    wire empty;
    wire do_push;
    wire do_pop;

    assign full = (count == (1 << ADDR_BITS));
    assign empty = (count == 0);
    assign do_push = (wr_en && !full);
    assign do_pop = (rd_en && !empty);

    assign rd_data = mem[rd_ptr];

    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
        end
        else begin
            if (do_push) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= wr_ptr + 1;
            end
            if (do_pop) rd_ptr <= rd_ptr + 1;
            case ({do_push, do_pop})
                2'b01: count <= count - 1;
                2'b10: count <= count + 1;
                default: count <= count;
            endcase
        end
    end

endmodule

`default_nettype wire