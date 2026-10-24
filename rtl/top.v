`timescale 1ns / 1ps

module top(
    input wire clk,
    input wire reset,
    input wire in_valid,
    input wire [7:0] in_byte,

    output wire signed [31:0] acc0, acc1, acc2, acc3
);

    wire tri_valid;
    wire [10:0] bucket;

    trigram rom1(
        .clk(clk),
        .reset(reset),
        .in_valid(in_valid),
        .bucket(bucket),
        .in_byte(in_byte),
        .tri_valid(tri_valid)
    );

    accum rom2(
        .clk(clk),
        .reset(reset),
        .tri_valid(tri_valid),
        .bucket(bucket),

        .acc0(acc0),
        .acc1(acc1),
        .acc2(acc2),
        .acc3(acc3)
    );
endmodule
