//============================================================================
//  crt_adjust.sv  —  "CRT Adjust"
//
//  Core-side analog CRT geometry module for MiSTer FPGA arcade cores.
//  Author: rmonic79 (with help from Andrea Bogazzi / @asturur).
//
//  This is the evolution of the earlier core-side "Analog H-Size" module:
//  the same content-shift line-buffer idea, now grown into a full CRT
//  alignment tool exposed in the OSD as "CRT Adjust". One always-on line
//  buffer provides THREE controls:
//
//      - H-Size     : horizontal stretch / squeeze (bidirectional, integer)
//      - H-Position : horizontal slide — two mechanisms, see HPOS_MODE below
//      - V-Shift    : vertical line shift
//
//  ─── Why it never desyncs the CRT ──────────────────────────────────────────
//  The picture CONTENT is shifted/resized through the line buffer while the
//  horizontal/vertical SYNC signals stay NATIVE. The CRT keeps its lock at
//  all times, so you can slide and resize the image live without the screen
//  rolling or losing hold — unlike moving the blanking/sync windows.
//
//  Every source pixel is emitted for an integer-uniform number of pixel-clock
//  periods (no fractional ratio, no per-pixel nearest-neighbor), so there is:
//      - NO shimmering on moving content
//      - NO blending / blur (output = source pixel, byte-exact)
//      - NO line buffer mismatch (1-line ping-pong, deterministic phase)
//
//  CORE-SIDE variant: instantiate this inside the core's emu wrapper (your
//  top-level .sv) at the video-output boundary, with zero sys_top.v changes
//  (MiSTer-devel compliant — the sys/ framework is never modified). The
//  trade-off: the adjust reaches the analog DAC AND HDMI follows it too.
//  Leave CRT Adjust Off for an untouched HDMI image. For the sys-side variant
//  (HDMI stays bit-identical, but you must edit sys_top.v) use crt_adjust_sys.sv.
//  See README.md and examples/ for the exact glue.
//
//  ─── Resource cost ─────────────────────────────────────────────────────────
//  ~1 M10K (24-bit linebuffer with ping-pong banks), ~50 ALM, 0 DSP.
//
//  ─── Required external signals ─────────────────────────────────────────────
//  pxl_cen   : the core's pixel clock enable (write rate, e.g. 6 MHz pulse
//              on a 96 MHz clk).
//  pxl2_cen  : the DAC read clock enable, generated externally as
//              (base + hsize) quarter-cycles of clk. IMPORTANT: reset its
//              generator on the RISE of `hs_ref_out` (NOT on the raw HSync), so
//              the read rate and the module's internal read counter restart on
//              the same edge in BOTH HPOS modes. See core_side_snippet.v.
//  active    : ON/OFF. 0 = pure bypass (native passthrough). 1 = module live,
//              so H-Size / H-Position / V-Shift work even at value 0.
//  hsize     : signed 5-bit, OSD-controlled size factor (bidirectional).
//              Convention here: read period = base + hsize, so
//              hsize = 0 → no scaling (H-Position / V-Shift still apply if On)
//              hsize > 0 → slower read → WIDER pixels (enlarge)
//              hsize < 0 → faster read → NARROWER pixels (shrink)
//  hoffset   : signed 9-bit, H-Position — mechanism selected by HPOS_MODE.
//  voffset   : signed 6-bit, V-Shift — shifts VSync by N lines.
//
//  ─── License ───────────────────────────────────────────────────────────────
//  Author: Umberto Parisi (rmonic79), 2026.
//  Distributed under GNU GPL v3 or later.
//
//  ─── Tank adaptation (2026-10-08) ──────────────────────────────────────────
//  Upstream: github.com/rmonic79/MiSTer-CRT-Adjust rtl/crt_adjust.sv @ c682de9.
//  Changes, all needed for Tank's 904-pixel line / 521-line interlaced frame:
//    - AW is a parameter (upstream fixed it at 10 = 512 samples per bank,
//      too short for a 904-pixel line; Tank instantiates AW = 11).
//    - hshift_tap / vshift_tap are sized from HTOTAL / VTOTAL (upstream's
//      10-bit / 9-bit signed taps overflow at HTOTAL 904 / VTOTAL 521).
//    - fl_in / fl_out: the interlace field flag (VGA_F1) rides the V-Shift
//      line shift register with VSync, so the HDMI scaler still sees the
//      right field parity at each shifted VSync.  VTOTAL must then be the
//      FRAME length in lines (521 for Tank: two fields of 260.5 lines), so a
//      negative shift (delay of VTOTAL - |N| lines) lands on a field of the
//      same parity.
//    - V-Shift samples VSync at mid-line too, so the half-line VSync edge
//      of Tank's second field is kept (see there).
//    - hoff_s sign fix (negative H-Position in CONTENTSHIFT; see there).
//    - DE/RGB blanked while the output HSync is high (content pushed past
//      the line end no longer leaks a pixel past the HSync rise).
//  Everything else is upstream's logic, unchanged.
//============================================================================

