`timescale 1ns / 1ps

module mem_check(
    input  wire clk,
    input  wire reset,
    input  wire start,
    input wire [7:0] in_byte,
    output reg  active,
    output reg done,
    output wire is_punct,
    output wire [7:0] norm_byte
);
    
    reg [2:0] count;
    reg [31:0] bias [0:3];
    assign is_punct = ((8'h21 <= in_byte && in_byte <= 8'h2F) || 
                        ((8'h3A <= in_byte && in_byte <= 8'h40)) || 
                        ((8'h5B <= in_byte && in_byte <= 8'h60)) || 
                        (8'h7B <= in_byte && in_byte <= 8'h7E));
    assign norm_byte = (8'h41 <= in_byte && in_byte <= 8'h5A) ? in_byte | 8'h20 : in_byte;

    
    initial begin
        $readmemh("hw/bias.mem", bias);
    end

    always @(posedge clk) begin
        if (reset) begin
            count <= 3'd0;
            active <= 1'b0;
            done <= 1'b0;
        end 
        else begin
            done <= 1'b0;

            if (start && !active) begin
                active <= 1'b1;
                count <= 3'd0;
            end 
            else if (active) begin

                $display("bias[%d] = %h", count, bias[count]);

                if (count == 3'd3) begin
                    active <= 1'b0;
                    done <= 1'b1;
                    count <= 3'd0;
                end 
                else begin
                    count <= count + 1'b1;
                end
            end
        end
    end
endmodule
