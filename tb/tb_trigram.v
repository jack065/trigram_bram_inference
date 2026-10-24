`timescale 1ns / 1ps

module tb_trigram;

    reg clk;
    reg reset;
    reg in_valid;
    reg [7:0] in_byte;
    wire tri_valid;
    wire [7:0] b0, b1, b2;
    wire [10:0] bucket;

    trigram uut (
        .clk(clk),
        .reset(reset),
        .in_valid(in_valid),
        .in_byte(in_byte),
        .tri_valid(tri_valid),
        .b0(b0),
        .b1(b1),
        .b2(b2),
        .bucket(bucket)
    );


    reg [23:0] expected [0:31];
    integer n_expected;
    integer n_seen;
    integer errors;
    integer i;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    initial begin
        $dumpfile("tri.vcd");
        $dumpvars(0, tb_trigram);
    end

    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

    always @(negedge clk) begin
        if (!reset && tri_valid) begin
            if (n_seen >= n_expected) begin
                $display("  FAIL: extra trigram %h", {b0, b1, b2});
                errors = errors + 1;
            end
            else if ({b0, b1, b2} !== expected[n_seen]) begin
                $display("  FAIL: trigram #%0d got %h expected %h",
                         n_seen, {b0, b1, b2}, expected[n_seen]);
                errors = errors + 1;
            end
            else begin
                $display("  pass: %h", {b0, b1, b2});
                $display("  Bucket Value: %0d", bucket);
            end
            n_seen = n_seen + 1;
        end
    end

    task do_reset;
        begin
            @(negedge clk);
            reset = 1;
            @(negedge clk);
            @(negedge clk);
            reset = 0;
            n_expected = 0;
            n_seen = 0;
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
        end
    endtask

    task expect_tri;
        input [23:0] t;
        begin
            expected[n_expected] = t;
            n_expected = n_expected + 1;
        end
    endtask

    task end_test;
        begin
            repeat (5) @(posedge clk);   // idle cycles: catches tri_valid stuck high
            if (n_seen != n_expected) begin
                $display("  FAIL: got %0d trigrams, expected %0d", n_seen, n_expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        reset = 1;
        in_valid = 0;
        in_byte = 0;

        $display("test: abc");
        do_reset;
        expect_tri(24'h616263);
        send_string("abc", 3);
        end_test;

        $display("test: ABC (uppercase)");
        do_reset;
        expect_tri(24'h616263);
        send_string("ABC", 3);
        end_test;

        $display("test: Hi, Bob!");
        do_reset;
        expect_tri(24'h686920);
        expect_tri(24'h692062);
        expect_tri(24'h20626f);
        expect_tri(24'h626f62);
        send_string("Hi, Bob!", 8);
        end_test;

        $display("test: ab (too short)");
        do_reset;
        send_string("ab", 2);
        end_test;

        $display("test: gaps between bytes");
        do_reset;
        expect_tri(24'h616263);
        send_byte("a");
        repeat (3) @(negedge clk);
        send_byte("b");
        repeat (3) @(negedge clk);
        send_byte("c");
        end_test;

        $display("test: reset clears the window");
        do_reset;
        send_string("ab", 2);
        do_reset;
        expect_tri(24'h636465);
        send_string("cde", 3);
        end_test;

        $display("test: long string abcdefghijkl");
        do_reset;
        for (i = 0; i < 10; i = i + 1)
            expect_tri({8'h61 + i[7:0], 8'h62 + i[7:0], 8'h63 + i[7:0]});
        send_string("abcdefghijkl", 12);
        end_test;

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S)", errors);
        $finish;
    end
endmodule