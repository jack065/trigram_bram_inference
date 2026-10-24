`timescale 1ns / 1ps

module tb_weight_rom;

    reg clk;
    reg [10:0] addr;
    wire [31:0] dout;

    weight_rom uut(
        .clk(clk),
        .addr(addr),
        .dout(dout)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    integer errors;

    task check_byte;
        input [10:0] test_addr;
        input [31:0] expected_weight;
        begin
            @(negedge clk);
            addr <= test_addr;
            @(negedge clk);
            if (dout !== expected_weight) begin
                $display("FAIL -> At memory (%d): expected %h, got %h", test_addr, expected_weight, dout);
                errors = errors + 1;
            end
            else begin
                $display("Pass");
            end
        end
    endtask

initial begin
    errors = 0;

    check_byte(11'd0, 32'h00000000);
    check_byte(11'd1, 32'he8f22302);
    check_byte(11'd1654, 32'h020000fe);
    check_byte(11'd2047, 32'hfefbf412);

    if (errors == 0)
        $display("All tests passed");
    else
        $display("%0d test(s) failed", errors);

    $finish;

end

endmodule