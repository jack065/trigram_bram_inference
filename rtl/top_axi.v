`timescale 1ns / 1ps
`default_nettype none

module top_axi(
    input wire s_axi_aclk,
    input wire s_axi_aresetn,
    input wire [4:0] s_axi_awaddr,
    input wire s_axi_awvalid,
    input wire s_axi_bready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    input wire [4:0] s_axi_araddr,
    input wire s_axi_arvalid,
    input wire s_axi_rready,

    output reg s_axi_rvalid,
    output reg [31:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_arready,
    output wire s_axi_bvalid,
    output wire s_axi_wready,
    output wire [1:0] s_axi_bresp,
    output wire s_axi_awready
);

    assign s_axi_arready = (s_axi_arvalid && (!s_axi_rvalid));
    assign s_axi_rresp = 2'b00;

    reg [7:0] in_byte;
    reg in_last, in_valid;
    reg soft_reset, bvalid;

    reg signed [31:0] acc0_q, acc1_q, acc2_q, acc3_q;
    reg [1:0] cls_q, argmax_q;
    reg result_ready;
    reg [31:0] cycles;
    reg counting;

    wire signed [31:0] acc0, acc1, acc2, acc3;
    wire [1:0] argmax, cls;
    wire done, cls_valid, top_reset;

    top u_top(
        .clk(s_axi_aclk),
        .reset(top_reset),
        .in_valid(in_valid),
        .in_byte(in_byte),
        .in_last(in_last),

        .acc0(acc0),
        .acc1(acc1),
        .acc2(acc2),
        .acc3(acc3),

        .done(done),
        .argmax(argmax),
        .cls(cls),
        .cls_valid(cls_valid)
    );

    assign top_reset = ~s_axi_aresetn | soft_reset;
    assign s_axi_awready = ((s_axi_awvalid && s_axi_wvalid) && (!bvalid));
    assign s_axi_wready = ((s_axi_awvalid && s_axi_wvalid) && (!bvalid));
    assign s_axi_bvalid = bvalid;
    assign s_axi_bresp = 2'b00;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            bvalid <= 0;
            in_valid <= 0;
            soft_reset <= 0;
            result_ready <= 0;
            counting <= 0;
            s_axi_rvalid <= 0;
            cls_q <= 0;
            argmax_q <= 0;
            acc0_q <= 0;
            acc1_q <= 0;
            acc2_q <= 0;
            acc3_q <= 0;
            counting <= 0;

        end
        else begin
            in_valid <= 0;
            soft_reset <= 0;

            // Writes
            if (bvalid && s_axi_bready) bvalid <= 0;

            if (s_axi_awvalid && s_axi_wvalid && s_axi_awready && s_axi_wready) begin
                bvalid <= 1;
                if (s_axi_awaddr[4:2] == 3'd0) begin
                    in_byte <= s_axi_wdata[7:0];
                    in_last <= s_axi_wdata[8];
                    in_valid <= 1;

                    if (!counting) begin
                        cycles <= 0;
                        counting <= 1;
                    end
                end
                else if (s_axi_awaddr[4:2] == 3'd6) begin
                    if (s_axi_wdata[0]) begin
                        soft_reset <= 1;
                        counting <= 0;
                    end
                    if (s_axi_wdata[1]) result_ready <= 0;
                end
            end

            // Reads
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                case (s_axi_araddr[4:2])
                    3'd0: s_axi_rdata <= 0;
                    3'd1: s_axi_rdata <= {27'b0, argmax_q, cls_q, result_ready};
                    3'd2: s_axi_rdata <= acc0_q;
                    3'd3: s_axi_rdata <= acc1_q;
                    3'd4: s_axi_rdata <= acc2_q;
                    3'd5: s_axi_rdata <= acc3_q;
                    3'd6: s_axi_rdata <= 0;
                    3'd7: s_axi_rdata <= cycles;
                    default: s_axi_rdata <= 0;
                endcase
            end

            if (counting) cycles <= cycles + 1;

            if (done) begin
                acc0_q <= acc0;
                acc1_q <= acc1;
                acc2_q <= acc2;
                acc3_q <= acc3;
            end

            if (cls_valid) begin
                cls_q <= cls;
                argmax_q <= argmax;
                result_ready <= 1;
                counting <= 0;
            end
        end
    end


endmodule
`default_nettype wire