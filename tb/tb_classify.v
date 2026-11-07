`timescale 1ns/1ps

module tb_classify;

    reg clk;
    reg reset;
    reg start;
    wire [1:0] argmax;
    wire [1:0] cls;
    wire cls_valid;

    reg signed [31:0] acc0, acc1, acc2, acc3;

    classify uut (
        .clk(clk),
        .reset(reset),
        .start(start),

        .acc0(acc0),
        .acc1(acc1),
        .acc2(acc2),
        .acc3(acc3),

        .argmax(argmax),
        .cls(cls),
        .cls_valid(cls_valid)
    );

    integer error = 0;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    task check_row;
        input signed [31:0] a0;
        input signed [31:0] a1;
        input signed [31:0] a2;
        input signed [31:0] a3;
        input [1:0] ex_argmax;
        input [1:0] ex_cls;

        begin
            @(negedge clk);
            acc0 = a0;
            acc1 = a1;
            acc2 = a2;
            acc3 = a3;
            start = 1;
            @(negedge clk);
            start = 0;

            while (cls_valid !== 1) @(negedge clk);
            if ((ex_argmax == argmax) && (ex_cls == cls)) begin
                $display("Sum: %0d", uut.sum);
                $display("Pass");
            end
            else begin
                $display("Fail");
                $display("Sum: %0d", uut.sum);
                $display("Expected argmax: %d, got: %d", ex_argmax, argmax);
                $display("Expected class: %d, got: %d", ex_cls, cls);
                error = error + 1;
            end

            // repeat (4) @(negedge clk);
            // // $display("Argmax: %0d", argmax);
            // // $display("Max: %0d", uut.max);
            // $display("uut.addr0: %0d", uut.addr0);
            // $display("uut.addr1: %0d", uut.addr1);
            // $display("uut.addr2: %0d", uut.addr2);
            // $display("uut.addr3: %0d", uut.addr3);
        end
    endtask

    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

    initial begin
        reset = 1;
        start = 0;
        repeat (2) @(negedge clk);
        reset = 0;
        check_row(674, -71, -557, -49,   0, 0);   // accepted
        check_row(91,   3, -310, 218,    3, 3);   // winner is "other"
        check_row(334, -163, -343, 171,  0, 3);   // rejected by threshold
        check_row(5, 5, 5, 5,            0, 3);   // tie → argmax 0
        check_row(5000, 0, 0, 0,         0, 0);   // huge gap → clamp
        $display("Error count: %d", error);
        $finish;
    end
endmodule