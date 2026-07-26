`timescale 1ns / 1ps
`include "eth_frame_pkg.sv"

module decoder_iso_tb;

    import eth_frame_pkg::*;

    localparam DATA_W = 64;

    logic                      clk;
    logic                      rst_n;
    logic                      i_valid;
    logic [DATA_W + 1 : 0]     i_data;
    logic                      o_valid;
    logic [DATA_W - 1 : 0]     o_data;
    logic [DATA_W/8 - 1 : 0]   o_ctrl;
    logic [DATA_W/8 - 1 : 0]   o_keep;
    logic                      o_start;
    logic                      o_idle;
    logic                      o_terminate;
    logic                      o_error;

    decoder #(.DATA_W(DATA_W)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_valid     (i_valid),
        .i_data      (i_data),
        .o_valid     (o_valid),
        .o_data      (o_data),
        .o_ctrl      (o_ctrl),
        .o_keep      (o_keep),
        .o_start     (o_start),
        .o_idle      (o_idle),
        .o_terminate (o_terminate),
        .o_error     (o_error)
    );

    // 156.25 MHz
    initial clk = 0;
    always #3.2 clk = ~clk;

    int pass_count, fail_count;

    task automatic do_reset();
        rst_n   = 0;
        i_valid = 0;
        i_data  = '0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1;
    endtask

    // helper: build a 66-bit block in the format the decoder expects
    //   i_data = {payload[63:0], sync_header[1:0]}
    function automatic logic [DATA_W + 1 : 0] make_block(
        input logic [1:0]  sync,
        input logic [63:0] payload
    );
        return {payload, sync};
    endfunction

    // --------------------------------------------------------------------------
    // isolated test: you're simulating the descrambler upstream (driving 66-bit blocks)
    // and simulating the MAC downstream (checking XGMII output).
    //
    // the decoder is purely combinational. output should reflect input same-cycle.
    //
    // you're constructing raw 66-bit blocks by hand; so you need to know
    // the bit layout for each block type from IEEE clause 49 figure 49-7. the block type
    // field sits at i_data[9:2], and the rest of the payload is arranged per type.
    //
    // *: this is where you catch encoding bugs that the encoder might be hiding.
    //    by feeding known bit patterns directly, you isolate decoder behavior from
    //    any encoder issues.
    // --------------------------------------------------------------------------
    task automatic check_output(input string name, input logic exp_valid, input logic [DATA_W - 1 : 0] exp_data, 
                                input logic [7:0] exp_ctrl, input logic [7:0] exp_keep, input logic exp_start, 
                                input logic exp_idle, input logic exp_terminate, input logic exp_error); 
        begin
            #1; // wait for combinational logic to settle
            if (o_valid !== exp_valid || o_data !== exp_data || o_ctrl !== exp_ctrl || o_keep !== exp_keep || 
                o_start !== exp_start || o_idle !== exp_idle || o_terminate !== exp_terminate || o_error !== exp_error) begin
                $display("FAIL: %s", name); 
                $display("  Expected: valid=%b, data=%h, ctrl=%h, keep=%h, start=%b, idle=%b, terminate=%b, error=%b",
                        exp_valid, exp_data, exp_ctrl, exp_keep, exp_start, exp_idle, exp_terminate, exp_error);
                $display("  Observed: valid=%b, data=%h, ctrl=%h, keep=%h, start=%b, idle=%b, terminate=%b, error=%b",
                        o_valid, o_data, o_ctrl, o_keep, o_start, o_idle, o_terminate, o_error);
                fail_count++; 
            end 
            else begin
                $display("PASS: %s", name); 
                pass_count++; 
            end
        end
    endtask 

    initial begin
        $display("==============================================");
        $display("  decoder isolated testbench");
        $display("==============================================");
        pass_count = 0;
        fail_count = 0;

        do_reset();

        // test 1: data block
        //   sync = 01, payload = 8 known bytes. verify o_data matches payload,
        //   o_ctrl = 8'h00, o_keep = 8'hFF, no flags set, no error.
        i_valid = 1'b1;
        i_data = make_block(2'b01, 64'h0102030405060708);
        check_output(.name ("TEST 1: Data Block"),
                     .exp_valid (1'b1), .exp_data (64'h0102030405060708),
                     .exp_ctrl (8'h00), .exp_keep (8'hFF), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b0));

        // test 2: idle block
        //   sync = 10, block type = 0x1E, all control codes = 7'h00 (idle).
        //   verify o_data = 64'h0707070707070707, o_ctrl = 8'hFF, o_idle = 1.
        i_valid = 1'b1;
        i_data = make_block(2'b10, 64'h000000000000001E);
        check_output(.name ("TEST 2: Idle Block"),
                     .exp_valid (1'b1), .exp_data (64'h0707070707070707),
                     .exp_ctrl (8'hFF), .exp_keep (8'hFF), .exp_start (1'b0),
                     .exp_idle (1'b1), .exp_terminate (1'b0), .exp_error (1'b0));

        // test 3: start block (type 0x78)
        //   sync = 10, block type = 0x78, 7 data bytes in the payload.
        //   verify o_data[7:0] = 0xFB (start char), o_data[63:8] = your 7 bytes,
        //   o_ctrl = 8'h01, o_start = 1.
        i_valid = 1'b1;
        i_data = make_block(2'b10, 64'h7766554433221178);
        check_output(.name ("TEST 3: Start Block"),
                     .exp_valid (1'b1), .exp_data (64'h77665544332211FB),
                     .exp_ctrl (8'h01), .exp_keep (8'hFF), .exp_start (1'b1),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b0));

        // test 4: all terminate types
        //   for each TERM_0 through TERM_7: construct the block manually.
        //   verify: correct o_data (data bytes + 0xFD at the right position + idle padding),
        //   correct o_ctrl, correct o_keep, o_terminate = 1.
        //   *: pay close attention to o_keep. TERM_0 should have o_keep = 8'h00,
        //      TERM_7 should have o_keep = 8'h7F. if yours include the terminate
        //      byte in the keep mask, that's a bug.
        i_valid = 1'b1; 

        
        // 4a: TERM_0 (0x87) - 0 data, 7 idles
        i_data  = make_block(2'b10, 64'h0000000000000087);
        check_output(.name ("TEST 4a: TERM_0 (0x87)"),
                     .exp_valid (1'b1), .exp_data (64'h07070707070707FD),
                     .exp_ctrl (8'hFF), .exp_keep (8'h00), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));

        // 4b: TERM_1 (0x99) - 1 data, 6 idles
        i_data  = make_block(2'b10, 64'h0000000000001199);
        check_output(.name ("TEST 4b: TERM_1 (0x99)"),
                     .exp_valid (1'b1), .exp_data (64'h070707070707FD11),
                     .exp_ctrl (8'hFE), .exp_keep (8'h01), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));

        // 4c: TERM_2 (0xAA) - 2 data, 5 idles
        i_data  = make_block(2'b10, 64'h00000000002211AA);
        check_output(.name ("TEST 4c: TERM_2 (0xAA)"),
                     .exp_valid (1'b1), .exp_data (64'h0707070707FD2211),
                     .exp_ctrl (8'hFC), .exp_keep (8'h03), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));

        // 4d: TERM_3 (0xB4) - 3 data, 4 idles
        i_data  = make_block(2'b10, 64'h00000000332211B4);
        check_output(.name ("TEST 4d: TERM_3 (0xB4)"),
                     .exp_valid (1'b1), .exp_data (64'h07070707FD332211),
                     .exp_ctrl (8'hF8), .exp_keep (8'h07), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));

        // 4e: TERM_4 (0xCC) - 4 data, 3 idles
        i_data  = make_block(2'b10, 64'h00000044332211CC);
        check_output(.name ("TEST 4e: TERM_4 (0xCC)"),
                     .exp_valid (1'b1), .exp_data (64'h070707FD44332211),
                     .exp_ctrl (8'hF0), .exp_keep (8'h0F), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));

        // 4f: TERM_5 (0xD2) - 5 data, 2 idles
        i_data  = make_block(2'b10, 64'h00005544332211D2);
        check_output(.name ("TEST 4f: TERM_5 (0xD2)"),
                     .exp_valid (1'b1), .exp_data (64'h0707FD5544332211),
                     .exp_ctrl (8'hE0), .exp_keep (8'h1F), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));

        // 4g: TERM_6 (0xE1) - 6 data, 1 idle
        i_data  = make_block(2'b10, 64'h00665544332211E1);
        check_output(.name ("TEST 4g: TERM_6 (0xE1)"),
                     .exp_valid (1'b1), .exp_data (64'h07FD665544332211),
                     .exp_ctrl (8'hC0), .exp_keep (8'h3F), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));

        // 4h: TERM_7 (0xFF) - 7 data, 0 idles
        i_data  = make_block(2'b10, 64'h77665544332211FF);
        check_output(.name ("TEST 4h: TERM_7 (0xFF)"),
                     .exp_valid (1'b1), .exp_data (64'hFD77665544332211),
                     .exp_ctrl (8'h80), .exp_keep (8'h7F), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b1), .exp_error (1'b0));
        
        // test 5: invalid sync header
        //   sync = 00 and sync = 11.
        //   verify o_error =1 for both.
        i_valid = 1'b1;

        // 5a: sync = 00
        i_data  = make_block(2'b00, 64'h0000000000000000);
        check_output(.name ("TEST 5a: Invalid Sync Header (00)"),
                     .exp_valid (1'b1), .exp_data (64'h0),
                     .exp_ctrl (8'h00), .exp_keep (8'h00), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b1));

        // 5b: sync = 11
        i_data  = make_block(2'b11, 64'h0000000000000000);
        check_output(.name ("TEST 5b: Invalid Sync Header (11)"),
                     .exp_valid (1'b1), .exp_data (64'h0),
                     .exp_ctrl (8'h00), .exp_keep (8'h00), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b1));

        // test 6: unrecognized block type
        //   sync = 10, block type = something not in the table (e.g. 0xAB).
        //   verify o_error =1.
        i_valid = 1'b1;

        i_data = make_block(2'b10, 64'h00000000000000AB);
        check_output(.name ("TEST 6: Unrecognized Block Type (0xAB)"),
                     .exp_valid (1'b1), .exp_data (64'h0),
                     .exp_ctrl (8'hFF), .exp_keep (8'h00), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b1));

        // test 7: bad control code in a valid block type
        //   sync = 10, block type = 0x1E (all control), but put an invalid 7-bit
        //   code in one of the control slots (e.g. 7'h7F).
        //   verify o_error =1 because decode_control_code returns 0xFE.
        i_valid = 1'b1;

        i_data = make_block(2'b10, 64'h0000000000007F1E);
        check_output(.name ("TEST 7: Bad Control Code (C0 = 7'h7F)"),
                     .exp_valid (1'b1), .exp_data (64'h07070707070707FE),
                     .exp_ctrl (8'hFF), .exp_keep (8'hFF), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b1));

        // test 8: ordered set blocks
        //   types 0x2D, 0x4B, 0x55, 0x66.
        //   construct with valid O-codes (4'h0 = Q, 4'hF = Fsig).
        //   verify correct o_data placement and o_ctrl flags.
        //   *: also test with an invalid O-code (e.g. 4'h5) —> should trigger o_error.

        // 8a: BLOCK_TYPE_OS_4 (0x2D) - "C0 C1 C2 C3 / O4 D5 D6 D7"
        //   C0..C3 = idle (7'h00) -> 0x07 each
        //   O4 = 4'h0 (Q)         -> 0x9C
        //   D5,D6,D7 = 0xAA,0xBB,0xCC (raw pass-through bytes)
        i_valid = 1'b1;

        i_data = make_block(2'b10, 64'hCCBBAA000000002D);
        check_output(.name ("TEST 8a: Ordered Set OS_4 (0x2D), valid O-code"),
                     .exp_valid (1'b1), .exp_data (64'hCCBBAA9C07070707),
                     .exp_ctrl (8'h1F), .exp_keep (8'hFF), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b0));

        // 8b: BLOCK_TYPE_OS_0 (0x4B) - "O0 D1 D2 D3 / C4 C5 C6 C7"
        //   O0 = 4'h0 (Q) -> 0x9C
        //   D1,D2,D3 = 0x11,0x22,0x33 (raw)
        //   C4..C7 = idle (7'h00) -> 0x07 each
        i_data = make_block(2'b10, 64'h000000003322114B);
        check_output(.name ("TEST 8b: Ordered Set OS_0 (0x4B), valid O-code"),
                     .exp_valid (1'b1), .exp_data (64'h070707073322119C),
                     .exp_ctrl (8'hF1), .exp_keep (8'hFF), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b0));

        // 8c: BLOCK_TYPE_OS_04 (0x55) - "O0 D1 D2 D3 / O4 D5 D6 D7"
        //   O0 = 4'h0 (Q) -> 0x9C, O4 = 4'hF (Fsig) -> 0x5C
        //   D1,D2,D3 = 0x11,0x22,0x33 ; D5,D6,D7 = 0x55,0x66,0x77
        i_data = make_block(2'b10, 64'h776655F033221155);
        check_output(.name ("TEST 8c: Ordered Set OS_04 (0x55), valid O-codes"),
                     .exp_valid (1'b1), .exp_data (64'h7766555C3322119C),
                     .exp_ctrl (8'h11), .exp_keep (8'hFF), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b0));

        // 8d: BLOCK_TYPE_OS_START (0x66) - "O0 D1 D2 D3 / S4 D5 D6 D7"
        //   O0 = 4'h0 (Q) -> 0x9C ; S4 is fixed to 0xFB regardless of payload
        //   D1,D2,D3 = 0x11,0x22,0x33 ; D5,D6,D7 = 0x55,0x66,0x77
        i_data = make_block(2'b10, 64'h7766550033221166);
        check_output(.name ("TEST 8d: Ordered Set OS_START (0x66), valid O-code"),
                     .exp_valid (1'b1), .exp_data (64'h776655FB3322119C),
                     .exp_ctrl (8'h11), .exp_keep (8'hFF), .exp_start (1'b1),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b0));

        // 8e: invalid O-code (4'h5) inside OS_04 (0x55)
        //   O0 = 4'h5 (not 0 or F) -> decode_o_code returns 8'hFE (error)
        //   O4 = 4'h0 (Q, valid) -> 0x9C ; D1,D2,D3,D5,D6,D7 = 0
        i_data = make_block(2'b10, 64'h0000000500000055);
        check_output(.name ("TEST 8e: Ordered Set OS_04, invalid O-code (4'h5)"),
                     .exp_valid (1'b1), .exp_data (64'h0000009C000000FE),
                     .exp_ctrl (8'h11), .exp_keep (8'hFF), .exp_start (1'b0),
                     .exp_idle (1'b0), .exp_terminate (1'b0), .exp_error (1'b1));

        $display("\n==============================================");
        $display("  Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("==============================================");
        $finish;
    end

endmodule