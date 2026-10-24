`timescale 1ns / 1ps

// Test bench for reading mem
// module tb_input_check;

//     reg clk;
//     reg reset;
//     reg start;
//     wire active;
//     wire done;

//     mem_check uut (
//         .clk(clk),
//         .reset(reset),
//         .start(start),
//         .active(active),
//         .done(done)
//     );

//     initial begin
//         clk = 0;
//         forever #5 clk = ~clk; // 100MHz clock
//     end

//     initial begin
//         reset = 1;
//         start = 0;
//         #20;
//         reset = 0;
//         #10;
//         start = 1; // Start the process
//         #10;
//         start = 0; // Deassert start
//         wait (done === 1'b1);
//         $finish;
//     end
// endmodule

// Test Bench for normalizing inputs
// module tb_normalize_check;

//     reg clk;
//     reg reset;
//     reg start;
//     wire active;
//     wire done;
//     reg [7:0] in_byte;
//     wire is_punct;
//     wire [7:0] norm_byte;

//     mem_check uut (
//         .clk(clk),
//         .reset(reset),
//         .start(start),
//         .in_byte(in_byte),
//         .active(active),
//         .done(done),
//         .is_punct(is_punct),
//         .norm_byte(norm_byte)
//     );

//     integer errors;

//     task check_byte;
//         input [7:0] test_byte;
//         input expected_punct;
//         input [7:0] expected_norm;
//         begin
//             in_byte = test_byte;
//             #1; // allow combinational outputs to settle

//             if (is_punct !== expected_punct ||
//                 norm_byte !== expected_norm) begin
//                 $display("FAIL input=%h: punct got %b expected %b; norm got %h expected %h",
//                         test_byte, is_punct, expected_punct,
//                         norm_byte, expected_norm);
//                 errors = errors + 1;
//             end
//             else begin
//                 $display("PASS input=%h", test_byte);
//             end
//         end
//     endtask

//     initial begin
//         errors = 0;

//         check_byte(8'h20, 1'b0, 8'h20);
//         check_byte(8'h21, 1'b1, 8'h21);
//         check_byte(8'h2F, 1'b1, 8'h2F);
//         check_byte(8'h30, 1'b0, 8'h30);
//         check_byte(8'h41, 1'b0, 8'h61); // uppercase A becomes lowercase a
//         check_byte(8'h5A, 1'b0, 8'h7A); // uppercase Z becomes lowercase z
//         check_byte(8'h5F, 1'b1, 8'h5F);
//         check_byte(8'h7E, 1'b1, 8'h7E);
//         check_byte(8'h7F, 1'b0, 8'h7F);

//         if (errors == 0)
//             $display("All tests passed");
//         else
//             $display("%0d test(s) failed", errors);

//         $finish;
//     end
// endmodule