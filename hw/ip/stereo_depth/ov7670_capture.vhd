----------------------------------------------------------------------------------
-- Captures one OV7670's parallel output into a frame buffer, decimating
-- VGA down to the configured WIDTH x HEIGHT and keeping the top 4 bits of
-- luma.
--
-- Originally ported from Archfx/FPGA-DepthMap-Basys3, then reworked after
-- three defects -- all present in that original -- were traced and fixed
-- in a separate OV7670/Zynq project on this same bench. Each is a real,
-- hardware-diagnosed failure, not theoretical hardening:
--
--  1. VSYNC was used raw. One glitch on a ribbon-cable VSYNC restarts the
--     frame mid-capture, so a readout ends up spliced from two different
--     frames -- the horizontal banding this design showed. Fixed by
--     requiring VSYNC to hold a new level for DEBOUNCE_CYCLES before it
--     is believed.
--
--  2. The write address free-ran across the whole frame with no per-line
--     anchor. Any line delivering the wrong pixel count (HREF glitch,
--     sensor scaler jitter) then offsets EVERY subsequent line
--     permanently -- structurally a progressive diagonal shear. Fixed by
--     snapping the address to the exact expected line boundary at the
--     start of each captured line, so a bad line corrupts only itself.
--
--  3. The address had no upper bound. The sensor emits more active lines
--     per frame than the buffer budget assumes (measured 239 vs an
--     assumed 204 in the other project), so the address ran past the end
--     and wrapped, overwriting the FRONT of the buffer with trailing-line
--     data. Fixed by dropping writes once the line budget is spent.
--
-- Timing structure below (byte latching on the falling PCLK edge, the
-- href_last shift register for column decimation, and advancing the
-- address on the cycle AFTER a write) is kept exactly as the original --
-- that part was working and is easy to break subtly.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ov7670_capture is
    Generic (
        WIDTH           : positive := 160;
        HEIGHT          : positive := 120;
        -- PCLK cycles VSYNC must hold a new level before it is believed:
        -- long enough to reject cable glitches, short enough to still
        -- resolve well inside the blanking interval.
        DEBOUNCE_CYCLES : positive := 16
    );
    Port ( pclk  : in   STD_LOGIC;
           rez_160x120 : IN std_logic;
           rez_320x240 : IN std_logic;
           -- Which byte of the YUV422 pair carries luma. The sensor emits
           -- U Y V Y, so Y is every other byte, but which phase lands in
           -- the upper half of the two-byte latch depends on where HREF
           -- starts relative to the decimation counter. Resolved at run
           -- time by the host rather than guessed: real luma correlates
           -- strongly between horizontal neighbours and chroma does not,
           -- so scoring both phases picks the right one unambiguously.
           luma_phase : in std_logic;
           vsync : in   STD_LOGIC;
           href  : in   STD_LOGIC;
           d     : in   STD_LOGIC_VECTOR (7 downto 0);
           -- The debounced VSYNC this module uses internally, exported so
           -- every other consumer of frame sync can use the same clean
           -- edge. preview_buffer originally took the raw pin and restarted
           -- its write pointer on each glitch, so only a handful of rows
           -- were ever written and its snapshot "ready" fired on glitch
           -- pairs -- the capture path was immune because the debounce was
           -- applied here, but nothing downstream shared it.
           vsync_clean_out : out STD_LOGIC;
           addr  : out  STD_LOGIC_VECTOR (16 downto 0);
           dout  : out  STD_LOGIC_VECTOR (11 downto 0);
           we    : out  STD_LOGIC);
end ov7670_capture;

