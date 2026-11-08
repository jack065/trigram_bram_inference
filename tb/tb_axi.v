`timescale 1ns / 1ps

module tb_axi;

    reg clk;
    reg aresetn;

    // write address / write data / write response
    reg  [4:0]  awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;

    // read address / read data
    reg  [4:0]  araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    top_axi uut (
        .s_axi_aclk(clk),
        .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready)
    );

    // Register offsets
    localparam DATA    = 5'h00;
    localparam STATUS  = 5'h04;
    localparam ACC0    = 5'h08;
    localparam ACC1    = 5'h0C;
    localparam ACC2    = 5'h10;
    localparam ACC3    = 5'h14;
    localparam CONTROL = 5'h18;
    localparam CYCLES  = 5'h1C;

    integer errors;
    integer polls;
    reg [31:0] status;
    reg signed [31:0] a0, a1, a2, a3;
    reg [31:0] cyc;
    reg [31:0] tmp;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish;
    end

    // One AXI4-Lite write, the way the ARM would do it.
    // awready/wready are sampled on the rising edge, which is when the
    // handshake actually happens; inputs change on falling edges.
    task axi_write;
        input [4:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr  = addr;
            wdata   = data;
            wstrb   = 4'hf;
            awvalid = 1;
            wvalid  = 1;
            bready  = 1;

            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);

            @(negedge clk);
            awvalid = 0;
            wvalid  = 0;

            while (bvalid !== 1'b1) @(negedge clk);
            if (bresp !== 2'b00) begin
                $display("  FAIL: write to %h got bresp %b", addr, bresp);
                errors = errors + 1;
            end

            // bvalid && bready on the next rising edge completes the response
            @(negedge clk);
            bready = 0;
        end
    endtask

    // One AXI4-Lite read: address on AR, data back on R.
    task axi_read;
        input  [4:0]  addr;
        output [31:0] data;
        begin
            @(negedge clk);
            araddr  = addr;
            arvalid = 1;
            rready  = 1;

            @(posedge clk);
            while (!arready) @(posedge clk);

            @(negedge clk);
            arvalid = 0;

            while (rvalid !== 1'b1) @(negedge clk);
            data = rdata;
            if (rresp !== 2'b00) begin
                $display("  FAIL: read from %h got rresp %b", addr, rresp);
                errors = errors + 1;
            end

            // rvalid && rready on the next rising edge completes the read
            @(negedge clk);
            rready = 0;
        end
    endtask

    // Sends a string one byte per DATA write, with bit 8 set on the last byte.
    task send_string;
        input [8*64-1:0] s;
        input integer len;
        integer k;
        begin
            for (k = 0; k < len; k = k + 1)
                axi_write(DATA, {23'b0, k == len - 1, s[8*(len-1-k) +: 8]});
        end
    endtask

    // Polls STATUS until "result ready" (bit 0) is set, like Python will.
    task wait_result;
        begin
            polls = 1;
            axi_read(STATUS, status);
            while (status[0] !== 1'b1 && polls < 200) begin
                axi_read(STATUS, status);
                polls = polls + 1;
            end
            if (status[0] !== 1'b1) begin
                $display("  FAIL: STATUS never reported a result");
                errors = errors + 1;
            end
        end
    endtask

    // Reads the class from STATUS and the scores and cycle count from their
    // registers, then compares them with the expected values.
    task check_result;
        input [1:0] exp_cls;
        input [1:0] exp_argmax;
        input signed [31:0] e0, e1, e2, e3;
        begin
            axi_read(STATUS, status);
            axi_read(ACC0, a0);
            axi_read(ACC1, a1);
            axi_read(ACC2, a2);
            axi_read(ACC3, a3);
            axi_read(CYCLES, cyc);

            if (status[2:1] !== exp_cls || status[4:3] !== exp_argmax ||
                a0 !== e0 || a1 !== e1 || a2 !== e2 || a3 !== e3) begin
                $display("  FAIL: cls %0d argmax %0d acc %0d %0d %0d %0d",
                         status[2:1], status[4:3], a0, a1, a2, a3);
                $display("        expected cls %0d argmax %0d acc %0d %0d %0d %0d",
                         exp_cls, exp_argmax, e0, e1, e2, e3);
                errors = errors + 1;
            end
            else begin
                $display("  pass: cls %0d argmax %0d acc %0d %0d %0d %0d, %0d cycles, %0d STATUS polls",
                         status[2:1], status[4:3], a0, a1, a2, a3, cyc, polls);
            end
        end
    endtask

    initial begin
        errors  = 0;
        aresetn = 0;
        awaddr  = 0;
        awvalid = 0;
        wdata   = 0;
        wstrb   = 0;
        wvalid  = 0;
        bready  = 0;
        araddr  = 0;
        arvalid = 0;
        rready  = 0;

        repeat (4) @(negedge clk);
        aresetn = 1;

        $display("test: soft reset, then STATUS reads 0");
        axi_write(CONTROL, 32'h1);
        axi_read(STATUS, status);
        if (status !== 32'h0) begin
            $display("  FAIL: STATUS = %h after reset", status);
            errors = errors + 1;
        end
        else
            $display("  pass");

        $display("test: write-only registers read as 0");
        axi_read(DATA, tmp);
        axi_read(CONTROL, status);
        if (tmp !== 32'h0 || status !== 32'h0) begin
            $display("  FAIL: DATA reads %h, CONTROL reads %h", tmp, status);
            errors = errors + 1;
        end
        else
            $display("  pass");

        $display("test: abc");
        send_string("abc", 3);
        wait_result;
        check_result(3, 3, -242, -212, -191, 645);

        $display("test: clear result ready");
        axi_write(CONTROL, 32'h2);
        axi_read(STATUS, status);
        if (status[0] !== 1'b0) begin
            $display("  FAIL: STATUS bit 0 still set after clear");
            errors = errors + 1;
        end
        else
            $display("  pass");

        $display("test: confident book_flight (accepted)");
        send_string("Book me a flight from Boston to Denver next Friday.", 51);
        wait_result;
        check_result(0, 0, 674, -71, -557, -49);

        $display("test: book_flight below threshold (rejected)");
        axi_write(CONTROL, 32'h2);
        send_string("I want to fly from Chicago to Seattle on the 12th.", 50);
        wait_result;
        check_result(3, 0, 334, -163, -343, 171);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d ERROR(S)", errors);
        $finish;
    end

endmodule
