----------------------------------------------------------------------------------
-- depth_engine_sad: mesin disparitas SAD 5x5 dengan uji keunikan dan uji
-- konsistensi kiri-kanan. Pengganti disparity_generator.vhd.
--
-- Padanan bit-per-bit dari engine_sw() di sw/tools/depth_sw.py (cost_volume +
-- wta), dijalankan pada citra yang ditranspos. Testbench di
-- hw/sim/depth_engine membandingkan keduanya piksel demi piksel.
--
-- GEOMETRI. Kalibrasi board ini menempatkan baseline di sumbu KOLOM sensor,
-- jadi pencarian berjalan sepanjang y. Mesin menyapu frame buffer dalam
-- "garis pindai":
--     garis  a = 0 .. LINES-1   (sensor x)
--     piksel b = 0 .. PIX-1     (sensor y)
-- dan alamat sensornya b*STRIDE + a. Frame buffer-nya BRAM beralamat bebas,
-- jadi transposisi ini hanya urutan alamat, bukan memori tambahan.
--
-- REKTIFIKASI. Piksel kanan untuk (a, b) diambil dari
-- (a + off_cross, b + off_base); di luar citra dibaca sebagai nol. Sama
-- dengan shift2d() di software. Keduanya port, bukan generic: susunan
-- kamera pernah berubah setelah kalibrasi, dan mengoreksinya tidak boleh
-- menuntut build bitstream.
--
-- ALUR PER GARIS
--   LOAD  : baca satu garis baru dari kedua frame buffer, geser masuk ke
--           "kata kolom" 20 bit per posisi b (5 piksel = 5 garis terakhir).
--           RAM uji kiri-kanan dikosongkan di lintasan yang sama.
--   PROC  : untuk tiap b dan tiap disparitas d, satu siklus:
--             cs  = jumlah |L - R| atas 5 garis di kolom pq = b+2
--             sad = sad + cs - cs(lima kolom sebelumnya)
--           Jendela 5x5 tidak pernah dijumlah ulang; hanya kolom yang masuk
--           dan keluar. Tanpa pengali.
--   PASS2 : uji kiri-kanan lalu tulis satu garis keluaran.
--
-- Siklus per frame pada 160x120, DMAX=40: ~0,8 juta. Pada 40 MHz itu ~20 ms.
--
-- KELUARAN. o_data = disparitas (DMIN..DMAX) atau 0 = tidak ada jawaban.
-- Semua LINES*PIX alamat ditulis tepat sekali per frame.
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity depth_engine_sad is
  generic (
    LINES     : positive := 160;  -- jumlah garis pindai (sensor x)
    PIX       : positive := 120;  -- piksel per garis pindai (sensor y), <= 128
    STRIDE    : positive := 160;  -- alamat sensor = y*STRIDE + x
    ADDR_W    : positive := 15;
    DMIN      : positive := 1;
    DMAX      : positive := 40;   -- <= 63
    UNIQ_DEN  : natural  := 8;    -- lolos bila (kedua - terbaik)*UNIQ_DEN >= terbaik; 0 = mati
    LRC_EN    : boolean  := true
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;   -- '1' saat diam memulai satu frame; boleh ditahan '1'

    -- Geser rektifikasi citra kanan, bertanda, dari register PS. Dicuplik
    -- sekali di awal tiap frame, jadi mengubahnya di tengah frame tidak
    -- merobek frame itu.
    off_base   : in  signed(7 downto 0);  -- di sumbu baseline (b)
    off_cross  : in  signed(3 downto 0);  -- di sumbu silang (a)

    -- frame buffer kiri/kanan: baca sinkron, data muncul satu siklus setelah alamat
    l_addr     : out std_logic_vector(ADDR_W-1 downto 0);
    l_data     : in  std_logic_vector(3 downto 0);
    r_addr     : out std_logic_vector(ADDR_W-1 downto 0);
    r_data     : in  std_logic_vector(3 downto 0);

    o_we       : out std_logic;
    o_addr     : out std_logic_vector(ADDR_W-1 downto 0);
    o_data     : out std_logic_vector(7 downto 0);

    busy       : out std_logic;
    frame_done : out std_logic    -- satu siklus, setelah alamat terakhir ditulis
  );
end depth_engine_sad;

