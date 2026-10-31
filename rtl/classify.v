`timescale 1ns / 1ps

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

    reg v1, v2, v3, v4;
    reg signed [31:0] max01, max23, max;
    reg [1:0] idx01, idx23;

    always @(posedge clk) begin
        if (reset) begin
            v1 <= 0;
            v2 <= 0;
            v3 <= 0;
            v4 <= 0;

            cls_valid <= 0;
        end
        else begin
            v1 <= start;
            v2 <= v1;
            v3 <= v2;
            v4 <= v3;

            if (start) begin
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
                if (max23 > max01) begin
                    max <= max23;
                    argmax <= idx23;
                end
                else begin
                    max <= max01;
                    argmax <= idx01;
                end
            end

            if (v2) begin

            end

            if (v3) begin

            end

            if (v4) begin

            end
        end
    end
endmodule