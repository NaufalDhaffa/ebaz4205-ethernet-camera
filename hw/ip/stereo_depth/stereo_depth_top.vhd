----------------------------------------------------------------------------------
-- stereo_depth_top: EBAZ4205 port of Archfx/FPGA-DepthMap-Basys3's dual-OV7670
-- + SSD disparity pipeline. See hw/ip/stereo_depth/*.vhd headers for what was
-- ported unchanged vs. adapted, and the porting plan for the full rationale.
--
-- Deviations from the reference design, summarized here since they're
-- spread across several files:
--  - VGA/RGB output path dropped entirely (no VGA connector on this board).
--    Its role -- reading the finished disparity frame out -- is replaced by
--    exposing disparity_ram's free read/write port directly as a native
--    BRAM port for an AXI BRAM Controller (axi_* ports below), giving the
--    PS random-access reads instead of a fixed-rate scanout.
--  - The "average image" frame buffer (write-only demo/debug output in the
--    original, only ever read by the dropped VGA path) is not instantiated
--    at all here -- disparity_generator's avg_out/avg_reg_en ports are left
--    open.
--  - Image_Rectification's 4 pushbuttons replaced by row_offset/col_offset
--    registers (this board has none) -- see image_rectification.vhd.
--  - disparity_generator gained one new `frame_done` output pulse (see that
--    file's header) so the PS knows when a frame is ready.
--  - CLK_MAIN and clk_camera (HCLK) are both tied to the same input (port
--    `clk50`, named for its original intended 50MHz -- see
--    hw/scripts/build_bd.tcl's PCW_FPGA0_PERIPHERAL_FREQMHZ for what it's
--    actually set to). The original used a Clocking Wizard whose CLK_MAIN
--    frequency wasn't recoverable from the files pulled during porting;
--    50MHz was tried first here but failed timing closure on the
--    SSD_calc_process's 8-tap combinational path (WNS ~-1.7ns, confirmed
--    via place_design/route_design, not guessed) -- FCLK0 is set to 40MHz
--    instead, which closes with WNS = +0.199ns / WHS = +0.027ns. That is
--    real but thin margin: anything that lengthens the SSD path should be
--    re-checked against route_design rather than assumed safe, and the
--    answer if it violates is to drop FCLK0 further. This also slows
--    camera XCLK (derived from the same clk50 input, divide-by-2) to
--    20MHz, still within OV7670's valid 10-48MHz range.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- IOBUF is instantiated by hand for the two SCCB data lines; see the SCCB
-- mux below for why inference could not be relied on here.
library UNISIM;
use UNISIM.vcomponents.all;

entity stereo_depth_top is
  Port (
    clk50 : in STD_LOGIC; -- PS7 FCLK_CLK0

    -- Camera 1 (DATA1/DATA2 headers, see docs/BOARD_CONFIG.md)
    cam_pclk     : in    STD_LOGIC;
    cam_xclk     : out   STD_LOGIC;
    cam_vsync    : in    STD_LOGIC;
    cam_href     : in    STD_LOGIC;
    cam_pdata    : in    STD_LOGIC_VECTOR(7 downto 0);
    cam_sioc     : out   STD_LOGIC;
    cam_siod     : inout STD_LOGIC;
    cam_pwdn     : out   STD_LOGIC;
    cam_reset_n  : out   STD_LOGIC;

    -- Camera 2 (DATA3/DATA2 headers)
    -- No cam2_xclk: both sensors share cam_xclk, so one divider drives both.
    -- Their PCLKs still free-run independently -- an OV7670 derives its pixel
    -- clock internally, so a shared XCLK does not phase-align them, and the
    -- two PCLK domains stay asynchronous exactly as before.
    cam2_pclk    : in    STD_LOGIC;
    cam2_vsync   : in    STD_LOGIC;
    cam2_href    : in    STD_LOGIC;
    cam2_pdata   : in    STD_LOGIC_VECTOR(7 downto 0);
    cam2_sioc    : out   STD_LOGIC;
    cam2_siod    : inout STD_LOGIC;
    cam2_pwdn    : out   STD_LOGIC;
    cam2_reset_n : out   STD_LOGIC;

    -- Control (driven by an AXI GPIO block from the PS). These are meant
    -- for small stereo-alignment corrections; the reference project's own
    -- defaults were row_offset=8, col_offset=20. Even at their maximum
    -- (15, 255) the resulting frame-buffer address stays inside the buffers
    -- -- see the Inst_frame_buffer_* comments below for the arithmetic.
    resend       : in  STD_LOGIC;
    row_offset   : in  STD_LOGIC_VECTOR(3 downto 0);
    col_offset   : in  STD_LOGIC_VECTOR(7 downto 0);

    -- PS-driven SCCB override. The hardware ov7670_controller still blasts
    -- the boot-time register table, but raising ps_sccb_en hands the two
    -- SCCB buses to software so ANY camera register can be read or written
    -- at run time (orientation, exposure, gain, test pattern...) without
    -- rebuilding the bitstream. Bit 0 of each vector is camera 1, bit 1 is
    -- camera 2.
    -- siod is open-drain: software asserts ps_siod_oe to pull the line low,
    -- and releases it (oe=0) to let the camera drive or the pull-up win.
    ps_sccb_en   : in  STD_LOGIC;
    ps_sioc      : in  STD_LOGIC_VECTOR(1 downto 0);
    ps_siod_o    : in  STD_LOGIC_VECTOR(1 downto 0);
    ps_siod_oe   : in  STD_LOGIC_VECTOR(1 downto 0);
    ps_siod_i    : out STD_LOGIC_VECTOR(1 downto 0);

    -- Snapshot handshake for all three PS-readable buffers. Hold snap_arm
    -- high; each buffer freezes after it has captured one whole frame and
    -- raises its ready bit. Without this the PS reads buffers that are
    -- still being overwritten and gets an image spliced from several
    -- frames (visible as horizontal banding).
    snap_arm     : in  STD_LOGIC;

    -- '1' = pakai cam2 sebagai citra acuan mesin depth (peran kiri/kanan
    -- ditukar). Bersama row_offset/col_offset di atas, ini yang membuat
    -- kalibrasi ulang cukup dengan menulis register, tanpa build bitstream.
    cam_swap     : in  STD_LOGIC;

    -- Camera RESET#/PWDN, driven from the PS instead of tied to constants.
    -- Both are ACTIVE HIGH here so that the AXI GPIO's reset value (all
    -- zeros) means "not in reset, powered up" -- the safe state. An OV7670
    -- that powered up while these pins were still high-Z (before the FPGA
    -- was configured) can latch into a state its internal power-on reset
    -- does not clear; with RESET# wired to a constant there was no way to
    -- get it out again without cycling board power.
    cam_reset_assert : in STD_LOGIC;
    cam_pwdn_assert  : in STD_LOGIC;

    -- Which byte of each YUV422 pair is luma (see ov7670_capture.vhd).
    -- Host-selected rather than fixed, because the phase depends on where
    -- HREF lands relative to the decimation counter.
    luma_phase       : in STD_LOGIC;

    -- Debug taps for the two ILAs in the block design. Only signals that
    -- live INSIDE this module need bringing out: the camera's own pins are
    -- already BD ports and the ILA probes attach to those nets directly.
    -- dbg_siod_in in particular must come from the fabric side of the
    -- SIOD IOBUF, never from the cam_siod inout net -- adding an ILA load
    -- to an IOBUF pad net fails place_design with DRC REQP-1582.
    dbg_siod_in      : out STD_LOGIC;   -- SIOD as the FPGA actually reads it
    dbg_siod_low     : out STD_LOGIC;   -- '1' while the FPGA pulls SIOD low
    dbg_cap_we       : out STD_LOGIC;   -- capture write strobe, PCLK domain
    dbg_cap_pix      : out STD_LOGIC_VECTOR(3 downto 0);  -- luma nibble stored
    -- Same four taps for camera 2. Kept as a separate set rather than a
    -- mux: the two pixel paths run on independent PCLKs, so they need
    -- independent ILAs and cannot share probe wiring.
    dbg2_siod_in     : out STD_LOGIC;
    dbg2_siod_low    : out STD_LOGIC;
    dbg2_cap_we      : out STD_LOGIC;
    dbg2_cap_pix     : out STD_LOGIC_VECTOR(3 downto 0);
    snap_ready   : out STD_LOGIC_VECTOR(2 downto 0);  -- [0]=cam1 [1]=cam2 [2]=depth

    -- Status (read by the PS, e.g. via AXI GPIO input). frame_done_toggle
    -- flips once per finished frame (NOT a raw pulse -- disparity_generator's
    -- own frame_done output is a single clk50-cycle pulse, far too short
    -- for software polling a memory-mapped register to reliably catch;
    -- this wraps it into a level that stays stable between frames, so
    -- software just watches for it to change value).
    cam1_config_ok    : out STD_LOGIC;
    cam2_config_ok    : out STD_LOGIC;
    frame_done_toggle : out STD_LOGIC;

    -- Per-camera pixel-path activity counters (see cam_activity.vhd) --
    -- diagnostic only, nothing downstream depends on them.
    cam1_activity : out STD_LOGIC_VECTOR(31 downto 0);
    cam2_activity : out STD_LOGIC_VECTOR(31 downto 0);

    -- Capture-stage probes (see capture_probe.vhd) -- distinguishes "pins
    -- are alive" from "capture actually latches into the frame buffers".
    cap_we_counts  : out STD_LOGIC_VECTOR(31 downto 0);
    cap_wdata_info : out STD_LOGIC_VECTOR(31 downto 0);

    -- Native BRAM port for an AXI BRAM Controller (DATA_WIDTH=32, the
    -- IP's minimum -- it doesn't accept anything narrower, empirically
    -- confirmed) -- gives the PS random-access reads (and writes, unused)
    -- onto the finished disparity frame, packed 4 pixels/word with
    -- byte-lane write enables. axi_addrb is a WORD address (15 bits for
    -- 32768 words = 128KB) -- the byte-address-to-word-address slice
    -- happens in the block design, dropping bram_addr_a's 2 LSBs (see
    -- hw/scripts/build_bd.tcl), since those are always zero for properly
    -- 4-byte-aligned AXI transactions anyway.
    axi_clk   : in  STD_LOGIC;
    axi_web   : in  STD_LOGIC_VECTOR(3 downto 0);
    axi_addrb : in  STD_LOGIC_VECTOR(14 downto 0);
    axi_dinb  : in  STD_LOGIC_VECTOR(31 downto 0);
    axi_doutb : out STD_LOGIC_VECTOR(31 downto 0);

    -- Raw-camera preview windows (see preview_buffer.vhd). Packed 8 pixels
    -- per 32-bit word; needed because the real frame buffers have no spare
    -- port for the PS to read.
    prev1_web   : in  STD_LOGIC_VECTOR(3 downto 0);
    prev1_addrb : in  STD_LOGIC_VECTOR(11 downto 0);
    prev1_dinb  : in  STD_LOGIC_VECTOR(31 downto 0);
    prev1_doutb : out STD_LOGIC_VECTOR(31 downto 0);

    prev2_web   : in  STD_LOGIC_VECTOR(3 downto 0);
    prev2_addrb : in  STD_LOGIC_VECTOR(11 downto 0);
    prev2_dinb  : in  STD_LOGIC_VECTOR(31 downto 0);
    prev2_doutb : out STD_LOGIC_VECTOR(31 downto 0)
  );
end stereo_depth_top;

architecture rtl of stereo_depth_top is

  component ov7670_controller
    Port ( clk             : in    STD_LOGIC;
           resend          : in    STD_LOGIC;
           config_finished : out   STD_LOGIC;
           sioc            : out   STD_LOGIC;
           siod            : inout STD_LOGIC;
           reset_n         : out   STD_LOGIC;
           pwdn            : out   STD_LOGIC;
           xclk            : out   STD_LOGIC);
  end component;

  component ov7670_capture
    Generic ( WIDTH : positive; HEIGHT : positive; DEBOUNCE_CYCLES : positive );
    Port ( pclk  : in   STD_LOGIC;
           rez_160x120 : IN std_logic;
           rez_320x240 : IN std_logic;
           luma_phase : in std_logic;
           vsync_clean_out : out STD_LOGIC;
           vsync : in   STD_LOGIC;
           href  : in   STD_LOGIC;
           d     : in   STD_LOGIC_VECTOR (7 downto 0);
           addr  : out  STD_LOGIC_VECTOR (16 downto 0);
           dout  : out  STD_LOGIC_VECTOR (11 downto 0);
           we    : out  STD_LOGIC);
  end component;

  component dpram
    generic ( DATA_WIDTH : positive; WE_WIDTH : positive; ADDR_WIDTH : positive; DEPTH : positive );
    Port ( clka  : in  STD_LOGIC;
           wea   : in  STD_LOGIC_VECTOR (WE_WIDTH-1 downto 0);
           addra : in  STD_LOGIC_VECTOR (ADDR_WIDTH-1 downto 0);
           dina  : in  STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
           douta : out STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
           clkb  : in  STD_LOGIC;
           web   : in  STD_LOGIC_VECTOR (WE_WIDTH-1 downto 0);
           addrb : in  STD_LOGIC_VECTOR (ADDR_WIDTH-1 downto 0);
           dinb  : in  STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0);
           doutb : out STD_LOGIC_VECTOR (DATA_WIDTH-1 downto 0));
  end component;

  component image_rectification
    generic ( WIDTH : positive );
    Port ( address_in    : in  STD_LOGIC_VECTOR (16 downto 0);
           row_offset    : in  STD_LOGIC_VECTOR (3 downto 0);
           col_offset    : in  STD_LOGIC_VECTOR (7 downto 0);
           address_left  : out STD_LOGIC_VECTOR (16 downto 0);
           address_right : out STD_LOGIC_VECTOR (16 downto 0));
  end component;

  component disparity_generator
    generic (window:positive; WIDTH:positive; HEIGHT:positive;
             maxoffset:positive; minoffset:positive; fetchBlock:positive);
    Port ( HCLK            : in  STD_LOGIC;
           CLK_MAIN        : in  STD_LOGIC;
           left_in         : in  STD_LOGIC_vector(3 downto 0);
           right_in        : in  STD_LOGIC_vector(3 downto 0);
           avg_out         : out STD_LOGIC_vector(3 downto 0);
           dOUT            : out STD_LOGIC_vector(7 downto 0);
           dOUT_addr       : out STD_LOGIC_vector(16 downto 0);
           left_right_addr : out STD_LOGIC_vector(16 downto 0);
           avg_reg_en      : out STD_LOGIC;
           wr_en           : out STD_LOGIC;
           frame_done      : out STD_LOGIC);
  end component;

  component cam_activity
    Port ( pclk   : in  STD_LOGIC;
           vsync  : in  STD_LOGIC;
           href   : in  STD_LOGIC;
           pdata  : in  STD_LOGIC_VECTOR(7 downto 0);
           status : out STD_LOGIC_VECTOR(31 downto 0));
  end component;

  component preview_buffer
    generic ( ADDR_WIDTH : positive; DEPTH : positive );
    Port ( pclk : in STD_LOGIC; vsync : in STD_LOGIC; we : in STD_LOGIC;
           wdata : in STD_LOGIC_VECTOR(3 downto 0);
           axi_clk : in STD_LOGIC;
           axi_web : in STD_LOGIC_VECTOR(3 downto 0);
           axi_addrb : in STD_LOGIC_VECTOR(ADDR_WIDTH-1 downto 0);
           axi_dinb : in STD_LOGIC_VECTOR(31 downto 0);
           axi_doutb : out STD_LOGIC_VECTOR(31 downto 0);
           arm : in STD_LOGIC; ready : out STD_LOGIC);
  end component;

  component capture_probe
    Port ( pclk_l  : in STD_LOGIC; we_l : in STD_LOGIC;
           wdata_l : in STD_LOGIC_VECTOR(3 downto 0);
           vsync_l : in STD_LOGIC; href_l : in STD_LOGIC;
           pclk_r  : in STD_LOGIC; we_r : in STD_LOGIC;
           wdata_r : in STD_LOGIC_VECTOR(3 downto 0);
           vsync_r : in STD_LOGIC; href_r : in STD_LOGIC;
           we_counts  : out STD_LOGIC_VECTOR(31 downto 0);
           wdata_info : out STD_LOGIC_VECTOR(31 downto 0));
  end component;

  constant ZERO4 : STD_LOGIC_VECTOR(3 downto 0) := (others => '0');

  signal wraddress_l, wraddress_r : STD_LOGIC_VECTOR(16 downto 0);
  signal wrdata_l, wrdata_r       : STD_LOGIC_VECTOR(11 downto 0);
  signal wren_l, wren_r           : STD_LOGIC;
  signal rddata_l, rddata_r       : STD_LOGIC_VECTOR(3 downto 0);

  signal address_left, address_right : STD_LOGIC_VECTOR(16 downto 0);
  signal left_right_addr             : STD_LOGIC_VECTOR(16 downto 0);
  signal eng_l_addr, eng_r_addr, eng_o_addr : STD_LOGIC_VECTOR(14 downto 0);
  signal eng_l_data, eng_r_data             : STD_LOGIC_VECTOR(3 downto 0);
  signal disparity_out               : STD_LOGIC_VECTOR(7 downto 0);
  signal wr_address_disp             : STD_LOGIC_VECTOR(16 downto 0);
  signal wr_en                       : STD_LOGIC;

  -- disparity_generator writes one 8-bit pixel/cycle; disparity_ram is
  -- packed 4 pixels/32-bit word (to satisfy axi_bram_ctrl's 32-bit
  -- minimum, see the axi_* port comments above) with byte-lane write
  -- enables, so each pixel write is decoded into a word address + a
  -- single asserted byte lane here.
  signal disp_word_addr : STD_LOGIC_VECTOR(14 downto 0);
  signal disp_byte_we   : STD_LOGIC_VECTOR(3 downto 0);
  signal disp_wdata     : STD_LOGIC_VECTOR(31 downto 0);

  -- Controller-side SCCB, muxed onto the pins below.
  signal ctrl_sioc1, ctrl_siod1 : STD_LOGIC;
  signal ctrl_sioc2, ctrl_siod2 : STD_LOGIC;

  -- One open-drain "pull this line low" request per camera, combining the
  -- hardware controller and the PS override. Kept as explicit signals so the
  -- tristate below is a plain two-branch assignment -- see the comment at
  -- the SCCB mux for why that matters.
  signal siod1_low, siod2_low : STD_LOGIC;

  -- Pin level read back out of the IOBUFs -- the camera pulling the line low
  -- during a read or an ACK is only visible here.
  signal siod1_in, siod2_in : STD_LOGIC;

  -- Debounced frame sync from each capture block, shared with the preview
  -- buffers so they no longer restart on a glitch.
  signal vsync_clean_l, vsync_clean_r : STD_LOGIC;

  signal frame_done_pulse : STD_LOGIC;

  -- Same arm/capture/freeze sequence as preview_buffer, but keyed on the
  -- disparity engine's own frame boundary instead of a camera VSYNC.
  type dsnap_t is (D_IDLE, D_WAIT_START, D_CAPTURING, D_DONE);
  signal dsnap     : dsnap_t := D_IDLE;
  signal d_capture : STD_LOGIC;
  signal prev1_ready, prev2_ready : STD_LOGIC;
  signal depth_ready : STD_LOGIC;
  signal frame_done_toggle_r : STD_LOGIC := '0';

begin

  process(clk50)
  begin
    if rising_edge(clk50) then
      if frame_done_pulse = '1' then
        frame_done_toggle_r <= not frame_done_toggle_r;
      end if;
    end if;
  end process;
  frame_done_toggle <= frame_done_toggle_r;

  -- As in preview_buffer: free-running by default, frozen only while a
  -- completed frame is being held for the PS.
  d_capture <= '0' when dsnap = D_DONE else '1';
  -- '(dsnap = D_DONE)' is a boolean, which has no '&' with std_logic;
  -- convert first.
  depth_ready <= '1' when dsnap = D_DONE else '0';
  snap_ready  <= depth_ready & prev2_ready & prev1_ready;

  dsnap_fsm: process(clk50)
  begin
    if rising_edge(clk50) then
      case dsnap is
        when D_IDLE =>
          if snap_arm = '1' then dsnap <= D_WAIT_START; end if;
        when D_WAIT_START =>
          if snap_arm = '0' then dsnap <= D_IDLE;
          elsif frame_done_pulse = '1' then dsnap <= D_CAPTURING; end if;
        when D_CAPTURING =>
          if snap_arm = '0' then dsnap <= D_IDLE;
          elsif frame_done_pulse = '1' then dsnap <= D_DONE; end if;
        when D_DONE =>
          if snap_arm = '0' then dsnap <= D_IDLE; end if;
      end case;
    end if;
  end process;

  disp_word_addr <= wr_address_disp(16 downto 2);
  disp_byte_we <= (others => '0') when d_capture = '0' else
                  (0 => wr_en, others => '0') when wr_address_disp(1 downto 0) = "00" else
                  (1 => wr_en, others => '0') when wr_address_disp(1 downto 0) = "01" else
                  (2 => wr_en, others => '0') when wr_address_disp(1 downto 0) = "10" else
                  (3 => wr_en, others => '0');
  disp_wdata <= disparity_out & disparity_out & disparity_out & disparity_out;

  Inst_cam1_controller: ov7670_controller port map (
    clk => clk50, resend => resend, config_finished => cam1_config_ok,
    sioc => ctrl_sioc1, siod => ctrl_siod1, reset_n => open,
    pwdn => open, xclk => cam_xclk
  );

  Inst_cam2_controller: ov7670_controller port map (
    clk => clk50, resend => resend, config_finished => cam2_config_ok,
    sioc => ctrl_sioc2, siod => ctrl_siod2, reset_n => open,
    -- xclk left open: cam1's controller drives the shared XCLK pin. Both
    -- dividers would produce the same clk50/2, but a pin can only have one
    -- driver, so cam2's copy is simply unused.
    pwdn => open, xclk => open
  );

  -- RESET# is active low at the sensor; PWDN is active high.
  cam_reset_n  <= not cam_reset_assert;
  cam2_reset_n <= not cam_reset_assert;
  cam_pwdn     <= cam_pwdn_assert;
  cam2_pwdn    <= cam_pwdn_assert;

  -- SCCB pin mux. With ps_sccb_en low the hardware controller owns the bus
  -- exactly as before; with it high, software does. siod is only ever
  -- actively driven LOW -- never high -- so the bus stays open-drain and
  -- the camera can drive it during reads and ACKs.
  cam_sioc  <= ps_sioc(0) when ps_sccb_en = '1' else ctrl_sioc1;
  cam2_sioc <= ps_sioc(1) when ps_sccb_en = '1' else ctrl_sioc2;

  -- SCCB is open-drain: a driver only ever pulls the line LOW, and the
  -- external pull-up provides the high level. Work out that single pull-low
  -- request first, from whichever side owns the bus.
  --
  -- The previous version wrote this as one conditional assignment whose 'Z'
  -- branch fell through to `ctrl_siod1` -- itself the inout of i2c_sender.
  -- Vivado could not infer a tristate from that chain and synthesised both
  -- pins as plain OBUFs: no IBUF, no OBUFT, no input path at all (confirmed
  -- on the routed checkpoint -- `cam_siod_OBUF_inst (OBUF)`). Every SCCB
  -- read therefore returned 0x00 no matter what the camera did, ACK
  -- detection always reported success because !0 = 1, and the pin sat at
  -- 3.3 V because the FPGA was driving it, not the pull-up. Keeping the
  -- tristate to a bare two-branch assignment over a plain signal is what
  -- makes the IOBUF appear.
  siod1_low <= '1' when (ps_sccb_en = '1' and ps_siod_oe(0) = '1' and ps_siod_o(0) = '0') else
               '1' when (ps_sccb_en = '0' and ctrl_siod1 = '0') else
               '0';
  siod2_low <= '1' when (ps_sccb_en = '1' and ps_siod_oe(1) = '1' and ps_siod_o(1) = '0') else
               '1' when (ps_sccb_en = '0' and ctrl_siod2 = '0') else
               '0';

  -- Explicit IOBUF rather than an inferred tristate. Writing the assignment
  -- as `cam_siod <= '0' when siod1_low = '1' else 'Z'` is textbook and works
  -- in simulation, but this module is instantiated as a cell inside a block
  -- design and connected to a BD port of direction IO -- across that
  -- boundary Vivado still flattened it to a plain OBUF, exactly as the
  -- original conditional assignment did. Instantiating the primitive is the
  -- only form that reliably produces the input path.
  --
  -- T is active high: T='1' releases the line, T='0' drives I ('0') onto it.
  -- That is open-drain, which is what SCCB needs -- the external pull-up
  -- supplies the high level.
  iobuf_siod1 : IOBUF
    port map (O => siod1_in, IO => cam_siod,  I => '0', T => not siod1_low);
  iobuf_siod2 : IOBUF
    port map (O => siod2_in, IO => cam2_siod, I => '0', T => not siod2_low);

  ps_siod_i <= siod2_in & siod1_in;

  -- Debug taps (camera 1 only -- this build streams camera 1).
  dbg_siod_in  <= siod1_in;
  dbg_siod_low <= siod1_low;
  dbg_cap_we   <= wren_l;
  dbg_cap_pix  <= wrdata_l(7 downto 4);
  dbg2_siod_in  <= siod2_in;
  dbg2_siod_low <= siod2_low;
  dbg2_cap_we   <= wren_r;
  dbg2_cap_pix  <= wrdata_r(7 downto 4);

  -- 160x120, not 320x240: disparity_generator's org_L/org_R LUTRAM cache
  -- (sized WIDTH*fetchBlock) doesn't fit XC7Z010's 6000-cell distributed-RAM
  -- budget at the reference project's original 320x240/fetchBlock=15
  -- sizing (needs 6840 -- confirmed via place_design DRC, not guessed).
  -- XC7Z010 has more BRAM than Basys3's XC7A35T but LESS LUTRAM (6000 vs
  -- 9600), and this array is LUTRAM-bound, not BRAM-bound, so the extra
  -- BRAM headroom doesn't help here. 160x120/fetchBlock=8 keeps
  -- disparity_generator.vhd's cacheManager at 15 bands (fits its existing
  -- 4-bit/16-branch select statements unchanged) while shrinking the array
  -- to a quarter of its previous size.
  Inst_cam1_capture: ov7670_capture
    generic map (WIDTH => 160, HEIGHT => 120, DEBOUNCE_CYCLES => 16)
    port map (
    pclk => cam_pclk, rez_160x120 => '1', rez_320x240 => '0',
    luma_phase => luma_phase, vsync_clean_out => vsync_clean_l,
    vsync => cam_vsync, href => cam_href, d => cam_pdata,
    addr => wraddress_l, dout => wrdata_l, we => wren_l
  );

  Inst_cam2_capture: ov7670_capture
    generic map (WIDTH => 160, HEIGHT => 120, DEBOUNCE_CYCLES => 16)
    port map (
    pclk => cam2_pclk, rez_160x120 => '1', rez_320x240 => '0',
    luma_phase => luma_phase, vsync_clean_out => vsync_clean_r,
    vsync => cam2_vsync, href => cam2_href, d => cam2_pdata,
    addr => wraddress_r, dout => wrdata_r, we => wren_r
  );

  -- Frame buffers: 2**15 entries, addressed by the low 15 bits of the
  -- 17-bit address buses. Worst-case address actually generated at this
  -- design's 160x120/fetchBlock=8/NBANDS=15 geometry is 22014 --
  -- disparity_generator's own max left_right_addr (19359: readreg up to
  -- WIDTH*fetchBlock+2*WIDTH-1, plus the band stride for the last band)
  -- plus image_rectification's largest possible correction (row_offset=15
  -- -> 15*160, col_offset=255). That fits in 15 bits with room to spare, so
  -- the top two address bits are always zero and slicing them off is
  -- lossless. (An earlier DEPTH of 80000 here was left over from the
  -- 320x240 sizing and cost ~12 extra BRAMs for address space that can
  -- never be reached.)
  Inst_cam1_activity: cam_activity port map (
    pclk => cam_pclk, vsync => cam_vsync, href => cam_href,
    pdata => cam_pdata, status => cam1_activity
  );

  Inst_cam2_activity: cam_activity port map (
    pclk => cam2_pclk, vsync => cam2_vsync, href => cam2_href,
    pdata => cam2_pdata, status => cam2_activity
  );

  Inst_capture_probe: capture_probe port map (
    pclk_l => cam_pclk,  we_l => wren_l, wdata_l => wrdata_l(7 downto 4),
    vsync_l => cam_vsync, href_l => cam_href,
    pclk_r => cam2_pclk, we_r => wren_r, wdata_r => wrdata_r(7 downto 4),
    vsync_r => cam2_vsync, href_r => cam2_href,
    we_counts => cap_we_counts, wdata_info => cap_wdata_info
  );

  Inst_preview1: preview_buffer
    generic map (ADDR_WIDTH => 12, DEPTH => 4096)
    port map (
      pclk => cam_pclk, vsync => vsync_clean_l, we => wren_l,
      wdata => wrdata_l(7 downto 4),
      axi_clk => axi_clk, axi_web => prev1_web, axi_addrb => prev1_addrb,
      axi_dinb => prev1_dinb, axi_doutb => prev1_doutb,
      arm => snap_arm, ready => prev1_ready
    );

  Inst_preview2: preview_buffer
    generic map (ADDR_WIDTH => 12, DEPTH => 4096)
    port map (
      pclk => cam2_pclk, vsync => vsync_clean_r, we => wren_r,
      wdata => wrdata_r(7 downto 4),
      axi_clk => axi_clk, axi_web => prev2_web, axi_addrb => prev2_addrb,
      axi_dinb => prev2_dinb, axi_doutb => prev2_doutb,
      arm => snap_arm, ready => prev2_ready
    );

  Inst_frame_buffer_l: dpram
    generic map (DATA_WIDTH => 4, WE_WIDTH => 1, ADDR_WIDTH => 15, DEPTH => 32768)
    port map (
      clka => cam_pclk, wea => (others => wren_l), addra => wraddress_l(14 downto 0),
      dina => wrdata_l(7 downto 4), douta => open,
      clkb => clk50, web => (others => '0'), addrb => address_left(14 downto 0),
      dinb => ZERO4, doutb => rddata_l
    );

  Inst_frame_buffer_r: dpram
    generic map (DATA_WIDTH => 4, WE_WIDTH => 1, ADDR_WIDTH => 15, DEPTH => 32768)
    port map (
      clka => cam2_pclk, wea => (others => wren_r), addra => wraddress_r(14 downto 0),
      dina => wrdata_r(7 downto 4), douta => open,
      clkb => clk50, web => (others => '0'), addrb => address_right(14 downto 0),
      dinb => ZERO4, doutb => rddata_r
    );

  -- Mesin disparitas SAD 5x5 (depth_engine_sad.vhd), menggantikan
  -- image_rectification + disparity_generator. Padanan bit-per-bit dari
  -- engine_sw() di sw/tools/depth_sw.py; lihat hw/sim/depth_engine.
  --
  -- Mesin ini membaca kedua frame buffer langsung dengan alamat sensor
  -- (y*160 + x) dan menyapunya sepanjang KOLOM sensor, karena kalibrasi
  -- terhadap Kinect menempatkan baseline di sumbu itu. Geser rektifikasinya
  -- datang dari register PS lewat port col_offset / row_offset (dulu milik
  -- rektifikasi lama), sekarang dibaca bertanda.
  --
  -- Keluaran: disparitas 1..40 apa adanya, 0 = tidak ada jawaban (BUKAN
  -- lagi (d-1)*4 seperti mesin lama). start ditahan '1': mesin berjalan
  -- terus, ~16,5 ms per frame, dan dsnap_fsm di atas yang membekukan satu
  -- frame utuh di antara dua frame_done untuk dibaca PS.
  -- Pertukaran peran kamera dilakukan di sini, di luar mesin: mesin selalu
  -- melihat "kiri" dan "kanan", dan cam_swap memilih frame buffer mana yang
  -- menjadi yang mana. Preview cam1/cam2 tidak ikut ditukar.
  address_left    <= "00" & eng_l_addr when cam_swap = '0' else "00" & eng_r_addr;
  address_right   <= "00" & eng_r_addr when cam_swap = '0' else "00" & eng_l_addr;
  eng_l_data      <= rddata_l when cam_swap = '0' else rddata_r;
  eng_r_data      <= rddata_r when cam_swap = '0' else rddata_l;
  wr_address_disp <= "00" & eng_o_addr;

  Inst_depth_engine: entity work.depth_engine_sad
    generic map (LINES => 160, PIX => 120, STRIDE => 160, ADDR_W => 15,
                 DMIN => 1, DMAX => 40, UNIQ_DEN => 8, LRC_EN => true)
    port map (
      clk => clk50, rst => '0', start => '1',
      -- register PS, dibaca sebagai bilangan bertanda:
      --   col_offset (8 bit) = geser di sumbu baseline, -128..127
      --   row_offset (4 bit) = geser di sumbu silang,   -8..7
      off_base => signed(col_offset), off_cross => signed(row_offset),
      l_addr => eng_l_addr, l_data => eng_l_data,
      r_addr => eng_r_addr, r_data => eng_r_data,
      o_we => wr_en, o_addr => eng_o_addr, o_data => disparity_out,
      busy => open, frame_done => frame_done_pulse
    );

  Inst_disparity_ram: dpram
    generic map (DATA_WIDTH => 32, WE_WIDTH => 4, ADDR_WIDTH => 15, DEPTH => 32768)
    -- 32768 words * 4 bytes = 128KB, word-addressed (2 pixels' worth of
    -- headroom in address-bit terms over the disparity engine's own
    -- worst-case pixel address ~19520, i.e. ~4880 words, at this design's
    -- 160x120 resolution)
    port map (
      clka => clk50, wea => disp_byte_we, addra => disp_word_addr,
      dina => disp_wdata, douta => open,
      clkb => axi_clk, web => axi_web, addrb => axi_addrb,
      dinb => axi_dinb, doutb => axi_doutb
    );

end rtl;