architecture rtl of depth_engine_sad is

  constant WIN : positive := 5;
  constant H2  : positive := 2;

  subtype pix_t  is unsigned(3 downto 0);
  subtype cs_t   is unsigned(6 downto 0);   -- 5 * 15 = 75
  subtype cost_t is unsigned(8 downto 0);   -- 25 * 15 = 375
  subtype disp_t is unsigned(5 downto 0);

  -- Kata kolom: 5 piksel = 5 garis terakhir pada posisi b. Urutan garis di
  -- dalam kata tidak penting, karena hanya dijumlahkan.
  type col_ram_t  is array (0 to 127) of std_logic_vector(19 downto 0);
  type hist_ram_t is array (0 to 511) of cs_t;      -- alamat = slot*64 + d
  type sad_ram_t  is array (0 to 63)  of cost_t;
  type c_ram_t    is array (0 to 127) of cost_t;
  type d_ram_t    is array (0 to 127) of disp_t;
  type v_ram_t    is array (0 to 127) of std_logic;

  signal colL, colR : col_ram_t := (others => (others => '0'));
  signal hist       : hist_ram_t := (others => (others => '0'));
  signal sadram     : sad_ram_t := (others => (others => '0'));
  signal bestR_c    : c_ram_t := (others => (others => '0'));
  signal bestR_d    : d_ram_t := (others => (others => '0'));
  signal bestR_v    : v_ram_t := (others => '0');
  signal dL_d       : d_ram_t := (others => (others => '0'));
  signal dL_v       : v_ram_t := (others => '0');

  type state_t is (S_IDLE, S_LOAD, S_PROC, S_FLUSH, S_OUT, S_NEXT);
  signal state : state_t := S_IDLE;

  signal n_line : integer range 0 to LINES := 0;       -- garis yang sedang dimuat

  -- LOAD
  signal lb            : integer range 0 to PIX := 0;
  signal acc_l         : integer range 0 to 2**ADDR_W - 1 := 0;
  signal acc_r         : integer range -(2**(ADDR_W+1)) to 2**(ADDR_W+1) - 1 := 0;
  -- nilai geser yang berlaku untuk frame berjalan
  signal ob_r          : integer range -128 to 127 := 0;
  signal oc_r          : integer range -8 to 7 := 0;
  signal r_base        : integer range -(2**(ADDR_W+1)) to 2**(ADDR_W+1) - 1 := 0;
  signal v1, v2        : std_logic := '0';
  signal b1, b2        : integer range 0 to 127 := 0;
  signal rng1, rng2    : std_logic := '0';

  -- PROC
  signal pq   : integer range 0 to 127 := 0;
  signal pd   : integer range 0 to 63 := 0;
  signal slot : integer range 0 to WIN-1 := 0;         -- pq mod 5

  -- tahap 2
  signal s2_valid, s2_first : std_logic := '0';
  signal s2_cost            : cost_t := (others => '0');
  signal s2_d               : disp_t := (others => '0');
  signal s2_b               : integer range 0 to 127 := 0;

  -- Empat biaya terkecil piksel berjalan, terurut. Empat, bukan dua: biaya
  -- kedua harus berasal dari disparitas yang BUKAN tetangga pemenang, dan
  -- pemenang paling banyak punya dua tetangga, jadi kandidat itu selalu ada
  -- di antara empat terkecil.
  type t_c_arr is array (1 to 4) of cost_t;
  type t_d_arr is array (1 to 4) of disp_t;
  signal t_c   : t_c_arr := (others => (others => '0'));
  signal t_d   : t_d_arr := (others => (others => '0'));
  signal t_cnt : integer range 0 to 4 := 0;
  signal t_pix : integer range 0 to 127 := 0;

  signal flush_cnt : integer range 0 to 3 := 0;

  -- OUT
  signal ob        : integer range 0 to PIX := 0;
  signal out_line  : integer range 0 to LINES - 1 := 0;
  signal out_zero  : std_logic := '0';
  signal acc_o     : integer range 0 to 2**ADDR_W - 1 := 0;
  signal tail_zero : integer range 0 to H2 := 0;       -- garis nol penutup yang tersisa

  function absdiff(a, b : pix_t) return unsigned is
  begin
    if a >= b then return resize(a - b, 7); else return resize(b - a, 7); end if;
  end function;

  function col_sad(l, r : std_logic_vector(19 downto 0)) return cs_t is
    variable s : cs_t := (others => '0');
  begin
    for k in 0 to WIN-1 loop
      s := s + absdiff(unsigned(l(4*k+3 downto 4*k)), unsigned(r(4*k+3 downto 4*k)));
    end loop;
    return s;
  end function;

