`timescale 1ns / 1ps

// Unit test for rtl/fifo.v. Expected interface:
//
//   module fifo #(parameter WIDTH = 33, parameter ADDR_BITS = 6) (
//       input  wire                 clk,
//       input  wire                 reset,      // active high, synchronous
//       input  wire                 wr_en,      // push wr_data on this edge
//       input  wire [WIDTH-1:0]     wr_data,
//       input  wire                 rd_en,      // pop the oldest entry on this edge
//       output wire [WIDTH-1:0]     rd_data,    // the oldest entry, valid whenever count > 0
//       output      [ADDR_BITS:0]   count       // entries stored: 0 .. 2**ADDR_BITS
//   );
//
// A push when full is ignored (even with a pop on the same edge), and a pop
// when empty is ignored. Otherwise a push and a pop on the same edge both
// happen, and count stays the same.
module tb_fifo;

    localparam WIDTH     = 33;
    localparam ADDR_BITS = 6;
    localparam DEPTH     = 1 << ADDR_BITS;

    reg                  clk;
    reg                  reset;
    reg                  wr_en;
    reg  [WIDTH-1:0]     wr_data;
    reg                  rd_en;
    wire [WIDTH-1:0]     rd_data;
    wire [ADDR_BITS:0]   count;

    fifo #(.WIDTH(WIDTH), .ADDR_BITS(ADDR_BITS)) uut (
        .clk(clk),
        .reset(reset),
        .wr_en(wr_en),
        .wr_data(wr_data),
        .rd_en(rd_en),
        .rd_data(rd_data),
        .count(count)
    );

    // Reference model: the same queue kept in a plain array.
    reg [WIDTH-1:0] model [0:DEPTH-1];
    integer m_head, m_count;
    integer errors, i, seed;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        #2000000;
        $display("TIMEOUT");
        $finish;
    end

    // Compares the FIFO outputs with the model (between edges).
    task check_state;
        input [8*24-1:0] where;
        begin
            if (count !== m_count) begin
                $display("  FAIL (%0s): count %0d, expected %0d", where, count, m_count);
                errors = errors + 1;
            end
            else if (m_count > 0 && rd_data !== model[m_head]) begin
                $display("  FAIL (%0s): rd_data %h, expected %h", where, rd_data, model[m_head]);
                errors = errors + 1;
            end
        end
    endtask

    // One clock cycle with the given push/pop, applied on the falling edge,
    // with the model updated the same way the FIFO should be.
    task cycle;
        input do_push;
        input [WIDTH-1:0] data;
        input do_pop;
        reg push_ok, pop_ok;
        begin
            @(negedge clk);
            wr_en   = do_push;
            wr_data = data;
            rd_en   = do_pop;
            push_ok = do_push && (m_count < DEPTH);
            pop_ok  = do_pop && (m_count > 0);
            @(negedge clk);
            if (pop_ok) begin
                m_head  = (m_head + 1) % DEPTH;
                m_count = m_count - 1;
            end
            if (push_ok) begin
                model[(m_head + m_count) % DEPTH] = data;
                m_count = m_count + 1;
            end
            wr_en = 0;
            rd_en = 0;
            check_state("cycle");
        end
    endtask

    initial begin
        errors  = 0;
        seed    = 1;
        m_head  = 0;
        m_count = 0;
        reset   = 1;
        wr_en   = 0;
        rd_en   = 0;
        wr_data = 0;
        repeat (3) @(negedge clk);
        reset = 0;

        $display("test: empty after reset");
        check_state("reset");

        $display("test: one push, data visible straight away, one pop");
        cycle(1, 33'h1_2345_6789, 0);
        cycle(0, 0, 1);

        $display("test: fill to %0d", DEPTH);
        for (i = 0; i < DEPTH; i = i + 1)
            cycle(1, i * 3 + 33'h1_0000_0000, 0);

        $display("test: push when full is ignored");
        cycle(1, 33'h0_DEAD_BEEF, 0);

        $display("test: push and pop on the same edge when full");
        cycle(1, 33'h0_0000_00AA, 1);

        $display("test: drain in order");
        for (i = 0; i < DEPTH; i = i + 1)
            cycle(0, 0, 1);

        $display("test: pop when empty is ignored");
        cycle(0, 0, 1);

        $display("test: push and pop on the same edge when empty (push only)");
        cycle(1, 33'h0_0000_00BB, 1);
        cycle(0, 0, 1);

        $display("test: pointers wrap around (3 x depth, half full)");
        for (i = 0; i < DEPTH / 2; i = i + 1)
            cycle(1, i, 0);
        for (i = 0; i < 3 * DEPTH; i = i + 1)
            cycle(1, 1000 + i, 1);
        for (i = 0; i < DEPTH / 2; i = i + 1)
            cycle(0, 0, 1);

        $display("test: 20000 random cycles");
        for (i = 0; i < 20000; i = i + 1)
            cycle(($random(seed) & 3) != 0, {$random(seed), $random(seed)} & {WIDTH{1'b1}},
                  ($random(seed) & 3) != 0);

        $display("test: reset empties it");
        cycle(1, 7, 0);
        @(negedge clk);
        reset = 1;
        @(negedge clk);
        reset = 0;
        m_head  = 0;
        m_count = 0;
        @(negedge clk);
        check_state("after reset");

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S)", errors);
        $finish;
    end

endmodule
