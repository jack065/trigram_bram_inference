`timescale 1ns / 1ps

module tb_accum;

    reg clk;
    reg reset;
    reg tri_valid;
    reg [10:0] bucket;

    wire signed [31:0] acc0, acc1, acc2, acc3;

    accum uut(
        .clk(clk),
        .reset(reset),
        .tri_valid(tri_valid),
        .bucket(bucket),

        .acc0(acc0),
        .acc1(acc1),
        .acc2(acc2),
        .acc3(acc3)
    );


    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end


    task send_bucket;
        input [10:0] sent_bucket;
        begin
            @(negedge clk);
            bucket <= sent_bucket;
            tri_valid <= 1;
            @(negedge clk);
            tri_valid <= 0;
            #10;
            $display("acc0: %0d", acc0);
            $display("acc1: %0d", acc1);
            $display("acc2: %0d", acc2);
            $display("acc3: %0d", acc3);
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            reset = 1;
            @(negedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    initial begin
        do_reset;
        send_bucket(11'd1654);
        do_reset;
        send_bucket(11'd349);
        send_bucket(11'd1345);
        send_bucket(11'd1019);
        send_bucket(11'd1720);

        $finish;
    end

endmodule