// ----------------------------------------------------------------------------
//  HPOS_MODE — how the H-Position control moves the image horizontally.
//
//  Both generations of H-Position live in this one file, driven by the same OSD
//  value (`hoffset`); the parameter picks which one is built. Neither desyncs
//  the CRT — but they fail differently at the extremes, so the right choice
//  depends on the GAME's geometry.
//
//    HPOS_CONTENTSHIFT (1) — the newer mechanism.
//        Shifts the CONTENT inside the line buffer; HSync out stays byte-for-byte
//        native. The whole engine (write + read) keeps restarting on the native
//        HSync, so it stays rock-solid even while H-Size SHRINKS the image.
//        Downside: on a NARROW game whose active area is anchored to one side of
//        the line (large asymmetric blanking), pushing the content toward the
//        short-margin side runs it out of the buffer window and a black block
//        appears at the screen edge.
//        USE FOR: wide / centered games (e.g. 320px active on a 384px line).
//
//    HPOS_SYNCSHIFT (0) — the original upstream mechanism, kept.
//        Shifts the HSYNC out by N pixels through a line-length shift register;
//        the content stays anchored natively. The picture slides on the CRT with
//        no buffer window to fall out of -> no black block on narrow anchored
//        games. In this mode the ENTIRE engine (write side, read counter) and the
//        external read-rate generator all restart on the SHIFTED HSync, exposed
//        as `hs_ref_out`. That shared reference is what keeps everything in phase;
//        it is also why the glue must reset pxl2_cen on `hs_ref_out` and not on
//        the raw HSync (doing the latter is what desynced the old upstream
//        scheme when shrinking).
//        USE FOR: narrow / side-anchored games (e.g. 256px active with a wide
//        asymmetric H back-porch).
// ----------------------------------------------------------------------------
// Guarded so that including both crt_adjust.sv and crt_adjust_sys.sv in the
// same project does not raise a macro-redefinition warning.
`ifndef HPOS_SYNCSHIFT
`define HPOS_SYNCSHIFT    0
`define HPOS_CONTENTSHIFT 1
`endif

