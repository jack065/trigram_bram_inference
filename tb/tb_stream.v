`timescale 1ns / 1ps

module tb_stream;

    reg clk;
    reg reset;
    reg in_valid;
    reg [7:0] in_byte;
    reg in_last;
    wire done;

    wire signed [31:0] acc0, acc1, acc2, acc3;
    wire [1:0] argmax, cls;
    wire cls_valid;

    reg fast;

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
        .done(done),
        .argmax(argmax),
        .cls(cls),
        .cls_valid(cls_valid)
    );

    integer errors;
    integer n_sent;
    integer n_done;
    integer n_cls;
    integer fd;
    integer len;
    integer r;
    integer value;
    integer curr;
    reg signed [31:0] exp0, exp1, exp2, exp3;
    reg signed [31:0] s_acc0, s_acc1, s_acc2, s_acc3;

    reg signed [31:0] exp_acc0 [0:1023];
    reg signed [31:0] exp_acc1 [0:1023];
    reg signed [31:0] exp_acc2 [0:1023];
    reg signed [31:0] exp_acc3 [0:1023];

    reg [1:0] exp_argmax [0:1023];
    reg [1:0] exp_cls [0:1023];
    
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

    task send_byte_fast;
        input [7:0] c;
        input last;
        begin
            in_byte = c;
            in_valid = 1;
            in_last = last;
            @(negedge clk);
        end
    endtask

    initial begin
        #50000000;
        $display("TIMEOUT");
        $finish;
    end

    always @(negedge clk) begin
        if (done) begin
            if ((acc0 !== exp_acc0[n_done]) || (acc1 !== exp_acc1[n_done]) || (acc2 !== exp_acc2[n_done]) || (acc3 !== exp_acc3[n_done])) begin
                $display("Error at %0d", n_done);
                $display("--- Expected Values ---");
                $display("acc0 -> Expected: %0d, Got: %0d", exp_acc0[n_done], acc0);
                $display("acc1 -> Expected: %0d, Got: %0d", exp_acc1[n_done], acc1);
                $display("acc2 -> Expected: %0d, Got: %0d", exp_acc2[n_done], acc2);
                $display("acc3 -> Expected: %0d, Got: %0d", exp_acc3[n_done], acc3);
                errors = errors + 1;
            end
            n_done = n_done + 1;
        end
        if (cls_valid) begin
            if ((argmax !== exp_argmax[n_cls]) || (cls !== exp_cls[n_cls])) begin
                $display("Error at %0d", n_cls);
                $display("--- Expected Values ---");
                $display("argmax -> Expected: %0d, Got: %0d", exp_argmax[n_cls], argmax);
                $display("cls -> Expected: %0d, Got: %0d", exp_cls[n_cls], cls);
                errors = errors + 1;
            end
            n_cls = n_cls + 1;
        end
    end

    initial begin
        errors = 0;
        n_sent = 0;
        n_cls = 0;
        n_done = 0;
        in_valid = 0;
        in_last = 0;
        in_byte = 0;
        fast = 1;

        fd = $fopen("hw/vectors.txt", "r");
        if (fd == 0) begin
            $display("Could not open file.");
            
            $finish;
        end
        do_reset;
        if (fast) begin
            while ($fscanf(fd, "%h", len) == 1) begin
                for (curr = 0; curr < len; curr = curr + 1) begin
                    r = $fscanf(fd, "%h", value);
                    send_byte_fast(value[7:0], curr == len - 1);
                end

                r = $fscanf(fd, "%h", exp_acc0[n_sent]);
                r = $fscanf(fd, "%h", exp_acc1[n_sent]);
                r = $fscanf(fd, "%h", exp_acc2[n_sent]);
                r = $fscanf(fd, "%h", exp_acc3[n_sent]);

                r = $fscanf(fd, "%h", exp_argmax[n_sent]);
                r = $fscanf(fd, "%h", exp_cls[n_sent]);
                n_sent = n_sent + 1;
            end
            in_valid = 0;
            in_last = 0;
        end
        else begin
            while ($fscanf(fd, "%h", len) == 1) begin
                for (curr = 0; curr < len; curr = curr + 1) begin
                    r = $fscanf(fd, "%h", value);
                    send_byte(value[7:0], curr == len - 1);
                end

                r = $fscanf(fd, "%h", exp_acc0[n_sent]);
                r = $fscanf(fd, "%h", exp_acc1[n_sent]);
                r = $fscanf(fd, "%h", exp_acc2[n_sent]);
                r = $fscanf(fd, "%h", exp_acc3[n_sent]);

                r = $fscanf(fd, "%h", exp_argmax[n_sent]);
                r = $fscanf(fd, "%h", exp_cls[n_sent]);
                n_sent = n_sent + 1;
            end
        end
        while (n_cls != n_sent) @(negedge clk);
        $fclose(fd);
        $display("%0d sent, %0d done, %0d cls, %0d errors", n_sent, n_done, n_cls, errors);
        $finish;
    end



endmodule