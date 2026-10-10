`timescale 1ns/1ps
//
// Run-skill harness: pcileech_bar_impl_mz0380_mb (+ pcileech_mz0380_periph)
// driver testbench. Drives the BAR0 mailbox through its real register
// interface (wr_* / rd_req_* / rd_rsp_*) and checks the command FSM and the
// peripheral path.
//
// Register map (byte addr): 0x00 DOORBELL, 0x04 PARAM0/opcode, 0x08 PARAM1,
// 0x0c PARAM2, 0x10 PARAM3, 0x14 PARAM4 .. 0x2c STATUS, 0x30 EVENT.
// Doorbell 0x800 = fire, 0x400 = ack. STATUS boot=0xDDDDDDDD, ok=0xAAAAAAAA.
//
module tb_mailbox;
    import mz0380_pkg::*;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic [31:0] wr_addr = 0, wr_data = 0;
    logic [3:0]  wr_be = 0;
    logic        wr_valid = 0;
    logic [87:0] rd_req_ctx = 0;
    logic [31:0] rd_req_addr = 0;
    logic        rd_req_valid = 0;
    logic [87:0] rd_rsp_ctx;
    logic [31:0] rd_rsp_data;
    logic        rd_rsp_valid;
    logic [255:0] mz_vid_base;
    logic [2:0]  mz_vid_slots;
    logic        mz_arm, mz_int_ack;

    pcileech_bar_impl_mz0380_mb dut (
        .rst(rst), .clk(clk),
        .wr_addr(wr_addr), .wr_be(wr_be), .wr_data(wr_data), .wr_valid(wr_valid),
        .rd_req_ctx(rd_req_ctx), .rd_req_addr(rd_req_addr), .rd_req_valid(rd_req_valid),
        .rd_rsp_ctx(rd_rsp_ctx), .rd_rsp_data(rd_rsp_data), .rd_rsp_valid(rd_rsp_valid),
        .mz_vid_base(mz_vid_base), .mz_vid_slots(mz_vid_slots),
        .mz_arm(mz_arm), .mz_int_ack(mz_int_ack),
        .mz_frame_done(1'b0), .mz_frame_token(32'h0)
    );

    integer errors = 0, g;
    logic [31:0] v;

    task automatic wbar(input [31:0] a, input [31:0] d);
        @(negedge clk); wr_addr = a; wr_data = d; wr_be = 4'hf; wr_valid = 1'b1;
        @(negedge clk); wr_valid = 1'b0;
    endtask

    task automatic rbar(input [31:0] a, output [31:0] d);
        @(negedge clk); rd_req_addr = a; rd_req_valid = 1'b1;
        d = 32'hx;
        for (g = 0; g < 8; g = g + 1) begin
            @(posedge clk);
            if (rd_rsp_valid) d = rd_rsp_data;        // addr held: pipe settles to regs[a]
        end
        @(negedge clk); rd_req_valid = 1'b0;
    endtask

    task automatic fire(input [7:0] op);
        wbar(32'h04, {24'h0, op});                     // PARAM0 = opcode
        wbar(32'h00, 32'h0000_0800);                   // DOORBELL = MZ_FIRE
        repeat (6) @(posedge clk);                     // dispatch + periph capture
    endtask

    task automatic chk(input [31:0] got, input [31:0] exp, input string name);
        if (got === exp) $display("  PASS  %0s = 0x%08h", name, got);
        else begin $display("  FAIL  %0s = 0x%08h (exp 0x%08h)", name, got, exp); errors = errors + 1; end
    endtask

    initial begin
        rst = 1; repeat (4) @(posedge clk); rst = 0; @(posedge clk);

        // T1: boot stamp at reset
        rbar(32'h2c, v); chk(v, 32'hDDDD_DDDD, "T1 STATUS boot stamp");

        // T2: INIT -> ok stamp + EVENT bit11 (CMD_DONE)
        fire(8'h01);
        rbar(32'h2c, v); chk(v, 32'hAAAA_AAAA, "T2 STATUS ok stamp");
        rbar(32'h30, v);
        if (v[11]) $display("  PASS  T2 EVENT bit11 set (0x%08h)", v);
        else begin $display("  FAIL  T2 EVENT bit11 (0x%08h)", v); errors = errors + 1; end

        // T3: GET_BOARD_VERSION -> PARAM1/PARAM2 = fw version
        fire(8'h0a);
        rbar(32'h08, v); chk(v, MZ_FW_VERSION_MAJOR, "T3 fw major");
        rbar(32'h0c, v); chk(v, MZ_FW_VERSION_MINOR, "T3 fw minor");

        // T4: SET_BUF_VID -> slot table + slot count.
        //   slot0 = {PARAM3(hi), PARAM4(lo)} so base[31:0] = PARAM4.
        wbar(32'h08, 32'h0000_0000);                   // PARAM1 channel
        wbar(32'h0c, 32'h0000_02d0);                   // PARAM2 stride
        wbar(32'h10, 32'h0000_dead);                   // PARAM3 phys hi
        wbar(32'h14, 32'hbeef_0000);                   // PARAM4 phys lo
        fire(8'h02);
        if (mz_vid_slots == 3'd4) $display("  PASS  T4 vid_slots = 4");
        else begin $display("  FAIL  T4 vid_slots = %0d", mz_vid_slots); errors = errors + 1; end
        chk(mz_vid_base[31:0], 32'hbeef_0000, "T4 slot0 lo");
        chk(mz_vid_base[63:32], 32'h0000_dead, "T4 slot0 hi");

        // T5: START / STOP -> mz_arm
        fire(8'h06);
        if (mz_arm) $display("  PASS  T5 START -> mz_arm=1"); else begin $display("  FAIL  T5 START"); errors = errors + 1; end
        fire(8'h07);
        if (!mz_arm) $display("  PASS  T5 STOP -> mz_arm=0"); else begin $display("  FAIL  T5 STOP"); errors = errors + 1; end

        // T6: bridge REG write/read round-trip through the periph.
        //   Exercises the per-shape PARAM mux {chip=PARAM1,reg=PARAM2,val=PARAM3}
        //   and the read-result capture into PARAM3 (regs[4], addr 0x10).
        wbar(32'h08, 32'h0000_0090);                   // PARAM1 chip = bridge 0x90
        wbar(32'h0c, 32'h0000_0019);                   // PARAM2 reg  = 0x19 (RW)
        wbar(32'h10, 32'h0000_00ab);                   // PARAM3 val  = 0xAB
        fire(8'h1b);                                   // REG_WRITE
        wbar(32'h08, 32'h0000_0090);                   // PARAM1 chip
        wbar(32'h0c, 32'h0000_0019);                   // PARAM2 reg
        wbar(32'h10, 32'h0000_0000);                   // clear PARAM3 so a stale 0xAB can't false-pass
        fire(8'h1a);                                   // REG_READ
        rbar(32'h10, v); chk(v, 32'h0000_00ab, "T6 bridge reg round-trip -> PARAM3");

        // T7: MST read with the receiver unpowered (GPIO pin9 low).
        //   NOTE: the modeled GPIO set only drives the low 8 shadow bits, so
        //   pin9 (MST power) can't be raised from the mailbox; the no-signal
        //   MST constants therefore stay gated. Here that reads back 0 (NAK).
        wbar(32'h08, 32'h0000_009c);                   // PARAM1 chip = MST 0x9c
        wbar(32'h0c, 32'h0000_0055);                   // PARAM2 reg  = 0x55 (DETECT)
        wbar(32'h10, 32'h0000_0000);
        fire(8'h1a);                                   // I2C read
        rbar(32'h10, v);
        if (v == 32'h0) $display("  INFO  T7 MST read unpowered -> 0x%08h (NAK, pin9 gate)", v);
        else            $display("  INFO  T7 MST read -> 0x%08h", v);

        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
