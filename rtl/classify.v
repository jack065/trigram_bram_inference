`timescale 1ns / 1ps
`default_nettype none

module classify(
    input wire clk,
    input wire reset,
    input wire start,
    input wire signed [31:0] acc0, acc1, acc2, acc3,

    output reg [1:0] argmax,
    output reg [1:0] cls,
    output reg cls_valid
);

    `include "hw/model_params.vh"

    reg v1, v2, v3, v4, v5, v6;
    reg signed [31:0] max01, max23, max;
    reg [1:0] idx01, idx23, s2_argmax, s3_argmax, s4_argmax, s5_argmax, s6_argmax;

    wire signed [31:0] diff0, diff1, diff2, diff3;
    reg [10:0] addr0, addr1, addr2, addr3;
    reg signed [31:0] s1_acc0, s1_acc1, s1_acc2, s1_acc3, s2_acc0, s2_acc1, s2_acc2, s2_acc3, d0, d1, d2, d3;

    assign diff0 = max - s2_acc0;
    assign diff1 = max - s2_acc1;
    assign diff2 = max - s2_acc2;
    assign diff3 = max - s2_acc3;

    wire [15:0] e0, e1, e2, e3;

    exp_rom lut0(
        .clk(clk),
        .addr(addr0),
        .dout(e0)
    );

    exp_rom lut1(
        .clk(clk),
        .addr(addr1),
        .dout(e1)
    );

    exp_rom lut2(
        .clk(clk),
        .addr(addr2),
        .dout(e2)
    );

    exp_rom lut3(
        .clk(clk),
        .addr(addr3),
        .dout(e3)
    );

    wire [15:0] m0, m1, m2, m3;
    wire [17:0] sum;

    assign m0 = (s6_argmax == 2'd0) ? 0: e0;
    assign m1 = (s6_argmax == 2'd1) ? 0: e1;
    assign m2 = (s6_argmax == 2'd2) ? 0: e2;
    assign m3 = (s6_argmax == 2'd3) ? 0: e3;

    assign sum = m0 + m1 + m2 + m3;

    always @(posedge clk) begin
        if (reset) begin
            v1 <= 0;
            v2 <= 0;
            v3 <= 0;
            v4 <= 0;
            v5 <= 0;
            cls_valid <= 0;
        end
        else begin
            v1 <= start;
            v2 <= v1;
            v3 <= v2;
            v4 <= v3;
            v5 <= v4;
            v6 <= v5;
            cls_valid <= v6;

            if (start) begin
                s1_acc0 <= acc0;
                s1_acc1 <= acc1;
                s1_acc2 <= acc2;
                s1_acc3 <= acc3;
                if (acc1 > acc0) begin
                    max01 <= acc1;
                    idx01 <= 1;
                end
                else begin
                    max01 <= acc0;
                    idx01 <= 0;
                end

                if (acc3 > acc2) begin
                    max23 <= acc3;
                    idx23 <= 3;
                end
                else begin
                    max23 <= acc2;
                    idx23 <= 2;
                end
            end

            if (v1) begin
                s2_acc0 <= s1_acc0;
                s2_acc1 <= s1_acc1;
                s2_acc2 <= s1_acc2;
                s2_acc3 <= s1_acc3;
                if (max23 > max01) begin
                    max <= max23;
                    s2_argmax <= idx23;
                end
                else begin
                    max <= max01;
                    s2_argmax <= idx01;
                end
            end

            if (v2) begin
                s3_argmax <= s2_argmax;
                d0 <= diff0;
                d1 <= diff1;
                d2 <= diff2;
                d3 <= diff3;
            end

            if (v3) begin
                s4_argmax <= s3_argmax;
                addr0 <= (| d0[31:11]) ? 2047 : d0[10:0];
                addr1 <= (| d1[31:11]) ? 2047 : d1[10:0];
                addr2 <= (| d2[31:11]) ? 2047 : d2[10:0];
                addr3 <= (| d3[31:11]) ? 2047 : d3[10:0];
            end

            if (v4) begin
                s5_argmax <= s4_argmax;
            end

            if (v5) begin
                s6_argmax <= s5_argmax;
            end

            if (v6) begin
                argmax <= s6_argmax;
                if ((s6_argmax == 2'd3) || (sum > THRESH_SUM)) begin
                    cls <= 2'd3;
                end
                else begin
                    cls <= s6_argmax;
                end
            end
        end
    end
endmodule

`default_nettype wire