`timescale 1ns / 1ps

module tb_top;

    reg clk;
    reg reset;
    reg in_valid;
    reg [7:0] in_byte;

    wire signed [31:0] acc0, acc1, acc2, acc3;

    top uut (
        .clk(clk),
        .reset(reset),
        .in_valid(in_valid),
        .in_byte(in_byte),

        .acc0(acc0),
        .acc1(acc1),
        .acc2(acc2),
        .acc3(acc3)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    task do_reset;
        begin
            @(negedge clk);
            reset = 1;
            @(negedge clk);
            @(negedge clk);
            reset = 0;
        end
    endtask

    task send_byte;
        input [7:0] c;
        begin
            @(negedge clk);
            in_byte = c;
            in_valid = 1;
            @(negedge clk);
            in_valid = 0;
        end
    endtask

    task send_string;
        input [8*64-1:0] s;
        input integer len;
        integer k;
        begin
            for (k = 0; k < len; k = k + 1)
                send_byte(s[8*(len-1-k) +: 8]);

            repeat (3) @(negedge clk);
        end
    endtask


    initial begin
        reset = 1;

        $display("test: abc");
        do_reset;
        send_string("abc", 3);
        $display("acc0: %0d", acc0);
        $display("acc1: %0d", acc1);
        $display("acc2: %0d", acc2);
        $display("acc3: %0d", acc3);
        do_reset;

        $display("test: Hi, Bob!");
        do_reset;
        send_string("Hi, Bob!", 8);
        $display("acc0: %0d", acc0);
        $display("acc1: %0d", acc1);
        $display("acc2: %0d", acc2);
        $display("acc3: %0d", acc3);
        do_reset;

        $finish;

    end



endmodule