module crt_adjust #(
    parameter VTOTAL   = 263,
    parameter HTOTAL   = 384,               // line length in pixels (for the HSync shreg)
    parameter HPOS_MODE = `HPOS_CONTENTSHIFT, // see HPOS_MODE block above
    parameter AW       = 10                 // line buffer: 2^(AW-1) samples per bank
)
(
    input              clk,
    input              pxl_cen,      // write clock enable (core pixel rate)
    input              pxl2_cen,     // read clock enable  (DAC pixel rate, slower)

    input              active,       // ON/OFF: 0 = bypass puro (nativo), 1 = modulo
                                     // attivo (H-Size / H-Pos / V-Shift funzionano
                                     // anche se i loro valori sono 0).

    input  signed [4:0] hsize,       // 0 = nessuna scala, !=0 = enlarge/shrink
    input  signed [8:0] hoffset,     // H-Position value from the OSD.
                                     // HPOS_CONTENTSHIFT: shifts the CONTENT in the
                                     //   line buffer (>0 right, <0 left), sync native.
                                     // HPOS_SYNCSHIFT: delays HSync by N pixels, content
                                     //   stays native (>0 right, <0 left). See HPOS_MODE.
    input  signed [5:0] voffset,     // V-Shift: sposta il VSync di N righe (signed).
                                     // >0 = giu`, <0 = su. Verticale non desincronizza.

    input        [7:0] r_in,
    input        [7:0] g_in,
    input        [7:0] b_in,
    input              hs_in,
    input              vs_in,
    input              hb_in,
    input              vb_in,

    output reg   [7:0] r_out,
    output reg   [7:0] g_out,
    output reg   [7:0] b_out,
    output reg         hs_out,
    output reg         vs_out,
    output reg         hb_out,
    output reg         vb_out,
    // Shifted HSync reference (HPOS_SYNCSHIFT): the glue must reset its read-rate
    // generator (pxl2_cen) on the RISE of this signal so the read-rate and the
    // module's read counter restart on the same edge (like the upstream scheme).
    // In HPOS_CONTENTSHIFT it equals the native HSync.
    output wire        hs_ref_out,

    // Interlace field flag: delayed through the V-Shift line shift register
    // exactly like VSync (Tank adaptation).  Bypass: registered @ pxl_cen.
    input              fl_in,
    output reg         fl_out
);

    // Tap widths (Tank adaptation): one bit more than the total needs, signed.
    localparam integer HTW = $clog2(HTOTAL) + 1;
    localparam integer VTW = $clog2(VTOTAL) + 1;

    // ------------------------------------------------------------------
    //  Input pipeline @ pxl_cen (for latency matching in bypass mode)
    // ------------------------------------------------------------------
    reg [7:0] r_in_q, g_in_q, b_in_q;
    reg       hs_in_q, hb_in_q, vs_in_q, vb_in_q;
    reg       hs_in_d;
    reg       fl_in_q;
    initial begin
        r_in_q = 0; g_in_q = 0; b_in_q = 0;
        hs_in_q = 0; hb_in_q = 1; vs_in_q = 0; vb_in_q = 0;
        hs_in_d = 0; fl_in_q = 0;
    end

    always @(posedge clk) if (pxl_cen) begin
        r_in_q   <= r_in;
        g_in_q   <= g_in;
        b_in_q   <= b_in;
        hs_in_q  <= hs_in;
        hb_in_q  <= hb_in;
        vs_in_q  <= vs_in;
        vb_in_q  <= vb_in;
        hs_in_d  <= hs_in;
        fl_in_q  <= fl_in;
    end

    // Native HSync rise (used only for the shift register that produces the
    // shifted reference below).
    wire hs_rise_native = pxl_cen && (hs_in & ~hs_in_d);

    // ------------------------------------------------------------------
    //  H-Shift shift register (HPOS_SYNCSHIFT). Delays HSync by N pixels
    //  (hoffset signed). Declared BEFORE the read side because in
    //  HPOS_SYNCSHIFT the read counter (rdcnt) resets on this SHIFTED HSync,
    //  exactly like the reference upstream scheme (analog_hsize + h-shift):
    //  there the read divisor and the read counter both restart on the shifted
    //  HSync, so the enlarged content stays aligned with the read window and
    //  never runs off into the right-edge black. Clocked @ pxl_cen (native px).
    //  hoffset >0 = right (delay HSync), <0 = left (advance = HTOTAL-|N| tap).
    // ------------------------------------------------------------------
    // (Tank adaptation: tap sized HTW bits; upstream's 10-bit signed tap
    //  overflowed for HTOTAL > 511.)
    localparam [HTW-1:0] HTOT_W = HTOTAL;
    wire [HTW-1:0] hshift_tap = hoffset[8]
        ? (HTOT_W + {{(HTW-9){hoffset[8]}}, hoffset})  // negativo -> HTOTAL - |N|
        : {{(HTW-9){1'b0}}, hoffset};                  // positivo -> N
    reg [HTOTAL-1:0] hsync_pix_shreg;
    initial hsync_pix_shreg = 0;
    always @(posedge clk) if (pxl_cen)
        hsync_pix_shreg <= {hsync_pix_shreg[HTOTAL-2:0], hs_in};
    reg hs_shifted;
    initial hs_shifted = 0;
    always @(posedge clk) if (pxl_cen)
        hs_shifted <= (hshift_tap == 0) ? hs_in : hsync_pix_shreg[hshift_tap - 1'd1];

    // HSync reference for the WHOLE line-buffer engine: the shifted HSync in
    // HPOS_SYNCSHIFT, the native HSync otherwise. Like the reference upstream
    // scheme (analog_hsize fed the already-shifted HSync), BOTH the write side
    // (wrp/bank/hb0/hb1 capture) and the read side restart on this same edge, so
    // write and read stay on the same bank/phase and the enlarged content is not
    // disaligned at the right edge.
    wire hs_read_ref = (HPOS_MODE == `HPOS_SYNCSHIFT) ? hs_shifted : hs_in;
    assign hs_ref_out = hs_read_ref;   // exposed so the glue aligns pxl2_cen to it
    reg  hs_ref_d1;
    initial hs_ref_d1 = 0;
    always @(posedge clk) if (pxl_cen) hs_ref_d1 <= hs_read_ref;
    wire hs_rise_in = pxl_cen && (hs_read_ref & ~hs_ref_d1);

    // ------------------------------------------------------------------
    //  Linebuffer ping-pong (24-bit RGB, single M10K, two banks).
    //  Written @ pxl_cen by the core, read @ pxl2_cen by the DAC.
    //  Two banks (selected by `bank` flipped on each HSync rise) avoid
    //  read/write collisions: write current line into `bank`, read the
    //  previous line (`~bank`) which is already complete.
    // ------------------------------------------------------------------
    (* ramstyle = "no_rw_check, M10K" *) reg [23:0] mem [0:(1<<AW)-1];
    integer ii;
    initial for (ii = 0; ii < (1<<AW); ii = ii + 1) mem[ii] = 24'd0;

    // ------------------------------------------------------------------
    //  WRITE side @ pxl_cen
    // ------------------------------------------------------------------
    reg [AW-1:0] wrp;
    reg [AW-1:0] hmax;
    reg [AW-1:0] hb0, hb1;
    reg          lhb_l;
    reg          bank;
    initial begin
        wrp = 0; hmax = 0;
        hb0 = 0; hb1 = 0;
        lhb_l = 0;
        bank = 0;
    end

    wire lhb = ~hb_in;

    always @(posedge clk) if (pxl_cen) begin
        lhb_l <= lhb;
        mem[{bank, wrp[AW-2:0]}] <= {r_in, g_in, b_in};
        if (hs_rise_in) begin
            wrp  <= {AW{1'b0}};
            hmax <= wrp;
            bank <= ~bank;
        end else begin
            wrp <= wrp + 1'b1;
        end
        if (lhb   & ~lhb_l) hb1 <= wrp;  // start of active region (wrp value)
        if (~lhb  &  lhb_l) hb0 <= wrp;  // end of active region   (wrp value)
    end

    // ------------------------------------------------------------------
    //  READ side @ pxl2_cen.
    //  rdcnt increments by 1 at each pxl2_cen pulse -> exactly one source
    //  pixel is emitted to the DAC per read tick. Reset is triggered by
    //  the rising edge of HSync, detected at FULL clk rate to avoid
    //  missing edges when pxl2_cen is slow.
    // ------------------------------------------------------------------
    reg [AW-1:0] rdcnt;
    reg          hs_in_d2;
    reg          hs_rise_pending;
    initial begin
        rdcnt = 0;
        hs_in_d2 = 0;
        hs_rise_pending = 0;
    end

    always @(posedge clk) begin
        hs_in_d2 <= hs_read_ref;
        if (hs_read_ref & ~hs_in_d2)  hs_rise_pending <= 1'b1;
        else if (pxl2_cen)            hs_rise_pending <= 1'b0;
    end

    always @(posedge clk) if (pxl2_cen) begin
        if (hs_rise_pending) begin
            rdcnt <= {AW{1'b0}};
        end else begin
            rdcnt <= rdcnt + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    //  Read from the linebuffer @ pxl2_cen, on the OPPOSITE bank to the
    //  one currently being written (so the previous fully-written line).
    //  pass_q gates active video against blanking, in linebuffer units.
    // ------------------------------------------------------------------
    reg [23:0] rd_data;
    reg        pass_q;
    initial begin
        rd_data = 0;
        pass_q = 0;
    end

    // vb_active: VBlank verticale vero, allineato al READ side.
    // Serve a spegnere pass_q durante le righe di VBlank -> VGA_DE torna basso
    // nel VBlank -> l'OSD trova il confine verticale del frame e resta visibile.
    // NON tocca hb0/hb1 (bordi orizzontali) -> nessun re-clamp del "gotcha".
    //
    // FIX pixel tagliati in basso: il read side emette la riga PRECEDENTE
    // (~bank), quindi e` in ritardo di 1 riga rispetto al write/vb_in nativo.
    // Se vb_active seguisse vb_in al write rate, spegnerebbe pass_q mentre il
    // read sta ancora emettendo l'ultima riga attiva -> ultima riga mangiata.
    // Campiono vb_in una volta per riga (hs_rise) e lo ritardo di 1 riga cosi`
    // vb_active si allinea a cio` che il read sta effettivamente emettendo.
    // (Tank: VBlank changes at the line wrap and HSync, hcount 32..63, comes
    //  before the picture, hcount 128..901, so the bank read in line L holds
    //  line L-1 and this one-line-late gate matches it.  Gating on vb_in
    //  instead adds a stale top line and drops the bottom one.)
    reg vb_line, vb_active;
    initial begin vb_line = 0; vb_active = 0; end
    always @(posedge clk) if (hs_rise_in) begin
        vb_line   <= vb_in;
        vb_active <= vb_line;
    end

    // hoffset (signed) sposta la finestra attiva: >0 = contenuto a DESTRA, <0 a
    // SINISTRA. rd_addr compensa per leggere il pixel sorgente giusto. hs_out NON
    // e' toccato -> HSync intatto -> no desync, qualunque sia l'entita' del shift.
    //
    // In HPOS_SYNCSHIFT the horizontal offset is applied to HSync out (see below),
    // NOT to the read window: the content stays anchored natively, so the read
    // offset is forced to 0 here and hb1/hb0 keep gating the native active area.
    // (Tank adaptation: upstream's unsigned {(AW+2){1'b0}} arm made the whole
    //  ?: unsigned, so $signed(hoffset) was ZERO-extended — a left shift of
    //  -5 became +507 and pushed the picture out of the line.  Both arms are
    //  signed now, so hoffset sign-extends as intended.)
    wire signed [AW+1:0] hoff_s  = (HPOS_MODE == `HPOS_CONTENTSHIFT)
                                   ? $signed(hoffset)
                                   : $signed({(AW+2){1'b0}});
    wire signed [AW+1:0] rdcnt_s = $signed({2'b0, rdcnt});
    wire signed [AW+1:0] hb1_s   = $signed({2'b0, hb1});
    wire signed [AW+1:0] hb0_s   = $signed({2'b0, hb0});
    wire [AW-1:0] rd_addr = (rdcnt_s - hoff_s);
    always @(posedge clk) if (pxl2_cen) begin
        rd_data <= mem[{~bank, rd_addr[AW-2:0]}];
        pass_q  <= (rdcnt_s >= (hb1_s + hoff_s)) && (rdcnt_s < (hb0_s + hoff_s)) && ~vb_active;
    end

    // ------------------------------------------------------------------
    //  V-Shift INTERNO: ritarda il VSync di N righe via shift register per
    //  linea (voffset signed). Sposta il VSync, non il contenuto: verticalmente
    //  il CRT ha ampia tolleranza -> nessun desync. hs_rise_in = fine riga.
    // ------------------------------------------------------------------
    // (Tank adaptation: tap sized VTW bits; upstream's 9-bit signed tap
    //  overflowed for VTOTAL > 255.)
    localparam [VTW-1:0] VTOT_W = VTOTAL;
    wire [VTW-1:0] vshift_tap = voffset[5]
        ? (VTOT_W + {{(VTW-6){voffset[5]}}, voffset})  // negativo -> VTOTAL - |N|
        : {{(VTW-6){1'b0}}, voffset};                  // positivo -> N
    reg [VTOTAL-1:0] vsync_line_shreg;
    initial vsync_line_shreg = 0;
    always @(posedge clk) if (hs_rise_in)
        vsync_line_shreg <= {vsync_line_shreg[VTOTAL-2:0], vs_in};

    // (Tank adaptation: VSync is also sampled half a line after the HSync
    //  rise, through its own line delay, so an interlaced field whose VSync
    //  edge falls mid-line keeps it there.  Sampling only at the HSync rise
    //  moved that edge to the next line start, and a CRT then drew both
    //  fields on the same scanlines.  A VSync that changes only at line
    //  starts reads the same at both points and comes out as before.)
    localparam [AW-1:0] HHALF = HTOTAL / 2;
    wire hs_mid_in = pxl_cen && !hs_rise_in && (wrp == HHALF);
    reg [VTOTAL-1:0] vsync_mid_shreg;
    initial vsync_mid_shreg = 0;
    always @(posedge clk) if (hs_mid_in)
        vsync_mid_shreg <= {vsync_mid_shreg[VTOTAL-2:0], vs_in};

    reg vs_shifted;
    initial vs_shifted = 0;
    always @(posedge clk)
        if (hs_rise_in)
            vs_shifted <= (vshift_tap == 0) ? vs_in : vsync_line_shreg[vshift_tap - 1'd1];
        else if (hs_mid_in)
            vs_shifted <= (vshift_tap == 0) ? vs_in : vsync_mid_shreg[vshift_tap - 1'd1];

    // Field flag through the same two line delays as VSync, so it changes
    // with the VSync edge it belongs to (Tank adaptation).
    reg [VTOTAL-1:0] fl_line_shreg;
    initial fl_line_shreg = 0;
    always @(posedge clk) if (hs_rise_in)
        fl_line_shreg <= {fl_line_shreg[VTOTAL-2:0], fl_in};
    reg [VTOTAL-1:0] fl_mid_shreg;
    initial fl_mid_shreg = 0;
    always @(posedge clk) if (hs_mid_in)
        fl_mid_shreg <= {fl_mid_shreg[VTOTAL-2:0], fl_in};
    reg fl_shifted;
    initial fl_shifted = 0;
    always @(posedge clk)
        if (hs_rise_in)
            fl_shifted <= (vshift_tap == 0) ? fl_in : fl_line_shreg[vshift_tap - 1'd1];
        else if (hs_mid_in)
            fl_shifted <= (vshift_tap == 0) ? fl_in : fl_mid_shreg[vshift_tap - 1'd1];

    // HSync emitted by the module: shifted only in HPOS_SYNCSHIFT, else native.
    // (hsync_pix_shreg / hs_shifted are computed above, before the read side.)
    wire hs_pos_out = (HPOS_MODE == `HPOS_SYNCSHIFT) ? hs_shifted : hs_in_q;

    // ------------------------------------------------------------------
    //  Output mux. CRITICAL: when stretch is active, outputs MUST be
    //  registered @ pxl2_cen (the DAC rate), NOT @ pxl_cen (the write
    //  rate). Otherwise the fast write clock would re-sample the slow
    //  read data at write rate, breaking the "every pixel lasts exactly
    //  (base+hsize) quarter-cycles" property and re-introducing shimmering.
    //  In bypass mode, registers run at pxl_cen for full passthrough.
    // ------------------------------------------------------------------
    // Bypass controllato dall'ON/OFF: OFF -> passthrough nativo puro.
    // ON -> modulo sempre attivo (anche con hsize=0/hoffset=0), cosi` H-Position
    // e V-Shift funzionano anche senza scala.
    wire bypass = ~active;
    wire pass_out = pass_q & ~hs_pos_out;   // Tank adaptation, see below

    initial begin
        r_out = 0; g_out = 0; b_out = 0;
        hs_out = 0; vs_out = 0; hb_out = 1; vb_out = 0; fl_out = 0;
    end

    always @(posedge clk) begin
        if (bypass) begin
            if (pxl_cen) begin
                r_out  <= r_in_q;
                g_out  <= g_in_q;
                b_out  <= b_in_q;
                hb_out <= hb_in_q;
                hs_out <= hs_in_q;
                vs_out <= vs_in_q;
                vb_out <= vb_in_q;
                fl_out <= fl_in_q;
            end
        end else begin
            if (pxl2_cen) begin
                // (Tank adaptation: pass_out = pass_q blanked while the output
                //  HSync is high.  When H-Position / H-Size push the content
                //  past the end of the line, its tail meets the next HSync:
                //  pass_q lags rdcnt by two ticks and HSync out by one, so DE
                //  stayed high a tick past the HSync rise (and those last reads
                //  already hit the freshly swapped bank).  Picture during sync
                //  is never valid, so the line now ends cleanly at HSync.)
                if (pass_out) begin
                    r_out <= rd_data[23:16];
                    g_out <= rd_data[15:8];
                    b_out <= rd_data[7:0];
                end else begin
                    r_out <= 8'd0;
                    g_out <= 8'd0;
                    b_out <= 8'd0;
                end
                hb_out <= ~pass_out;
                hs_out <= hs_pos_out;   // HPOS_SYNCSHIFT -> shifted HSync, else native
                vs_out <= vs_shifted;   // V-Shift interno (VSync shiftato)
                fl_out <= fl_shifted;   // field flag follows VSync (Tank)
                vb_out <= vb_in_q;
            end
        end
    end

endmodule
