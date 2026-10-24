`timescale 1ns / 1ps

module accum(
    input wire clk,
    input wire reset,
    input wire tri_valid,
    input wire [10:0] bucket,

    output reg signed [31:0] acc0, acc1, acc2, acc3
);

    wire [31:0] w_word;
    reg [31:0] bias [0:3];
    wire [31:0] w0, w1, w2, w3;
    reg w_valid;

    weight_rom rom(
        .clk(clk),
        .addr(bucket),
        .dout(w_word)
    );

    initial begin
        $readmemh("hw/bias.mem", bias);
    end

    assign w0 = {{24{w_word[7]}}, w_word[7:0]};
    assign w1 = {{24{w_word[15]}}, w_word[15:8]};
    assign w2 = {{24{w_word[23]}}, w_word[23:16]};
    assign w3 = {{24{w_word[31]}}, w_word[31:24]};

    always @(posedge clk) begin
        w_valid <= tri_valid;
        if (reset) begin
            acc0 <= bias[0];
            acc1 <= bias[1];
            acc2 <= bias[2];
            acc3 <= bias[3];
            w_valid <= 0;
        end
        else if (w_valid) begin
            acc0 <= acc0 + w0;
            acc1 <= acc1 + w1;
            acc2 <= acc2 + w2;
            acc3 <= acc3 + w3;
        end
        
    end

endmodule