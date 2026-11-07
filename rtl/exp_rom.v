`timescale 1ns / 1ps
`default_nettype none

module exp_rom(
    input wire clk,
    input wire [10:0] addr,
    output reg [15:0] dout
);

    // Building the memory array
    (* rom_style = "block" *) reg [15:0] lut_mem [0:2047];

    reg [15:0] dout_q;

    initial begin
        $readmemh("hw/exp_lut.mem", lut_mem);
    end

    // Fetching in a clocked block allows my code to use BRAM compared to building it out purely from logic cells
    always @(posedge clk) begin
        dout_q <= lut_mem[addr];
        dout <= dout_q;
    end

endmodule

`default_nettype wire