`timescale 1ns / 1ps

module tb_vectors;

    reg clk;
    reg reset;
    reg in_valid;
    reg [7:0] in_byte;
    reg in_last;
    wire done;

    wire signed [31:0] acc0, acc1, acc2, acc3;

    top uut (
        .clk(clk),
        .reset(reset),
        .in_valid(in_valid),
        .in_byte(in_byte),
        .in_last(in_last),

        .acc0(acc0),
        .acc1(acc1),
        .acc2(acc2),
        .acc3(acc3),
        .done(done)
    );

    integer errors;
    integer n_sent;
    integer fd;
    integer len;
    integer r;
    integer value;
    reg signed [31:0] exp0, exp1, exp2, exp3;

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
        input last;
        begin
            @(negedge clk);
            in_byte = c;
            in_valid = 1;
            in_last = last;
            @(negedge clk);
            in_valid = 0;
            in_last = 0;
        end
    endtask

    task run_sentence;
        integer curr;
        begin
            for (curr = 0; curr < len; curr = curr + 1) begin
                r = $fscanf(fd, "%h", value);
                send_byte(value[7:0], curr == len - 1);
            end
            while (done !== 1'b1) @(negedge clk);
        end
    endtask

    task check_result;
        begin
            r = $fscanf(fd, "%h", exp0);
            r = $fscanf(fd, "%h", exp1);
            r = $fscanf(fd, "%h", exp2);
            r = $fscanf(fd, "%h", exp3);

            r = $fscanf(fd, "%h", value);
            r = $fscanf(fd, "%h", value);

            if ((acc0 !== exp0) || (acc1 !== exp1) || (acc2 !== exp2) || (acc3 !== exp3)) begin
                $display("Error at %0d", n_sent);
                $display("--- Expected Values ---");
                $display("acc0 -> Expected: %0d, Got: %0d", exp0, acc0);
                $display("acc1 -> Expected: %0d, Got: %0d", exp1, acc1);
                $display("acc2 -> Expected: %0d, Got: %0d", exp2, acc2);
                $display("acc3 -> Expected: %0d, Got: %0d", exp3, acc3);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #50000000;
        $display("TIMEOUT");
        $finish;
    end

    initial begin
        errors = 0;
        n_sent = 0;
        in_valid = 0;
        in_last = 0;
        in_byte = 0;
        fd = $fopen("hw/vectors.txt", "r");
        if (fd == 0) begin
            $display("Could not open file.");
            
            $finish;
        end
        while ($fscanf(fd, "%h", len) == 1) begin
            do_reset;
            run_sentence;
            check_result;
            n_sent = n_sent + 1;
        end
        $fclose(fd);
        $display("%0d sentences, %0d errors", n_sent, errors);
        $finish;
    end


endmodule