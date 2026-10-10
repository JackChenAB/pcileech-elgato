//
// PCILeech FPGA - MZ0380 (Elgato HD60 Pro) BAR0 command mailbox emulation.
//
// Emulates the card's host-visible mailbox: doorbell-driven command FSM,
// STATUS stamps, EVENT word, frame-completion writeback. Protocol constants
// in pcileech_mz0380_pkg.sv; behaviour per Wolffyx hd60pro-linux-driver RE
// (RE_FINDINGS.md M4/M17/M40). Spec: HD60PRO_DESIGN.md section 2.
//
// Sits in the i_bar0 slot of pcileech_tlps128_bar_controller: 2-cycle read
// latency matching pcileech_bar_impl_zerowrite4k.
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"
import mz0380_pkg::*;

module pcileech_bar_impl_mz0380_mb (
    input               rst,
    input               clk,
    // standard bar_controller interface (2-cycle read latency)
    input  [31:0]       wr_addr,
    input  [3:0]        wr_be,
    input  [31:0]       wr_data,
    input               wr_valid,
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid,
    // mz0380 event bus
    output bit [255:0]  mz_vid_base,     // 4 x {hi,lo} phys, video window (op 0x02)
    output bit [2:0]    mz_vid_slots,    // 0 = none programmed, else 4
    output bit          mz_arm,          // START (0x06) sets, STOP (0x07) clears
    output bit          mz_int_ack,      // 1-cycle pulse on doorbell 0x400
    input               mz_frame_done,   // 1-cycle pulse from dma engine
    input  [31:0]       mz_frame_token   // engine frame token
);

    // ------------------------------------------------------------------
    // Register file: BAR0 words 0x000..0x1fc, indexed by addr[8:2]
    //   word 0        doorbell (write)
    //   word 1..10    PARAM0(opcode)..PARAM9
    //   word 11       STATUS (boot stamp at reset; 0xaaaaaaaa on cmd done)
    //   word 12       EVENT
    //   word 16..19   EVT_PAYLOAD0..3 (0x40/44/48/4c)
    //   word 20..23   ENC_STATUS[0..15] bytes (0x50..)
    // ------------------------------------------------------------------
    bit [31:0]  regs [0:127];

    // doorbell value seen in the same cycle as PARAM writes latches the
    // PRE-doorbell PARAM contents (regs update first in the same always
    // block: reads of regs[] below use their old values by NBA semantics).
    bit [7:0]   cmd_opcode;

    // periph handoff (one fire = one op; p_rd/p_wr are 1-cycle pulses).
    // The periph registers its result, so rdata/nak are valid the cycle
    // after p_rd: p_rd_d delays the read pulse to align the result capture.
    bit         p_rd;
    bit         p_wr;
    bit         p_rd_d;
    bit [7:0]   p_rdata;
    bit         p_nak;

    // LOAD_FILES (0x6e) 4 KiB scratch (M76)
    bit [7:0]   lf_mem [0:4095];
    bit [15:0]  lf_offset;
    bit         lf_wr_fire;

    function automatic bit periph_is_wr( input bit [7:0] op );
        case ( op )
            MZ_CMD_GPIO_SET, MZ_CMD_GPIO_DIR, MZ_CMD_REG_WRITE,
            MZ_CMD_I2C_WRITE_S, MZ_CMD_I2C_COMBO: return 1'b1;
            default:                              return 1'b0;
        endcase
    endfunction

    function automatic bit periph_is_rd( input bit [7:0] op );
        case ( op )
            MZ_CMD_GPIO_READ, MZ_CMD_REG_READ, MZ_CMD_I2C_READ_S: return 1'b1;
            default:                                              return 1'b0;
        endcase
    endfunction

    // GPIO ops (0x14/0x15/0x17) carry {mask=PARAM1, data=PARAM2}; the I2C /
    // bridge ops carry {chip=PARAM1, reg=PARAM2, value=PARAM3}. PARAM(i) lives
    // in regs[1+i] (PARAM0 = regs[1] = opcode), so the periph's reg/wdata
    // inputs shift by one word between the two command shapes.
    wire        is_gpio_op  = (cmd_opcode == MZ_CMD_GPIO_READ) ||
                              (cmd_opcode == MZ_CMD_GPIO_SET)  ||
                              (cmd_opcode == MZ_CMD_GPIO_DIR);
    wire [7:0]  periph_chip  = regs[2][7:0];                        // PARAM1
    wire [7:0]  periph_reg   = is_gpio_op ? regs[2][7:0]            // PARAM1 (mask)
                                          : regs[3][7:0];           // PARAM2 (reg)
    wire [7:0]  periph_wdata = is_gpio_op ? regs[3][7:0]            // PARAM2 (data)
                                          : regs[4][7:0];           // PARAM3 (value)
    // EDID bulk payload = PARAM4..PARAM7 = regs[5..8], 16 bytes LSB-first.
    wire [127:0] periph_bulk = { regs[8], regs[7], regs[6], regs[5] };

    function automatic bit [127:0] lf_read16( input bit [15:0] off );
        bit [127:0] d;
        for ( int k = 0; k < 16; k++ )
            d[8*k +: 8] = lf_mem[(off + 16'(k)) & 12'hfff];
        return d;
    endfunction

    // frame completion bookkeeping
    bit [3:0]   frame_cnt;      // done-count nibble packed into EVT_PAYLOAD0
    bit         token_lo;       // low bits of frame token

    // ------------------------------------------------------------------
    // write path
    // ------------------------------------------------------------------
    wire [6:0]  wr_word         = wr_addr[8:2];                 // 0..127
    wire        wr_is_doorbell  = wr_valid && (wr_word == 0);
    wire        wr_is_param     = wr_valid && (wr_word >= 1) && (wr_word <= 10);
    wire        wr_is_generic   = wr_valid && (wr_word >= 11) && !wr_is_doorbell;

    always @ ( posedge clk ) begin
        if ( rst ) begin
            regs[11]    <= MZ_BOOT_STAMP;                       // STATUS: boot stamp (M4)
            regs[12]    <= 32'h0;                               // EVENT
            regs[16]    <= 32'h0;                               // EVT_PAYLOAD0
            regs[17]    <= 32'h0;
            regs[18]    <= 32'h0;                               // ENC_STATUS bytes all 0
            regs[19]    <= 32'h0;
            regs[20]    <= 32'h0;
            regs[21]    <= 32'h0;
            regs[22]    <= 32'h0;
            regs[23]    <= 32'h0;
            mz_vid_base <= 256'h0;
            mz_vid_slots<= 3'd0;
            mz_arm      <= 1'b0;
            mz_int_ack  <= 1'b0;
            cmd_opcode  <= 8'h0;
            frame_cnt   <= 4'd0;
            token_lo    <= 1'b0;
            p_rd        <= 1'b0;
            p_wr        <= 1'b0;
            p_rd_d      <= 1'b0;
            lf_wr_fire  <= 1'b0;
        end
        else begin
            mz_int_ack  <= 1'b0;                                // default: pulse low
            p_rd        <= 1'b0;                                // default: 1-cycle pulse
            p_wr        <= 1'b0;                                // default: 1-cycle pulse
            p_rd_d      <= p_rd;                                // delayed read pulse
            lf_wr_fire  <= 1'b0;                                // default: 1-cycle pulse

            // generic host writes to STATUS/EVENT/payload words (incl. the
            // ENC_STATUS clear handshake, M40)
            if ( wr_is_generic ) begin
                regs[wr_word] <= wr_data;
            end
            // host PARAM writes
            if ( wr_is_param ) begin
                regs[wr_word] <= wr_data;
            end

            // doorbell
            if ( wr_is_doorbell ) begin
                if ( wr_data == MZ_FIRE ) begin
                    cmd_opcode  <= regs[1][7:0];                // opcode = PARAM0
                    regs[11]    <= MZ_OK_STAMP;                 // success stamp
                    regs[12][MZ_EVENT_CMD_DONE] <= 1'b1;
                    // dispatch
                    case ( regs[1][7:0] )
                        MZ_CMD_INIT: begin
                            // stamp suffices (M4: answered on attempt 1)
                        end
                        MZ_CMD_GET_BOARD_VERSION: begin
                            regs[2] <= MZ_FW_VERSION_MAJOR;     // PARAM1
                            regs[3] <= MZ_FW_VERSION_MINOR;     // PARAM2
                        end
                        MZ_CMD_SET_BUF_VID: begin
                            // M17 12-word shape: word2=PARAM1=channel (regs[2]),
                            // word3=PARAM2=stride (regs[3]), word4..11 = 4x
                            // (phys_hi, phys_lo) = regs[4..11]. regs[11] doubles
                            // as the STATUS word (0x2c); the success stamp
                            // overwrites lo3 after capture - documented
                            // approximation, pair3's low half is rarely
                            // non-zero with 4-GiB-aligned IOVAs (M26: lo=0).
                            mz_vid_base[64*0 +: 64] <= { regs[4], regs[5] };
                            mz_vid_base[64*1 +: 64] <= { regs[6], regs[7] };
                            mz_vid_base[64*2 +: 64] <= { regs[8], regs[9] };
                            mz_vid_base[64*3 +: 64] <= { regs[10], regs[11] };
                            mz_vid_slots <= 3'd4;
                        end
                        MZ_CMD_SET_BUF_AUD,
                        MZ_CMD_SET_BUF_H264,
                        MZ_CMD_SET_BUF_5,
                        MZ_CMD_SET_BUF_8: begin
                            // accepted; no engine attached in v1
                        end
                        MZ_CMD_START_STREAMING: begin
                            mz_arm <= 1'b1;
                        end
                        MZ_CMD_STOP_STREAMING: begin
                            mz_arm <= 1'b0;
                            regs[12][MZ_EVENT_VIDEO] <= 1'b0;
                        end
                        MZ_CMD_SET_VIC: begin
                            // stored via the generic PARAM path above; no
                            // functional effect (emulation is always no-signal)
                        end
                        MZ_CMD_SET_AIC,
                        MZ_CMD_SET_ENC,
                        MZ_CMD_SET_ENC_POST,
                        MZ_CMD_POST_PROC,
                        MZ_CMD_SET_BAR,
                        MZ_CMD_SET_VIDEO_INVIS,
                        MZ_CMD_SET_LOGO: begin
                            // accept + ignore
                        end
                        // ---- peripherals (Task 3): bridge regs / GPIO /
                        // MST3367 I2C / EDID. Periph result byte lands in
                        // PARAM3 (regs[3], reg.h: "read result lands in
                        // PARAM3"). The periph NAKs unpowered accesses and
                        // forces the read result 0 (M13).
                        MZ_CMD_GPIO_READ,
                        MZ_CMD_GPIO_SET,
                        MZ_CMD_GPIO_DIR,
                        MZ_CMD_REG_READ,
                        MZ_CMD_REG_WRITE,
                        MZ_CMD_I2C_READ_S,
                        MZ_CMD_I2C_WRITE_S,
                        MZ_CMD_I2C_COMBO: begin
                            p_rd <= periph_is_rd(regs[1][7:0]);
                            p_wr <= periph_is_wr(regs[1][7:0]);
                        end
                        MZ_CMD_LOAD_FILES: begin
                            // M76: 44-byte command layout - cmd[N] is the Nth
                            // byte of the host command; PARAM(i) occupies
                            // cmd[4+4i .. 4+4i+3] little-endian. So:
                            //   is_write = cmd[5]   = PARAM0[15:8]
                            //   offset   = cmd[6..7] = PARAM0[31:16] (LE u16)
                            //   16 data bytes = cmd[8..23] = PARAM1..PARAM4
                            //                 = regs[2..5]
                            // Read: result 16 bytes go home in PARAM1..PARAM4;
                            // PARAM0 (regs[1]) keeps the control word so the
                            // host reads the 44-byte command back intact.
                            lf_offset   <= regs[1][31:16];
                            lf_wr_fire  <= |regs[1][15:8];
                            if ( !regs[1][15:8] ) begin
                                // read: 16 scratch bytes -> PARAM1..PARAM4
                                { regs[5], regs[4], regs[3], regs[2] } <= lf_read16(regs[1][31:16]);
                            end
                        end
                        default: begin
                            // unknown opcode: stamp OK (ep.ko dispatcher drops
                            // silently; host only reads STATUS)
                        end
                    endcase
                end
                else if ( wr_data == MZ_ACK ) begin
                    regs[12]    <= 32'h0;                       // clear EVENT
                    mz_int_ack  <= 1'b1;                        // pulse
                end
                // any other doorbell value: ignored
            end

            // frame-done writeback from the DMA engine (M17/M40)
            if ( mz_frame_done ) begin
                regs[12][MZ_EVENT_VIDEO] <= 1'b1;
                frame_cnt <= frame_cnt + 4'd1;
                regs[16]  <= { 28'h0, frame_cnt };              // token nibble
                regs[20][0] <= 1'b1;                            // ENC_STATUS[0] = 1:
                                                                // host must write 0 to ack
                token_lo <= ~token_lo;
            end

            // periph read result -> PARAM3 = regs[4] (reg.h: "read result
            // lands in PARAM3"); NAK forces result 0 (M13). The periph
            // registers rdata/nak, so they are valid one cycle after p_rd;
            // p_rd_d fires the capture on that cycle.
            if ( p_rd_d )
                regs[4][7:0] <= p_nak ? 8'h0 : p_rdata;

            // LOAD_FILES write fire: 16 bytes of PARAM1..PARAM4 (regs[2..5])
            // into scratch. lf_wr_fire is the 1-cycle pulse set by the doorbell
            // dispatch; the PARAM/offset values it reads were latched then.
            if ( lf_wr_fire ) begin
                for ( int k = 0; k < 16; k++ ) begin
                    lf_mem[(lf_offset + 16'(k)) & 12'hfff] <=
                        regs[2 + k[3:2]][8*(k % 4) +: 8];
                end
            end
        end
    end

    // mz_frame_token low 3 bits name the completed buffer (M17); we always
    // complete buffer 0. Kept for interface completeness.
    bit [31:0] frame_token_q;
    always @ ( posedge clk ) begin
        if ( rst )
            frame_token_q <= 32'h0;
        else if ( mz_frame_done )
            frame_token_q <= mz_frame_token;
    end

    // ------------------------------------------------------------------
    // periph instance: bridge regs / GPIO / MST3367 / EDID. The PARAM words
    // feeding chip/reg/wdata are selected per command shape (see the
    // periph_* wires above); EDID bulk payload = PARAM4..PARAM7.
    // ------------------------------------------------------------------
    pcileech_mz0380_periph i_periph (
        .rst            ( rst           ),
        .clk            ( clk           ),
        .p_op           ( cmd_opcode    ),
        .p_chip         ( periph_chip   ),
        .p_reg          ( periph_reg    ),
        .p_wdata        ( periph_wdata  ),
        .p_rd_en        ( p_rd          ),
        .p_wr_en        ( p_wr          ),
        .p_bulk_data    ( periph_bulk   ),
        .p_bulk_len     ( 8'd16         ),
        .rdata          ( p_rdata       ),
        .nak            ( p_nak         )
    );

    // ------------------------------------------------------------------
    // read path: 2-cycle pipeline (shape of pcileech_bar_impl_zerowrite4k)
    // ------------------------------------------------------------------
    bit [87:0]  rd_req_ctx_1;
    bit [31:0]  rd_req_addr_1;
    bit         rd_req_valid_1;
    bit [31:0]  rd_word;

    always @ ( posedge clk ) begin
        if ( rst ) begin
            rd_req_ctx_1    <= 88'h0;
            rd_req_addr_1   <= 32'h0;
            rd_req_valid_1  <= 1'b0;
        end
        else begin
            rd_req_ctx_1    <= rd_req_ctx;
            rd_req_addr_1   <= rd_req_addr;
            rd_req_valid_1  <= rd_req_valid;
            rd_word         <= (rd_req_addr_1[11:2] < 128) ?
                                regs[rd_req_addr_1[8:2]] : 32'h0;
        end
    end

    always @ ( posedge clk ) begin
        rd_rsp_ctx      <= rd_req_ctx_1;
        rd_rsp_data     <= rd_word;
        rd_rsp_valid    <= rd_req_valid_1;
    end

endmodule
