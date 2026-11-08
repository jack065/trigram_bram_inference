`timescale 1ns / 1ps
`default_nettype none

module top_axis(
    input wire aclk, aresetn,
    input wire [15:0] s_axis_tdata,
    input wire s_axis_tvalid,
    input wire s_axis_tlast,
    input wire m_axis_tready,
    
    output wire [31:0] m_axis_tdata,
    output wire m_axis_tvalid,
    output wire m_axis_tlast,
    output wire s_axis_tready
);

    wire [7:0] in_byte;
    wire in_last, in_valid;
    wire signed [31:0] acc0, acc1, acc2, acc3;
    wire [1:0] argmax, cls;
    wire cls_valid, done;

    wire [32:0] fifo_out;
    wire [6:0] fifo_count;

    reg [15:0] n_in, n_out, n_total;
    reg end_seen;
    wire last_result;

    assign last_result = end_seen && (n_out + 1 == n_total);

    assign in_valid = (s_axis_tvalid && s_axis_tready);
    assign in_byte = s_axis_tdata[7:0];
    assign in_last = s_axis_tdata[8];

    assign s_axis_tready = (fifo_count < 48);
    assign m_axis_tvalid = (fifo_count != 0);
    assign m_axis_tdata = fifo_out[31:0];
    assign m_axis_tlast = fifo_out[32];

    top u_top(
        .clk(aclk),
        .reset(~aresetn),
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

    fifo #(.WIDTH(33), .ADDR_BITS(6)) u_fifo (
        .clk(aclk),
        .reset(~aresetn),
        .wr_en(cls_valid),
        .wr_data({last_result, 28'b0, argmax, cls}),
        .rd_en(m_axis_tvalid && m_axis_tready),
        .rd_data(fifo_out),
        .count(fifo_count)
    );

    always @(posedge aclk) begin
        if (!aresetn) begin
            end_seen <= 0;
            n_in <= 0;
            n_out <= 0;
            n_total <= 0;
        end
        else begin
            if (in_valid && in_last) n_in <= n_in + 1;
            if (in_valid && s_axis_tlast) begin
                end_seen <= 1;
                n_total <= n_in + 1;
            end
            if (cls_valid) n_out <= n_out + 1;
            if (cls_valid && last_result) begin
                n_in <= 0;
                n_out <= 0;
                end_seen <= 0;
            end
        end
    end


endmodule

`default_nettype wire