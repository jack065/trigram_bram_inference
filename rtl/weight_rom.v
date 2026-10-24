`timescale 1ns / 1ps

module weight_rom(
    input wire clk,
    input wire [10:0] addr,
    output reg [31:0] dout
);

    // Building the memory array
    reg [31:0] weight_mem [0:2047];

    initial begin
        $readmemh("hw/weights.mem", weight_mem);
    end

    // Fetching in a clocked block allows my code to use BRAM compared to building it out purely from logic cells
    always @(posedge clk) begin
        dout <= weight_mem[addr];
    end

endmodule