architecture Behavioral of ov7670_capture is
   signal d_latch      : std_logic_vector(15 downto 0) := (others => '0');
   signal address      : unsigned(16 downto 0) := (others => '0');
   signal line         : std_logic_vector(1 downto 0)  := (others => '0');
   signal href_last    : std_logic_vector(6 downto 0)  := (others => '0');
   signal we_reg       : std_logic := '0';
   signal href_hold    : std_logic := '0';
   signal latched_href : STD_LOGIC := '0';
   signal latched_d    : STD_LOGIC_VECTOR (7 downto 0) := (others => '0');
   attribute IOB : string;
   attribute IOB of latched_d    : signal is "TRUE";
   attribute IOB of latched_href : signal is "TRUE";
   signal luma_byte    : STD_LOGIC_VECTOR (7 downto 0);

   signal luma_norm, luma_edge : STD_LOGIC_VECTOR (7 downto 0);

   -- Defect 1: debounced VSYNC.
   signal vsync_sync    : std_logic_vector(1 downto 0) := (others => '0');
   signal vsync_cnt     : integer range 0 to DEBOUNCE_CYCLES := 0;
   signal vsync_clean   : std_logic := '0';
   signal vsync_clean_d : std_logic := '0';

   -- Defects 2 and 3: per-line anchor and line budget.
   signal cap_line     : integer range 0 to HEIGHT := 0;
   signal capture_line : std_logic := '0';
   signal line_done    : std_logic := '0';
begin
   vsync_clean_out <= vsync_clean;
   addr <= std_logic_vector(address);
   we   <= we_reg;
   -- Take the top 4 bits of ONE WHOLE BYTE. The original expression,
   -- d_latch(15 downto 12) & d_latch(10 downto 7) & d_latch(4 downto 1),
   -- pulls the R/G/B fields out of an RGB565 pair -- correct for the
   -- reference design, which configured the sensor for RGB565. This port
   -- runs the sensor in YUV422 (COM7 = 0x00), where those same bit
   -- positions straddle the byte boundary: the field that actually reaches
   -- the frame buffer, bits 7..4, was three low bits of one byte glued to
   -- the top bit of the next. That is noise with a faint brightness
   -- correlation -- exactly what the captured frames looked like.
   --
   -- Only bits 7..4 are consumed downstream (stereo_depth_top feeds both
   -- the frame buffer and the preview buffer from wrdata(7 downto 4)), so
   -- the rest is padding.
   -- Default (luma_phase = '0') is the upper byte, and that is not
   -- arbitrary. In YUV422 the sensor emits U Y V Y, so luma sits at ODD
   -- byte indices. The decimating write fires every 8th PCLK, i.e. always
   -- at an EVEN byte index -- chroma. The byte before it, held in
   -- d_latch(15 downto 8), is the luma one. Measured as well as derived:
   -- with the lower byte selected, neighbouring pixels differed by 104 on
   -- a 0..255 scale, which is uncorrelated noise, not an image.
   -- Measured on hardware with the pixel-path ILA, not inferred: within an
   -- active line the even byte phase has a mean |neighbour difference| of
   -- 5.5 while the odd phase has 19.5. Luma is spatially smooth and chroma
   -- is not, so the even bytes are luma -- and at the cycle the decimating
   -- write fires, that byte is the one just latched, d_latch(7 downto 0).
   -- The earlier reasoning from 'YUV422 is U Y V Y so luma is odd' gave
   -- the opposite answer and was wrong for this sensor's byte ordering.
   -- The decimation counter runs ~3 PCLK past the end of the line, so the
   -- 160th write of every row lands after HREF has already fallen. d_latch
   -- stops shifting there, frozen on the line's final byte -- the chroma
   -- phase -- which showed up as a bright column at x=159 (column mean
   -- 127.8 against 2-6 for its neighbours; confirmed on the ILA, which
   -- triggered on "write while HREF low" and caught it three cycles late).
   --
   -- Stepping back one byte for exactly that write recovers the right
   -- phase. Suppressing the write instead would shear the image:
   -- preview_buffer packs by write COUNT, not by address, so every line
   -- must produce exactly 160.
   luma_norm <= d_latch(15 downto 8) when luma_phase = '1' else d_latch(7 downto 0);
   luma_edge <= d_latch(7 downto 0)  when luma_phase = '1' else d_latch(15 downto 8);
   luma_byte <= luma_norm when latched_href = '1' else luma_edge;
   dout <= "0000" & luma_byte(7 downto 4) & "0000";

   -- VSYNC is asynchronous to PCLK and travels the same ribbon as the
   -- data, so it is synchronised and then debounced before use.
   debounce_proc: process(pclk)
   begin
      if rising_edge(pclk) then
         vsync_sync <= vsync_sync(0) & vsync;
         if vsync_sync(1) = vsync_clean then
            vsync_cnt <= 0;
         elsif vsync_cnt = DEBOUNCE_CYCLES - 1 then
            vsync_clean <= vsync_sync(1);
            vsync_cnt   <= 0;
         else
            vsync_cnt <= vsync_cnt + 1;
         end if;
      end if;
   end process;

