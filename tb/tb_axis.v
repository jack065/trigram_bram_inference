`timescale 1ns / 1ps

// Testbench for rtl/top_axis.v, acting like the two DMA channels.
//
// Input stream (s_axis, 16 bits): [7:0] byte, [8] last byte of a sentence.
//   s_axis_tlast marks the last byte of a whole batch.
// Output stream (m_axis, 32 bits): one word per sentence, [1:0] class, [3:2] argmax.
//   m_axis_tlast must be set on the result of the last sentence of each batch.
//
// Like Python with the DMA, each batch is sent and all of its results are
// received before the next batch starts.
//
// Run with +peek to also print every cls_valid from inside the design
// (useful for stage 1, before the output stream exists).
module tb_axis;

    reg         clk;
    reg         aresetn;

    reg  [15:0] s_axis_tdata;
    reg         s_axis_tvalid;
    wire        s_axis_tready;
    reg         s_axis_tlast;

    wire [31:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready;
    wire        m_axis_tlast;

    top_axis uut (
        .aclk(clk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    // ---------------- test vectors ----------------
    localparam MAX_SENT  = 1024;
    localparam MAX_BYTES = 65536;

    reg  [7:0]  text  [0:MAX_BYTES-1];   // every sentence's bytes, back to back
    integer     start [0:MAX_SENT-1];    // where each sentence starts in text
    integer     len   [0:MAX_SENT-1];
    reg  [1:0]  vec_argmax [0:MAX_SENT-1];
    reg  [1:0]  vec_cls    [0:MAX_SENT-1];
    integer     n_vec;

    // ---------------- expected output stream ----------------
    // Filled by the sender as it sends each sentence; read by the checker.
    reg  [31:0] exp_word [0:4*MAX_SENT-1];
    reg         exp_last [0:4*MAX_SENT-1];
    integer     n_expected;    // results expected so far
    integer     n_received;    // results the checker has seen

    // ---------------- stream behaviour ----------------
    integer     ready_pct;     // % of cycles the receiver is ready
    integer     gap_pct;       // % chance of an idle cycle between input beats
    integer     seed;
    integer     errors;
    reg         saw_backpressure;

    integer fd, r, value, i, k, total;
    reg peek;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        #50000000;
        $display("TIMEOUT: %0d of %0d results received", n_received, n_expected);
        $finish;
    end

    // ---------------- receiver + checker ----------------
    // The receiver randomly holds m_axis_tready low; inputs change on falling edges.
    always @(negedge clk)
        m_axis_tready <= (($random(seed) % 100 + 100) % 100) < ready_pct;

    // A result moves on a rising edge where tvalid && tready.
    always @(posedge clk) begin
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            if (n_received >= n_expected) begin
                $display("  FAIL: extra result %h", m_axis_tdata);
                errors = errors + 1;
            end
            else if (m_axis_tdata !== exp_word[n_received] ||
                     m_axis_tlast !== exp_last[n_received]) begin
                $display("  FAIL: result #%0d got data %h last %b, expected data %h last %b",
                         n_received, m_axis_tdata, m_axis_tlast,
                         exp_word[n_received], exp_last[n_received]);
                errors = errors + 1;
            end
            n_received = n_received + 1;
        end
        if (aresetn && s_axis_tvalid && !s_axis_tready)
            saw_backpressure = 1;
    end

    // Optional: print results straight from inside the design (stage 1).
    always @(posedge clk)
        if (peek && uut.cls_valid)
            $display("  peek: cls_valid, cls %0d argmax %0d", uut.cls, uut.argmax);

    // ---------------- sender ----------------
    // One beat. Held until the rising edge where s_axis_tready is high,
    // like a real stream sender. Back-to-back calls give one beat per cycle.
    task send_beat;
        input [15:0] data;
        input        last;
        begin
            while ((($random(seed) % 100 + 100) % 100) < gap_pct) begin
                s_axis_tvalid = 0;
                @(negedge clk);
            end
            s_axis_tdata  = data;
            s_axis_tlast  = last;
            s_axis_tvalid = 1;
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            @(negedge clk);
        end
    endtask

    // Sends sentences first..first+count-1 as one batch, then waits until
    // every result of the batch has come back.
    task send_batch;
        input integer first;
        input integer count;
        integer s, b;
        begin
            for (s = first; s < first + count; s = s + 1) begin
                exp_word[n_expected] = {28'b0, vec_argmax[s], vec_cls[s]};
                exp_last[n_expected] = (s == first + count - 1);
                n_expected = n_expected + 1;
                for (b = 0; b < len[s]; b = b + 1)
                    send_beat({7'b0, b == len[s] - 1, text[start[s] + b]},
                              (s == first + count - 1) && (b == len[s] - 1));
            end
            s_axis_tvalid = 0;
            s_axis_tlast  = 0;
            while (n_received < n_expected) @(negedge clk);
        end
    endtask

    // Adds a short sentence (not from vectors.txt) with a known answer.
    task add_sentence;
        input [8*8-1:0] s;
        input integer   n;
        input [1:0]     argmax;
        input [1:0]     cls;
        integer j;
        begin
            start[n_vec] = total;
            len[n_vec]   = n;
            for (j = 0; j < n; j = j + 1) begin
                text[total] = s[8*(n-1-j) +: 8];
                total = total + 1;
            end
            vec_argmax[n_vec] = argmax;
            vec_cls[n_vec]    = cls;
            n_vec = n_vec + 1;
        end
    endtask

    integer phase_start;

    initial begin
        peek = $test$plusargs("peek");
        errors = 0;
        seed = 7;
        n_expected = 0;
        n_received = 0;
        saw_backpressure = 0;
        s_axis_tdata  = 0;
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        ready_pct = 100;
        gap_pct   = 0;

        // Load vectors.txt: len, bytes, acc0..acc3, argmax, class (all hex).
        n_vec = 0;
        total = 0;
        fd = $fopen("hw/vectors.txt", "r");
        if (fd == 0) begin
            $display("Could not open hw/vectors.txt");
            $finish;
        end
        while ($fscanf(fd, "%h", value) == 1) begin
            start[n_vec] = total;
            len[n_vec]   = value;
            for (k = 0; k < len[n_vec]; k = k + 1) begin
                r = $fscanf(fd, "%h", value);
                text[total] = value;
                total = total + 1;
            end
            for (k = 0; k < 4; k = k + 1)
                r = $fscanf(fd, "%h", value);    // scores: not part of the output stream
            r = $fscanf(fd, "%h", value);
            vec_argmax[n_vec] = value;
            r = $fscanf(fd, "%h", value);
            vec_cls[n_vec] = value;
            n_vec = n_vec + 1;
        end
        $fclose(fd);
        phase_start = n_vec;
        // 100 one-byte sentences for the backpressure test ('a' -> unknown)
        for (k = 0; k < 100; k = k + 1)
            add_sentence("a", 1, 3, 3);

        aresetn = 0;
        repeat (4) @(negedge clk);
        aresetn = 1;
        @(negedge clk);

        $display("test: one batch of all %0d sentences, full speed, receiver always ready", phase_start);
        ready_pct = 100;
        gap_pct   = 0;
        send_batch(0, phase_start);
        $display("  %0d results, %0d errors so far", n_received, errors);

        $display("test: batches of 1, 2, 7, 50 and the rest, random stalls on both sides");
        ready_pct = 50;
        gap_pct   = 20;
        send_batch(0, 1);
        send_batch(1, 2);
        send_batch(3, 7);
        send_batch(10, 50);
        send_batch(60, phase_start - 60);
        $display("  %0d results, %0d errors so far", n_received, errors);

        $display("test: receiver stalled while 100 one-byte sentences arrive (backpressure)");
        gap_pct   = 0;
        ready_pct = 0;
        saw_backpressure = 0;
        fork
            send_batch(phase_start, 100);
            begin
                repeat (2000) @(negedge clk);
                ready_pct = 100;
            end
        join
        if (!saw_backpressure) begin
            $display("  FAIL: s_axis_tready never went low while the receiver was stalled");
            errors = errors + 1;
        end
        $display("  %0d results, %0d errors so far", n_received, errors);

        $display("%0d results expected, %0d received, %0d errors", n_expected, n_received, errors);
        if (errors == 0 && n_received == n_expected)
            $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