begin

  assert PIX <= 128 report "depth_engine_sad: PIX harus <= 128" severity failure;
  assert DMAX <= 63 and DMIN <= DMAX report "depth_engine_sad: 1 <= DMIN <= DMAX <= 63" severity failure;
  assert DMIN <= H2 report "depth_engine_sad: DMIN harus <= 2" severity failure;
  assert LINES > 2*H2 and PIX > 2*H2 + DMIN report "depth_engine_sad: citra terlalu kecil" severity failure;

  busy <= '0' when state = S_IDLE else '1';

  process(clk)
    variable q        : integer range 0 to 127;
    variable dmax_b   : integer range 0 to 63;
    variable cs       : cs_t;
    variable oldv     : cs_t;
    variable prev, nw : cost_t;
    variable haddr    : integer range 0 to 511;
    variable qr       : integer range 0 to 127;
    variable yr       : integer;
    variable xr       : integer;
    variable inr      : boolean;
    variable rpix     : std_logic_vector(3 downto 0);
    variable c        : cost_t;
    -- finalisasi piksel
    variable has2     : boolean;
    variable sec      : cost_t;
    variable dd       : integer;
    variable uok      : boolean;
    variable fin      : boolean;
    -- keluaran
    variable dl       : disp_t;
    variable dr       : disp_t;
    variable ok       : boolean;
    variable outv     : unsigned(7 downto 0);
    -- Satu port tulis untuk RAM uji kiri-kanan. Tahap 2 dan LOAD tidak
    -- pernah aktif bersamaan, tetapi dua pernyataan tulis terpisah akan
    -- disintesis sebagai dua port dan RAM-nya jatuh menjadi register.
    variable br_we    : boolean;
    variable br_a     : integer range 0 to 127;
    variable br_v     : std_logic;
    variable br_c     : cost_t;
    variable br_d     : disp_t;
  begin
    if rising_edge(clk) then
      o_we       <= '0';
      frame_done <= '0';
      fin        := false;
      br_we      := false;
      br_a       := 0;
      br_v       := '0';
      br_c       := (others => '0');
      br_d       := (others => '0');

      ------------------------------------------------------------------
      -- Tahap 2: selalu aktif, memproses butir yang dikeluarkan PROC.
      ------------------------------------------------------------------
      if s2_valid = '1' then
        -- Uji kiri-kanan: biaya terbaik per posisi di citra KANAN. Untuk
        -- posisi kanan tetap, butir datang dengan d menaik, jadi `<` yang
        -- ketat menyimpan d terkecil saat seri -- sama dengan argmin.
        qr := s2_b - to_integer(s2_d);
        if bestR_v(qr) = '0' or s2_cost < bestR_c(qr) then
          br_we := true;  br_a := qr;
          br_v  := '1';   br_c := s2_cost;  br_d := s2_d;
        end if;

        c := s2_cost;
        if s2_first = '1' then
          fin      := (t_cnt > 0);      -- piksel sebelumnya selesai
          t_c(1)   <= c;  t_d(1) <= s2_d;
          t_cnt    <= 1;
          t_pix    <= s2_b;
        else
          -- Sisip terurut. `<` ketat: d datang menaik, jadi pada biaya yang
          -- sama d yang lebih kecil tetap di depan.
          if c < t_c(1) then
            t_c(4) <= t_c(3); t_d(4) <= t_d(3);
            t_c(3) <= t_c(2); t_d(3) <= t_d(2);
            t_c(2) <= t_c(1); t_d(2) <= t_d(1);
            t_c(1) <= c;      t_d(1) <= s2_d;
          elsif t_cnt < 2 or c < t_c(2) then
            t_c(4) <= t_c(3); t_d(4) <= t_d(3);
            t_c(3) <= t_c(2); t_d(3) <= t_d(2);
            t_c(2) <= c;      t_d(2) <= s2_d;
          elsif t_cnt < 3 or c < t_c(3) then
            t_c(4) <= t_c(3); t_d(4) <= t_d(3);
            t_c(3) <= c;      t_d(3) <= s2_d;
          elsif t_cnt < 4 or c < t_c(4) then
            t_c(4) <= c;      t_d(4) <= s2_d;
          end if;
          if t_cnt < 4 then t_cnt <= t_cnt + 1; end if;
        end if;
      end if;
      s2_valid <= '0';

      ------------------------------------------------------------------
      -- Mesin keadaan
      ------------------------------------------------------------------
      case state is

        when S_IDLE =>
          if start = '1' then
            n_line <= 0;
            lb     <= 0;
            acc_l  <= 0;
            ob_r   <= to_integer(off_base);
            oc_r   <= to_integer(off_cross);
            r_base <= to_integer(off_base) * STRIDE + to_integer(off_cross);
            acc_r  <= to_integer(off_base) * STRIDE + to_integer(off_cross);
            state  <= S_LOAD;
          end if;

        ----------------------------------------------------------------
        when S_LOAD =>
          -- data untuk b2 sudah di bus: geser masuk ke kata kolom
          if v2 = '1' then
            colL(b2) <= colL(b2)(15 downto 0) & l_data;
            if rng2 = '1' then rpix := r_data; else rpix := "0000"; end if;
            colR(b2) <= colR(b2)(15 downto 0) & rpix;
            -- kosongkan RAM uji kiri-kanan untuk garis berikutnya
            br_we := true;  br_a := b2;
            br_v  := '0';   br_c := (others => '0');  br_d := to_unsigned(DMIN, 6);
          end if;
          v2 <= v1;  b2 <= b1;  rng2 <= rng1;

          if lb < PIX then
            yr  := lb + ob_r;
            xr  := n_line + oc_r;
            inr := (yr >= 0) and (yr < PIX) and (xr >= 0) and (xr < LINES);
            l_addr <= std_logic_vector(to_unsigned(acc_l, ADDR_W));
            if inr then
              r_addr <= std_logic_vector(to_unsigned(acc_r, ADDR_W));
              rng1   <= '1';
            else
              r_addr <= (others => '0');
              rng1   <= '0';
            end if;
            v1 <= '1';
            b1 <= lb;
            lb <= lb + 1;
            if lb < PIX - 1 then
              acc_l <= acc_l + STRIDE;
              acc_r <= acc_r + STRIDE;
            end if;
          else
            v1 <= '0';
            if v1 = '0' and v2 = '0' then
              -- garis n_line sudah masuk seluruhnya
              if n_line < H2 then
                -- garis tepi atas: tidak ada jendela penuh, keluarkan nol
                out_line <= n_line; out_zero <= '1';
                ob <= 0; acc_o <= n_line; tail_zero <= 0;
                state <= S_OUT;
              elsif n_line < 2*H2 then
                state <= S_NEXT;
              else
                pq <= DMIN; pd <= DMIN; slot <= DMIN mod WIN; t_cnt <= 0;
                state <= S_PROC;
              end if;
            end if;
          end if;

        ----------------------------------------------------------------
        when S_PROC =>
          -- pq = kolom kiri yang sedang masuk ke jendela; piksel pusatnya
          -- b = pq - 2. Sapuan dimulai dari pq = DMIN, bukan dari b = 0:
          -- kolom pertama yang punya pasangan kanan untuk disparitas d adalah
          -- pq = d, dan melewatkannya membuat jumlah berjalan untuk d itu
          -- salah di sepanjang garis.
          q := pq;
          if q < DMAX then dmax_b := q; else dmax_b := DMAX; end if;

          cs := col_sad(colL(q), colR(q - pd));

          haddr := slot * 64 + pd;
          if q >= pd + WIN then oldv := hist(haddr); else oldv := (others => '0'); end if;
          if q > pd then prev := sadram(pd); else prev := (others => '0'); end if;
          nw := prev + resize(cs, 9) - resize(oldv, 9);

          hist(haddr) <= cs;
          sadram(pd)  <= nw;

          -- jendela penuh hanya bila kolom kanan paling kiri (b-2-d) >= 0,
          -- yaitu pq >= d + 4
          if q >= pd + 2*H2 then
            s2_valid <= '1';
            s2_cost  <= nw;
            s2_d     <= to_unsigned(pd, 6);
            s2_b     <= q - H2;
            if pd = DMIN then s2_first <= '1'; else s2_first <= '0'; end if;
          end if;

          if pd = dmax_b then
            pd <= DMIN;
            if slot = WIN - 1 then slot <= 0; else slot <= slot + 1; end if;
            if q = PIX - 1 then
              flush_cnt <= 0;
              state     <= S_FLUSH;
            else
              pq <= q + 1;
            end if;
          else
            pd <= pd + 1;
          end if;

        ----------------------------------------------------------------
        when S_FLUSH =>
          -- siklus 0: butir terakhir sedang di tahap 2
          -- siklus 1: daftar empat-terkecil sudah final -> finalisasi
          if flush_cnt = 1 then
            fin       := (t_cnt > 0);
            out_line  <= n_line - H2; out_zero <= '0';
            ob <= 0; acc_o <= n_line - H2;
            if n_line = LINES - 1 then tail_zero <= H2; else tail_zero <= 0; end if;
            state <= S_OUT;
          end if;
          flush_cnt <= flush_cnt + 1;

        ----------------------------------------------------------------
        when S_OUT =>
          if ob < PIX then
            outv := (others => '0');
            if out_zero = '0' and ob >= DMIN + H2 and ob <= PIX - 1 - H2 then
              dl := dL_d(ob);
              ok := (dL_v(ob) = '1');
              if LRC_EN then
                dr := bestR_d(ob - to_integer(dl));
                dd := to_integer(dr) - to_integer(dl);
                if dd > 1 or dd < -1 then ok := false; end if;
              end if;
              if ok then outv := resize(dl, 8); end if;
            end if;
            o_we   <= '1';
            o_addr <= std_logic_vector(to_unsigned(acc_o, ADDR_W));
            o_data <= std_logic_vector(outv);
            ob     <= ob + 1;
            if ob < PIX - 1 then acc_o <= acc_o + STRIDE; end if;
          else
            if tail_zero > 0 then
              -- garis tepi bawah: LINES-H2 .. LINES-1
              out_line  <= LINES - tail_zero; out_zero <= '1';
              ob <= 0; acc_o <= LINES - tail_zero;
              tail_zero <= tail_zero - 1;
            else
              state <= S_NEXT;
            end if;
          end if;

        ----------------------------------------------------------------
        when S_NEXT =>
          if n_line = LINES - 1 then
            frame_done <= '1';
            state      <= S_IDLE;
          else
            n_line <= n_line + 1;
            lb     <= 0;
            acc_l  <= n_line + 1;
            acc_r  <= r_base + n_line + 1;
            state  <= S_LOAD;
          end if;

      end case;

      ------------------------------------------------------------------
      -- Finalisasi piksel t_pix dari daftar empat-terkecil (nilai register
      -- sebelum tepi clock ini).
      ------------------------------------------------------------------
      if fin then
        has2 := false;
        sec  := (others => '0');
        for k in 2 to 4 loop
          if not has2 and k <= t_cnt then
            dd := to_integer(t_d(k)) - to_integer(t_d(1));
            if dd > 1 or dd < -1 then
              has2 := true;
              sec  := t_c(k);
            end if;
          end if;
        end loop;
        if UNIQ_DEN = 0 then
          uok := true;
        else
          -- (kedua - terbaik) * UNIQ_DEN >= terbaik; tanpa kandidat kedua
          -- keunikan tidak bisa dinilai dan piksel ditolak.
          uok := has2 and
                 ((to_integer(sec) - to_integer(t_c(1))) * UNIQ_DEN >= to_integer(t_c(1)));
        end if;
        dL_d(t_pix) <= t_d(1);
        if uok then dL_v(t_pix) <= '1'; else dL_v(t_pix) <= '0'; end if;
      end if;

      if br_we then
        bestR_v(br_a) <= br_v;
        bestR_c(br_a) <= br_c;
        bestR_d(br_a) <= br_d;
      end if;

      if rst = '1' then
        state    <= S_IDLE;
        s2_valid <= '0';
        v1 <= '0'; v2 <= '0';
        t_cnt    <= 0;
        o_we     <= '0';
        frame_done <= '0';
      end if;
    end if;
  end process;

end rtl;
