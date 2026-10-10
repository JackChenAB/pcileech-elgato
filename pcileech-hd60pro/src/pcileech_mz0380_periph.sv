//
// PCILeech FPGA - MZ0380 mailbox peripherals.
//
// Models what the real card's Mozart SoC serves behind the mailbox I2C/REG
// opcodes, per Wolffyx hd60pro-linux-driver RE (reg.h Section A, RE_FINDINGS
// M13/M15/M44/M67/M76). Spec: HD60PRO_DESIGN.md section 3.
//
//   - bridge register file (chip 0x90, ops 0x1a/0x1b)
//   - GPIO shadow (ops 0x14/0x15/0x17)
//   - MST3367 HDMI receiver model (I2C 8-bit 0x9c), power-gated by GPIO pin9
//   - EDID RAM (I2C 8-bit 0xa0) + bulk write state machine (op 0x1f)
//
// One command fires per mailbox doorbell; everything completes in 1 cycle
// except EDID bulk chunks, which the caller drives over consecutive fires.
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_mz0380_periph (
    input               rst,
    input               clk,
    // decoded command from the mailbox FSM (one fire = one op)
    input [7:0]         p_op,        // mailbox opcode (0x14..0x20, 0x6e handled by caller)
    input [7:0]         p_chip,      // PARAM1: chip / I2C device (8-bit)
    input [7:0]         p_reg,       // PARAM2: register / bank select / eeprom offset
    input [7:0]         p_wdata,     // PARAM3: value (writes) / sub-offset
    input               p_rd_en,     // 1-cycle: do a read for this op
    input               p_wr_en,     // 1-cycle: do a write for this op
    // EDID bulk write (op 0x1f) payload, driven by the mailbox FSM from PARAMs
    input [127:0]       p_bulk_data, // 16 payload bytes, LSB-first
    input [7:0]         p_bulk_len,  // bytes valid in p_bulk_data (<=16)
    // results
    output bit [7:0]    rdata,       // read result byte (caller puts in PARAM3)
    output bit          nak          // 1 = I2C NAK (read result forced 0, M13)
);

    // ------------------------------------------------------------------
    // GPIO shadow (M14/M15): 16 bits. Reset 0x0000 - pin9 low keeps the
    // MST3367 in reset until the host driver raises it.
    // ------------------------------------------------------------------
    bit [15:0] gpio_shadow;

    wire gpio_pin9_level = gpio_shadow[9];          // 1 = MST3367 out of reset
    wire mst_powered     = gpio_pin9_level;

    // ------------------------------------------------------------------
    // bridge register file (chip 0x90): 8 x 8-bit
    //   0x10 IRQ main    read-to-clear (nothing sets it in v1)
    //   0x12 SIGNAL      bit0 = 0 (no input signal - constant, this build)
    //   0x13..0x15       per-source IRQ, read-to-clear
    //   0x18/0x19        RW storage
    // ------------------------------------------------------------------
    bit [7:0] bridge [0:7];        // indexed by reg[2:0]

    // ------------------------------------------------------------------
    // MST3367: 4 banks x 256 bytes (M44: "256-byte register shadow per
    // bank"; bank 3 = never-loaded shape, reads 0 apart from bank echo)
    // ------------------------------------------------------------------
    bit [7:0] mst [0:3][0:255];
    bit [1:0] mst_bank;            // last bank written via reg 0x00

    // ------------------------------------------------------------------
    // EDID RAM: 256 bytes, $readmemh from the Wolffyx dump
    // ------------------------------------------------------------------
    bit [7:0] edid [0:255];
    initial begin
        $readmemh("mz0380_edid.mem", edid);
    end
    bit [8:0] edid_wr_ptr;         // running eeprom offset for bulk writes

    // ------------------------------------------------------------------
    // init: live MST3367 no-signal constants (M67 no-signal class)
    // ------------------------------------------------------------------
    initial begin
        integer i;
        for (i = 0; i < 8; i = i + 1) bridge[i] = 8'h00;
        for (i = 0; i < 4; i = i + 1)
            for (integer j = 0; j < 256; j = j + 1)
                mst[i][j] = 8'h00;
        // bank 0 live constants
        mst[0][8'h55] = 8'h03;      // DETECT: no signal (M67: 0x03 class)
        mst[0][8'hb7] = 8'h00;      // HPD/link (parked; host raises via EDID+HPD flow)
        mst[0][8'h57] = 8'h02;      // torn timing counters (M67)
        mst[0][8'h58] = 8'h90;
        mst[0][8'h59] = 8'h01;
        mst[0][8'h5a] = 8'hE0;
        mst[0][8'h5b] = 8'h00;
        mst[0][8'h5c] = 8'h05;
        mst[0][8'h6a] = 8'h02;
        mst[0][8'h6b] = 8'h90;
        mst[0][8'h5f] = 8'h03;      // interlace flags
        mst[0][8'he2] = 8'h00;      // auto position off
        // bank 2 active pixel counters read 0 (no signal)
        mst[2][8'h28] = 8'h00;
        mst[2][8'h29] = 8'h00;
    end

    // ------------------------------------------------------------------
    // command decode + execute (1-cycle)
    // ------------------------------------------------------------------
    wire is_bridge     = (p_chip == 8'h90);
    wire is_mst        = (p_chip == 8'h9c);
    wire is_edid       = (p_chip == 8'ha0);

    // bulk write: op 0x1f (or 0x20 combo treated as 0x1f, documented)
    wire is_bulk_wr    = ((p_op == 8'h1f) || (p_op == 8'h20)) && p_wr_en && is_edid;

    // GPIO ops
    wire is_gpio_rd    = (p_op == 8'h14) && p_rd_en;
    wire is_gpio_wr    = (p_op == 8'h15) && p_wr_en;
    // REG ops (bridge)
    wire is_reg_rd     = (p_op == 8'h1a) && p_rd_en && is_bridge;
    wire is_reg_wr     = (p_op == 8'h1b) && p_wr_en && is_bridge;
    // generic I2C ops (MST3367 or EDID byte access). The stack reaches the
    // receiver through either the generic REG read (0x1a) or the dedicated
    // I2C single read (0x1e); accept both (reg.h / DESIGN.md disagree on which).
    wire is_i2c_rd     = ((p_op == 8'h1a) || (p_op == 8'h1e)) && p_rd_en && (is_mst || is_edid);
    wire is_i2c_wr     = (p_op == 8'h1b) && p_wr_en && (is_mst || is_edid);

    always @ ( posedge clk ) begin
        if ( rst ) begin
            rdata        <= 8'h00;
            nak          <= 1'b0;
            gpio_shadow  <= 16'h0000;
            edid_wr_ptr  <= 9'h0;
            mst_bank     <= 2'd0;              // default bank 0 until host selects
        end
        else begin
            rdata <= 8'h00;
            nak   <= 1'b0;

            // ---- GPIO read: full shadow (documented approximation of the
            //      Windows masked read; the driver ORs the result with its
            //      own mask anyway) ----
            if ( is_gpio_rd ) begin
                rdata <= gpio_shadow[7:0];
            end

            // ---- GPIO set: PARAM1=mask, PARAM2=data ----
            if ( is_gpio_wr ) begin
                gpio_shadow <= (gpio_shadow & ~{8'h00, p_reg}) | ({8'h00, p_wdata} & {8'h00, p_reg});
            end
            // op 0x17 (direction): pins are pre-configured outputs; no-op

            // ---- bridge register read/write ----
            if ( is_reg_rd ) begin
                rdata <= bridge[p_reg[2:0]];
                if ( p_reg == 8'h10 || p_reg == 8'h13 || p_reg == 8'h14 || p_reg == 8'h15 )
                    bridge[p_reg[2:0]] <= 8'h00;    // read-to-clear
            end
            if ( is_reg_wr ) begin
                bridge[p_reg[2:0]] <= p_wdata;
            end

            // ---- I2C: MST3367 / EDID, power-gated by GPIO pin9 (M13:
            //      fw forces result 0x00 on NAK) ----
            if ( is_i2c_rd || is_i2c_wr || is_bulk_wr ) begin
                if ( !mst_powered ) begin
                    nak   <= 1'b1;
                    rdata <= 8'h00;
                end
                else begin
                    nak <= 1'b0;
                    if ( is_bulk_wr ) begin
                        // bulk EDID write: p_reg = eeprom offset base,
                        // p_bulk_data = bytes, LSB-first, p_bulk_len valid
                        for ( integer k = 0; k < 16; k = k + 1 ) begin
                            if ( k < $unsigned(p_bulk_len) )
                                edid[p_reg + k[7:0]] <= p_bulk_data[8*k +: 8];
                        end
                        edid_wr_ptr <= p_reg + p_bulk_len;
                    end
                    else if ( is_i2c_wr ) begin
                        if ( is_edid ) begin
                            edid[p_reg] <= p_wdata;
                        end
                        else begin
                            // MST3367: reg 0x00 = bank select (echoed), else RW.
                            // Index with the full 8-bit register offset: banks
                            // are 256 bytes and the live constants sit above
                            // 0x3f (0x55, 0x57.., 0x6a.., 0xe2).
                            if ( p_reg == 8'h00 )
                                mst_bank <= p_wdata[1:0];
                            else
                                mst[mst_bank][p_reg] <= p_wdata;
                        end
                    end
                    else begin // I2C read
                        if ( is_edid )
                            rdata <= edid[p_reg];
                        else
                            rdata <= mst[mst_bank][p_reg];
                    end
                end
            end
        end
    end

endmodule
