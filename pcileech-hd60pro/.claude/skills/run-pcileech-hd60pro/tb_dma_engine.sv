`timescale 1ns/1ps
//
// Run-skill harness: pcileech_dma_engine driver testbench.
//
// Drives the DMA engine through its REAL interfaces -- the AXIS TLP source
// (IfAXIS128) and the mz_* control bus -- acting as the sink. No vendor PCIe
// IP is involved; this is the same TLP beat stream the sink mux would consume.
//
// T1 full burst : assert START, sink always ready, count the emitted TLPs and
//                 sum their payload bytes. Expect 6227 TLPs and 0x30a5c0 bytes
//                 (the exact-byte total is also the no-double-send check).
// T2 STOP abort : drop mz_arm mid-TLP and confirm the in-flight TLP still runs
//                 to a full 512 B tlast (not truncated), no further TLP starts,
//                 and the engine goes idle.
//
module tb_dma_engine;
    import mz0380_pkg::*;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;                 // 100 MHz

    logic [15:0]  pcie_id = 16'h0100;
    logic [255:0] vid_base;
    logic [2:0]   vid_slots;
    logic         arm;
    logic         int_ack = 1'b0;

    IfAXIS128 axis();                     // DUT is .source; TB drives .tready

    pcileech_dma_engine dut (
        .rst(rst), .clk(clk),
        .pcie_id(pcie_id),
        .tlps_out(axis.source),
        .mz_vid_base(vid_base),
        .mz_vid_slots(vid_slots),
        .mz_arm(arm),
        .mz_int_ack(int_ack),
        .mz_frame_done(), .mz_frame_token(), .mz_int_req()
    );

    logic tready_r = 1'b0;
    assign axis.tready = tready_r;

    integer tlp_count, payload_bytes, cur_tlp_bytes, beats;
    integer dbeats, watchdog, post, last_tlp_bytes, i, errors;
    logic   saw_tlast;

    function automatic integer popcnt4(input [3:0] v);
        popcnt4 = v[0] + v[1] + v[2] + v[3];
    endfunction

    initial begin
        errors = 0;
        rst = 1; arm = 0; tready_r = 0; vid_slots = 0; vid_base = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: full burst totals ----------------------------------
        vid_base = 256'h0; vid_base[31:0] = 32'h4000_0000; vid_slots = 3'd4;
        tready_r = 1'b1; arm = 1'b1;
        tlp_count = 0; payload_bytes = 0; beats = 0; watchdog = 0;
        while (!(tlp_count >= 6227 && !axis.tvalid)) begin
            @(posedge clk);
            if (axis.tvalid && axis.tready) begin
                beats = beats + 1;
                if (axis.tuser[0]) tlp_count = tlp_count + 1;      // header beat
                else payload_bytes = payload_bytes + popcnt4(axis.tkeepdw) * 4;
            end
            watchdog = watchdog + 1;
            if (watchdog > 2000000) begin
                $display("ERROR: T1 watchdog"); errors = errors + 1; break;
            end
        end
        $display("T1 full burst: tlps=%0d payload=%0d (0x%0h) beats=%0d",
                 tlp_count, payload_bytes, payload_bytes, beats);
        if (tlp_count == 6227)      $display("  PASS  tlp count = 6227");
        else begin                  $display("  FAIL  tlp count != 6227"); errors = errors + 1; end
        if (payload_bytes == 32'h30a5c0) $display("  PASS  payload = 0x30a5c0");
        else begin                  $display("  FAIL  payload != 0x30a5c0"); errors = errors + 1; end

        // ---- T2: STOP mid-TLP aborts at the boundary -----------------
        arm = 0; repeat (20) @(posedge clk);          // let engine return to IDLE
        tlp_count = 0; cur_tlp_bytes = 0; dbeats = 0; saw_tlast = 0;
        last_tlp_bytes = -1; watchdog = 0;
        vid_slots = 3'd4; tready_r = 1'b1; arm = 1'b1;
        // phase A: accept 5 data beats of TLP1, then STOP (mid-TLP: needs 32)
        while (dbeats < 5) begin
            @(posedge clk);
            if (axis.tvalid && axis.tready) begin
                if (axis.tuser[0]) begin tlp_count = tlp_count + 1; cur_tlp_bytes = 0; end
                else begin cur_tlp_bytes = cur_tlp_bytes + popcnt4(axis.tkeepdw)*4; dbeats = dbeats + 1; end
            end
            watchdog = watchdog + 1;
            if (watchdog > 2000) begin $display("ERROR: T2a watchdog"); errors = errors + 1; break; end
        end
        arm = 0;                                       // STOP, mid-TLP
        // phase B: current TLP must still finish (tlast at full 512 B)
        watchdog = 0;
        while (!saw_tlast) begin
            @(posedge clk);
            if (axis.tvalid && axis.tready) begin
                if (axis.tuser[0]) begin tlp_count = tlp_count + 1; cur_tlp_bytes = 0; end
                else cur_tlp_bytes = cur_tlp_bytes + popcnt4(axis.tkeepdw)*4;
                if (axis.tlast) begin saw_tlast = 1; last_tlp_bytes = cur_tlp_bytes; end
            end
            watchdog = watchdog + 1;
            if (watchdog > 2000) begin $display("ERROR: T2b watchdog"); errors = errors + 1; break; end
        end
        // phase C: no further beats (engine idle)
        post = 0;
        for (i = 0; i < 300; i = i + 1) begin
            @(posedge clk);
            if (axis.tvalid && axis.tready) post = post + 1;
        end
        $display("T2 abort: completed-TLP bytes=%0d tlp_count=%0d post-stop beats=%0d",
                 last_tlp_bytes, tlp_count, post);
        if (last_tlp_bytes == 512) $display("  PASS  in-flight TLP ran to full 512 B");
        else begin                 $display("  FAIL  in-flight TLP truncated"); errors = errors + 1; end
        if (tlp_count == 1)        $display("  PASS  only the in-flight TLP emitted");
        else begin                 $display("  FAIL  extra TLP started after STOP"); errors = errors + 1; end
        if (post == 0)             $display("  PASS  engine idle after abort");
        else begin                 $display("  FAIL  beats after idle"); errors = errors + 1; end

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