capture_process: process(pclk)
      variable next_line : std_logic_vector(1 downto 0);
      variable keep      : boolean;
   begin
      if rising_edge(pclk) then
         -- Advance past the write issued last cycle. Placed first so the
         -- per-line anchor below can override it.
         if we_reg = '1' then
            address <= address + 1;
         end if;

         vsync_clean_d <= vsync_clean;
         href_hold     <= latched_href;
         we_reg        <= '0';

         if latched_href = '1' then
            d_latch <= d_latch(7 downto 0) & latched_d;
         end if;

         -- OV7670 default polarity: VSYNC HIGH is blanking, so its falling
         -- edge is the true start of a frame.
         if vsync_clean_d = '1' and vsync_clean = '0' then
            address      <= (others => '0');
            href_last    <= (others => '0');
            line         <= (others => '0');
            cap_line     <= 0;
            line_done    <= '0';
            capture_line <= '0';

         elsif href_hold = '0' and latched_href = '1' then
            -- Start of a scan line: decide whether it is kept, and anchor
            -- its write address to the exact expected boundary.
            case line is
               when "00"   => next_line := "01";
               when "01"   => next_line := "10";
               when "10"   => next_line := "11";
               when others => next_line := "00";
            end case;
            line      <= next_line;
            -- Cleared, not pre-loaded. Shifting this phase was tried as a
            -- way to pull the line's last write back inside HREF; it does
            -- that, but it also moved every sample off luma (measured
            -- neighbour difference went 5.8 -> 15.2, and flipping
            -- luma_phase did not recover it). The end-of-line case is
            -- handled at the luma_byte mux instead, which leaves the
            -- sampling phase of the other 159 pixels untouched.
            href_last <= (others => '0');

            if rez_160x120 = '1' then
               keep := (next_line = "10");
            elsif rez_320x240 = '1' then
               keep := (next_line(1) = '1');
            else
               keep := true;
            end if;

            if keep then
               capture_line <= '1';
            else
               capture_line <= '0';
            end if;

            if keep and line_done = '0' then
               address  <= to_unsigned(cap_line * WIDTH, address'length);
               cap_line <= cap_line + 1;
               -- Set the budget flag only AFTER the last line has been
               -- anchored. Setting it on the last line itself would have
               -- dropped that line's own pixels, capturing HEIGHT-1 rows.
               if cap_line = HEIGHT - 1 then
                  line_done <= '1';
               end if;
            end if;

         else
            if (rez_160x120 = '1' and href_last(6) = '1') or
               (rez_320x240 = '1' and href_last(2) = '1') or
               (rez_160x120 = '0' and rez_320x240 = '0' and href_last(0) = '1') then
               if capture_line = '1' and line_done = '0' then
                  we_reg <= '1';
               end if;
               href_last <= (others => '0');
            else
               href_last <= href_last(href_last'high-1 downto 0) & latched_href;
            end if;
         end if;
      end if;

   end process;

   -- Input registers: sample on the RISING edge, in the pad's own flip-flop.
   --
   -- The OV7670 changes D[7:0] and HREF on the FALLING edge of PCLK and holds
   -- them through the rising edge. The reference design latched them on the
   -- falling edge, i.e. on the very edge where they change; what was captured
   -- then depended on the few nanoseconds between the clock's insertion
   -- delay and each data bit's routing delay. Neither was constrained, and
   -- both moved with every place-and-route. One build was clean; the next
   -- showed camera 2 with ~1300 isolated wrong pixels per frame (7%), bits
   -- of the neighbouring chroma byte leaking into luma, drifting in bands.
   --
   -- Sampling half a period later puts the edge in the middle of the valid
   -- window (PCLK is 20 MHz: 25 ns either side). The IOB attribute pins the
   -- registers into the I/O cells so the pad-to-register delay is the same
   -- in every build instead of whatever the router left over.
   --
   -- D and HREF move together, so everything downstream (byte phase, the
   -- end-of-line handling above) sees the same relationship as before, one
   -- half cycle later.
   input_reg: process(pclk)
   begin
      if rising_edge(pclk) then
         latched_d    <= d;
         latched_href <= href;
      end if;
   end process;
end Behavioral;
