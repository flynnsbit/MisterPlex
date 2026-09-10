--------------------------------------------------------------------------------
-- AVALON SCALER
--------------------------------------------------------------------------------
-- TEMLIB 2018 - 2020
--------------------------------------------------------------------------------
-- This code can be freely distributed and used for any purpose, but, if you
-- find any bug, or want to suggest an enhancement, you ought to send a mail
-- to info@temlib.org.
--------------------------------------------------------------------------------

-- Features
--  - Arbitrary output video format
--  - Autodetect input image size or fixed window
--  - Progressive and interlaced input
--  - Interpolation
--    Upscaling   : Nearest, Bilinear, Sharp Bilinear, Bicubic, Polyphase
--    Downscaling : Nearest, Bilinear
--  - Avalon bus interface with 128 or 64 bits DATA
--  - Optional triple buffering
--  - Support for external low lag syntonization

--------------------------------------------
-- Downscaling
-- - Horizontal and vertical up-/down-scaling are independant.
-- - Downscaling, H and/or V, supports only nearest-neighbour and bilinear
--   filtering.
-- - For interlaced video, when the vertical size is lower than a deinterlaced
--   frame size (2x half-frame), the scaler processes only half-frames
--   and upscales (when the output size is between 1x an 2x) or downscales (size
--   below 1x) them.

--------------------------------------------
-- 5 clock domains
--  i_xxx    : Input video
--  o_xxx    : Output video
--  avl_xxx  : Avalon memory bus
--  poly_xxx : Polyphase filters memory
--  pal_xxx  : Framebuffer mode 8bpp palette.

--------------------------------------------
-- O_FB_FORMAT : Framebuffer format
--  [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
--  [3]   : 0=16bits 565 1=16bits 1555
--  [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
--  [5]   : TBD

--------------------------------------------
-- Image header. When HEADER = TRUE
-- Header Address = RAMBASE
-- Image Address  = RAMBASE + HEADER_SIZE

-- Header (Bytes. Big Endian.)
--  0    : Type = 1
--  1    : Pixel format
--         0 : 16 bits/pixel, RGB : RRRRRGGGGGGBBBBB
--         1 : 24 bits/pixel, RGB
--         2 : 32 bits/pixel, RGB0

--  3:2  : Header size : Offset to start of picture (= N_BURST). 12 bits
--  5:4  : Attributes
--         b0 ; Interlaced
--         b1 : Field number
--         b2 : Horizontal downscaled
--         b3 : Vertical downscaled
--         b4 : Triple buffered
--       b7-5 : Frame counter
--  7:6  : Image width. Pixels. 12 bits
--  9:8  : Image height. Pixels. 12 bits
-- 11:10 : Line length. Bytes.
-- 13:12 : Output width. Pixels. 12 bits
-- 15:14 : Output height. Pixels. 12 bits
--------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

-- MODE[2:0]
-- 000 : Nearest
-- 001 : Bilinear
-- 010 : Sharp Bilinear
-- 011 : Bicubic
-- 100 : Polyphase
-- 101 : TBD
-- 110 : TBD
-- 111 : TBD

-- MODE[3]
-- 0 : Direct. Single framebuffer.
-- 1 : Triple buffering

-- MODE[4] : TBD

-- MASK      : Enable / Disable selected interpoler
--             0:Nearest 1:Bilinear 2:SharpBilinear 3:Bicubic 4:Polyphase
-- RAMBASE   : RAM base address for framebuffer
-- RAMSIZE   : RAM allocated for one framebuffer (needs x3 if triple-buffering)
--             Must be a power of two
-- INTER     : True=Autodetect interlaced video False=Force progressive scan
-- HEADER    : True=Add image properties header
-- PALETTE   : Enable palette for framebuffer 8bpp mode
-- PALETTE2  : Enable palette for framebuffer 8bpp mode supplied by core
-- DOWNSCALE : True=Support downscaling False=Downscaling disabled
-- BYTESWAP  : Little/Big endian byte swap
-- FRAC      : Fractional bits, subpixel resolution
-- OHRES     : Max. output horizontal resolution. 1024, 2048, 2304, 2560, 4096
--             (Used for sizing line buffers)
-- IHRES     : Max. input horizontal resolution. Must be a power of two.
--             (Used for sizing line buffers)
-- N_DW      : Avalon data bus width. 64 or 128 bits
-- N_AW      : Avalon address bus width
-- N_BURST   : Burst size in bytes. Power of two.

ENTITY ascal IS
	GENERIC (
		MASK         : unsigned(7 DOWNTO 0) :=x"FF";
		CONFIG_HANDSHAKE : boolean := false;
		RAMBASE      : unsigned(31 DOWNTO 0);
		RAMSIZE      : unsigned(31 DOWNTO 0) := x"0080_0000"; -- =8MB
		INTER        : boolean := true;
		HEADER       : boolean := true;
		DOWNSCALE    : boolean := true;
		BYTESWAP     : boolean := true;
		PALETTE      : boolean := true;
		PALETTE2     : boolean := true;
		ADAPTIVE     : boolean := true;
		DOWNSCALE_NN : boolean := false;
		FRAC         : natural RANGE 4 TO 8 :=4;
		OHRES        : natural RANGE 1 TO 4096 :=2304;
		IHRES        : natural RANGE 1 TO 2048 :=2048;
		N_DW         : natural RANGE 64 TO 128 := 128;
		N_AW         : natural RANGE 8 TO 32 := 32;
		N_BURST      : natural := 256 -- 256 bytes per burst
		);
	PORT (
		------------------------------------
		-- Input video
		i_r   : IN  unsigned(7 DOWNTO 0);
		i_g   : IN  unsigned(7 DOWNTO 0);
		i_b   : IN  unsigned(7 DOWNTO 0);
		i_hs  : IN  std_logic; -- H sync
		i_vs  : IN  std_logic; -- V sync
		i_fl  : IN  std_logic; -- Interlaced field
		i_de  : IN  std_logic; -- Display Enable
		i_ce  : IN  std_logic; -- Clock Enable
		i_clk : IN  std_logic; -- Input clock

		------------------------------------
		-- Output video
		o_r   : OUT unsigned(7 DOWNTO 0);
		o_g   : OUT unsigned(7 DOWNTO 0);
		o_b   : OUT unsigned(7 DOWNTO 0);
		o_hs  : OUT std_logic; -- H sync
		o_vs  : OUT std_logic; -- V sync
		o_de  : OUT std_logic; -- Display Enable
		o_vbl : OUT std_logic; -- V blank
		o_brd : OUT std_logic; -- border enable
		o_ce  : IN  std_logic; -- Clock Enable
		o_clk : IN  std_logic; -- Output clock
		-- Complete descriptor/REQ are produced on i_clk and held through ACK.
		cfg_data : IN unsigned(269 DOWNTO 0) := (OTHERS =>'0');
		cfg_req  : IN std_logic := '0';
		cfg_ack  : OUT std_logic := '0';
		cfg_pal_ready : IN std_logic := '0';
		cfg_pal_valid : IN std_logic := '0';
		cfg_pal_bank  : IN std_logic := '0';
		cfg_active : OUT std_logic := '0';

		-- Border colour R G B
		o_border   : IN unsigned(23 DOWNTO 0) := x"000000";

		------------------------------------
		-- Framebuffer mode
		o_fb_ena    : IN std_logic :='0'; -- Enable Framebuffer Mode
		o_fb_hsize  : IN natural RANGE 0 TO 4095 :=0;
		o_fb_vsize  : IN natural RANGE 0 TO 4095 :=0;
		o_fb_format : IN unsigned(5 DOWNTO 0) :="000100";
		o_fb_base   : IN unsigned(31 DOWNTO 0) :=x"0000_0000";
		o_fb_stride : IN unsigned(13 DOWNTO 0) :=(OTHERS =>'0');

		-- Framebuffer palette in 8bpp mode
		pal1_clk : IN std_logic :='0';
		pal1_dw  : IN unsigned(47 DOWNTO 0) :=x"000000000000"; -- R1 G1 B1 R0 G0 B0
		pal1_dr  : OUT unsigned(47 DOWNTO 0) :=x"000000000000";
		pal1_a   : IN unsigned(6 DOWNTO 0)  :="0000000"; -- Colour index/2
		pal1_wr  : IN std_logic :='0';
		pal1_bank : IN std_logic :='0';

		pal_n    : IN std_logic :='0';

		pal2_clk : IN std_logic :='0';
		pal2_dw  : IN unsigned(23 DOWNTO 0) :=x"000000"; -- R G B
		pal2_dr  : OUT unsigned(23 DOWNTO 0) :=x"000000";
		pal2_a   : IN unsigned(7 DOWNTO 0)  :="00000000"; -- Colour index
		pal2_wr  : IN std_logic :='0';

		------------------------------------
		-- Low lag PLL tuning
		o_lltune : OUT unsigned(15 DOWNTO 0);

		------------------------------------
		-- Input video parameters
		iauto : IN std_logic :='1'; -- 1=Autodetect image size 0=Choose window
		himin : IN natural RANGE 0 TO 4095 :=0; -- MIN < MAX, MIN >=0, MAX < DISP
		himax : IN natural RANGE 0 TO 4095 :=0;
		vimin : IN natural RANGE 0 TO 4095 :=0;
		vimax : IN natural RANGE 0 TO 4095 :=0;

		-- Detected input image size
		i_hdmax : OUT natural RANGE 0 TO 4095;
		i_vdmax : OUT natural RANGE 0 TO 4095;

		-- Output video parameters
		run       : IN std_logic :='1'; -- 1=Enable output image. 0=No image
		freeze    : IN std_logic :='0'; -- 1=Disable framebuffer writes
		mode      : IN unsigned(4 DOWNTO 0);
 		bob_deint : IN std_logic := '0';
		-- SYNC  |_________________________/"""""""""\_______|
		-- DE    |""""""""""""""""""\________________________|
		-- RGB   |    <#IMAGE#>      ^HDISP                  |
		--            ^HMIN   ^HMAX        ^HSSTART  ^HSEND  ^HTOTAL
		htotal  : IN natural RANGE 0 TO 4095;
		hsstart : IN natural RANGE 0 TO 4095;
		hsend   : IN natural RANGE 0 TO 4095;
		hdisp   : IN natural RANGE 0 TO 4095;
		hmin    : IN natural RANGE 0 TO 4095;
		hmax    : IN natural RANGE 0 TO 4095; -- 0 <= hmin < hmax < hdisp
		vtotal  : IN natural RANGE 0 TO 4095;
		vsstart : IN natural RANGE 0 TO 4095;
		vsend   : IN natural RANGE 0 TO 4095;
		vdisp   : IN natural RANGE 0 TO 4095;
		vmin    : IN natural RANGE 0 TO 4095;
		vmax    : IN natural RANGE 0 TO 4095; -- 0 <= vmin < vmax < vdisp
		vrr     : IN std_logic := '0';
		vrrmax  : IN natural RANGE 0 TO 4095 := 0;
		swblack : IN std_logic := '0';        -- will output 3 black frame on every resolution switch

		-- Scaler format. 00=16bpp 565, 01=24bpp 10=32bpp
		format  : IN unsigned(1 DOWNTO 0) :="01";

		------------------------------------
		-- Polyphase filter coefficients
		-- Order :
		--   [Horizontal] [Vertical] [Horizontal2] [Vertical2]
		--   [0]...[2**FRAC-1]
		--   [-1][0][1][2]
		poly_clk : IN std_logic;
		poly_dw  : IN unsigned(9 DOWNTO 0);
		poly_a   : IN unsigned(FRAC+3 DOWNTO 0);
		poly_wr  : IN std_logic;

		------------------------------------
		-- Avalon
		avl_clk            : IN    std_logic; -- Avalon clock
		avl_waitrequest    : IN    std_logic;
		avl_readdata       : IN    std_logic_vector(N_DW-1 DOWNTO 0);
		avl_readdatavalid  : IN    std_logic;
		avl_burstcount     : OUT   std_logic_vector(7 DOWNTO 0);
		avl_writedata      : OUT   std_logic_vector(N_DW-1 DOWNTO 0);
		avl_address        : OUT   std_logic_vector(N_AW-1 DOWNTO 0);
		avl_write          : OUT   std_logic;
		avl_read           : OUT   std_logic;
		avl_byteenable     : OUT   std_logic_vector(N_DW/8-1 DOWNTO 0);

		------------------------------------
		reset_na           : IN    std_logic
		);

BEGIN
	ASSERT N_DW=64 OR N_DW=128 REPORT "DW" SEVERITY failure;
	
	ASSERT OHRES = 1024 OR OHRES = 2048 OR OHRES = 2304 OR
	       OHRES = 2560 OR OHRES = 4096 REPORT "OHRES" SEVERITY failure;

END ENTITY ascal;

--##############################################################################

ARCHITECTURE rtl OF ascal IS

	CONSTANT MASK_NEAREST        : natural :=0;
	CONSTANT MASK_BILINEAR       : natural :=1;
	CONSTANT MASK_SHARP_BILINEAR : natural :=2;
	CONSTANT MASK_BICUBIC        : natural :=3;
	CONSTANT MASK_POLY           : natural :=4;

	----------------------------------------------------------
	FUNCTION ilog2 (CONSTANT v : natural) RETURN natural IS
		VARIABLE r : natural := 1;
		VARIABLE n : natural := 0;
	BEGIN
		WHILE v>r LOOP
			n:=n+1;
			r:=r*2;
		END LOOP;
		RETURN n;
	END FUNCTION ilog2;
	FUNCTION to_std_logic (a : boolean) RETURN std_logic IS
	BEGIN
		IF a THEN RETURN '1';
		ELSE RETURN '0';
		END IF;
	END FUNCTION to_std_logic;

	----------------------------------------------------------
	FUNCTION ohres_h(CONSTANT r : natural) RETURN natural IS
	BEGIN
		CASE r IS
			WHEN 1024   => RETURN 1024;
			WHEN 2048   => RETURN 2048;
			WHEN OTHERS => RETURN 4096;
		END CASE;
	END FUNCTION;
	FUNCTION ohres_l(CONSTANT r : natural) RETURN natural IS
	BEGIN
		CASE r IS
			WHEN 1024               => RETURN 1024;
			WHEN 2048 | 2304 | 2560 => RETURN 2048;
			WHEN OTHERS             => RETURN 4096;
		END CASE;
	END FUNCTION;
	FUNCTION ohres_m(CONSTANT r : natural) RETURN natural IS
	BEGIN
		CASE r IS
			WHEN 1024 | 2048 | 2304 => RETURN 256;
			WHEN OTHERS             => RETURN 512;
		END CASE;
	END FUNCTION;
	
	CONSTANT OHRESH : natural := ohres_h(OHRES);
	CONSTANT OHRESL : natural := ohres_l(OHRES);
	CONSTANT OHRESM : natural := ohres_m(OHRES);

	----------------------------------------------------------
	CONSTANT NB_BURST : natural :=ilog2(N_BURST);
	CONSTANT NB_LA    : natural :=ilog2(N_DW/8); -- Low address bits
	CONSTANT BLEN     : natural :=N_BURST / N_DW * 8; -- Burst length

	----------------------------------------------------------
	TYPE arr_dw IS  ARRAY (natural RANGE <>) OF unsigned(N_DW-1 DOWNTO 0);

	TYPE type_pix IS RECORD
		r,g,b : unsigned(7 DOWNTO 0); -- 0.8
	END RECORD;
	TYPE arr_pix IS ARRAY (natural RANGE <>) OF type_pix;
	TYPE arr_pixq IS ARRAY(natural RANGE <>) OF arr_pix(0 TO 3);
	ATTRIBUTE ramstyle : string;

	SUBTYPE uint12 IS natural RANGE 0 TO 4095;
	SUBTYPE uint13 IS natural RANGE 0 TO 8191;

	TYPE arr_uv48 IS ARRAY (natural RANGE <>) OF unsigned(47 DOWNTO 0);
	TYPE arr_uv24 IS ARRAY (natural RANGE <>) OF unsigned(23 DOWNTO 0);
	TYPE arr_uv40 IS ARRAY (natural RANGE <>) OF unsigned(39 DOWNTO 0);
	TYPE arr_int9 IS ARRAY (natural RANGE <>) OF integer RANGE -256 TO 255;
	TYPE arr_uint12 IS ARRAY (natural RANGE <>) OF uint12;
	TYPE arr_frac IS ARRAY (natural RANGE <>) OF unsigned(11 DOWNTO 0);
	TYPE arr_div IS ARRAY (natural RANGE <>) OF unsigned(20 DOWNTO 0);

	----------------------------------------------------------
	-- Input image
	SIGNAL i_pvs,i_pfl,i_pde,i_pce : std_logic;
	SIGNAL i_ppix : type_pix;
	SIGNAL i_freeze : std_logic;
	SIGNAL i_bob_deint : std_logic;
	SIGNAL i_count : unsigned(2 DOWNTO 0);
	SIGNAL i_hsize,i_hmin,i_hmax,i_hcpt : uint12;
	SIGNAL i_hrsize,i_vrsize : uint12;
	SIGNAL i_himax,i_vimax : uint12;
	SIGNAL i_vsize,i_vmaxmin,i_vmin,i_vmax,i_vcpt : uint12;
	SIGNAL i_iauto : std_logic;
	SIGNAL i_mode : unsigned(4 DOWNTO 0);
	SIGNAL i_format : unsigned(1 DOWNTO 0);
	SIGNAL i_ven,i_sof : std_logic;
	SIGNAL i_wr : std_logic;
	SIGNAL i_divstart,i_divrun : std_logic;
	SIGNAL i_de_pre,i_vs_pre,i_fl_pre : std_logic;
	SIGNAL i_de_delay : natural RANGE 0 TO 31;
	SIGNAL i_intercnt : natural RANGE 0 TO 3;
	SIGNAL i_inter,i_half,i_flm : std_logic;
	SIGNAL i_wfl : std_logic_vector(2 DOWNTO 0);
	SIGNAL i_write : std_logic := '0';
	SIGNAL i_wreq,i_alt,i_line,i_wline,i_wline_mem : std_logic;
	SIGNAL i_walt,i_walt_mem,i_wreq_mem : std_logic := '0';
	SIGNAL i_wdelay : natural RANGE 0 TO 7;
	SIGNAL i_push,i_pushend,i_pushend2 : std_logic;
	SIGNAL i_eol : std_logic;
	SIGNAL i_pushhead,i_pushhead2,i_pushhead3 : std_logic;
	SIGNAL i_hburst,i_hbcpt : natural RANGE 0 TO 31;
	SIGNAL i_shift : unsigned(0 TO 119) := (OTHERS =>'0');
	SIGNAL i_head : unsigned(127 DOWNTO 0);
	SIGNAL i_acpt : natural RANGE 0 TO 15;
	SIGNAL i_dpram : arr_dw(0 TO BLEN*2-1);
	ATTRIBUTE ramstyle OF i_dpram : SIGNAL IS "no_rw_check";
	SIGNAL i_endframe0,i_endframe1,i_vss : std_logic;
	SIGNAL i_wad : natural RANGE  0 TO BLEN*2-1;
	SIGNAL i_dw : unsigned(N_DW-1 DOWNTO 0);
	SIGNAL i_adrs,i_adrsi,i_wadrs,i_wadrs_mem : unsigned(31 DOWNTO 0);
	SIGNAL i_reset_na : std_logic;
	SIGNAL i_reset_meta,o_reset_meta,avl_reset_meta : std_logic := '0';
	SIGNAL i_hnp,i_vnp : std_logic;
	SIGNAL i_mem : arr_pix(0 TO IHRES-1); -- Downscale line buffer
	ATTRIBUTE ramstyle OF i_mem : SIGNAL IS "no_rw_check";
	SIGNAL i_ohsize,i_ovsize : uint12;
	SIGNAL i_vdivi   : unsigned(12 DOWNTO 0);
	SIGNAL i_vdivr   : unsigned(24 DOWNTO 0);
	SIGNAL i_div     : unsigned(16 DOWNTO 0);
	SIGNAL i_dir     : unsigned(11 DOWNTO 0);
	SIGNAL i_h_frac,i_v_frac : unsigned(11 DOWNTO 0);
	SIGNAL i_hacc,i_vacc     : uint13;
	SIGNAL i_hdown,i_vdown   : std_logic;
	SIGNAL i_divcpt : natural RANGE 0 TO 36;
	SIGNAL i_lwad,i_lrad : natural RANGE 0 TO OHRESH-1;
	SIGNAL i_lwr,i_bil : std_logic;
	SIGNAL i_ldw,i_ldrm : type_pix;
	SIGNAL i_hpixp,i_hpix0,i_hpix1,i_hpix2,i_hpix3,i_hpix4 : type_pix;
	SIGNAL i_hpix,i_pix : type_pix;
	SIGNAL i_hnp1,i_hnp2,i_hnp3,i_hnp4 : std_logic;
	SIGNAL i_ven1,i_ven2,i_ven3,i_ven4,i_ven5,i_ven6 : std_logic;
	SIGNAL i_capture_allow,i_write_conflict,i_queue_conflict : std_logic := '0';
	SIGNAL i_frame_active,i_frame_drain,i_frame_bad,i_native_delivered : std_logic := '0';
	SIGNAL i_field_seen : unsigned(1 DOWNTO 0) := "00";
	SIGNAL i_frame_context : unsigned(63 DOWNTO 0) := (OTHERS =>'0');
	SIGNAL i_native_context : unsigned(36 DOWNTO 0) := (OTHERS =>'0');
	SIGNAL i_native_req,i_native_ack_meta,i_native_ack_sync : std_logic := '0';
	SIGNAL i_native_ack_seen : std_logic := '0';
	SIGNAL i_native_release : unsigned(2 DOWNTO 0) := "000";
	SIGNAL i_epoch_meta,i_epoch_sync,i_epoch_seen : std_logic := '0';
	SIGNAL i_stream_meta,i_stream_sync : std_logic := '0';
	SIGNAL i_write_done_meta,i_write_done_sync : std_logic := '0';
	SIGNAL i_capture_bank,i_wbuf,i_wbuf_mem : natural RANGE 0 TO 2 := 0;

	----------------------------------------------------------
	-- Avalon
	TYPE type_avl_state IS (sIDLE,sWRITE,sREAD_ADDR,sREAD_SET,sREAD);
	SIGNAL avl_state : type_avl_state := sIDLE;
	SIGNAL avl_write_i,avl_write_sync,avl_write_sync2 : std_logic := '0';
	SIGNAL avl_write_sync3,avl_write_done : std_logic := '0';
	SIGNAL avl_wbuf : natural RANGE 0 TO 2 := 0;
	SIGNAL avl_read_i,avl_read_sync,avl_read_sync2 : std_logic := '0';
	SIGNAL avl_read_pulse,avl_write_pulse : std_logic := '0';
	SIGNAL avl_read_sr,avl_write_sr,avl_read_clr,avl_write_clr : std_logic := '0';
	SIGNAL avl_rad,avl_rad_c : natural RANGE 0 TO 2*BLEN-1;
	SIGNAL avl_wad : natural RANGE 0 TO 2*BLEN-1 := 2*BLEN-1;
	SIGNAL avl_walt,avl_wline,avl_rline : std_logic;
	SIGNAL avl_dw,avl_dr : unsigned(N_DW-1 DOWNTO 0);
	SIGNAL avl_wr : std_logic := '0';
	SIGNAL avl_readdataack,avl_readack : std_logic := '0';
	SIGNAL avl_radrs,avl_wadrs : unsigned(31 DOWNTO 0);
	SIGNAL avl_read_low : unsigned(16 DOWNTO 0);
	SIGNAL avl_read_high : unsigned(15 DOWNTO 0);
	SIGNAL avl_i_offset0,avl_o_offset0 : unsigned(31 DOWNTO 0);
	SIGNAL avl_i_offset1,avl_o_offset1 : unsigned(31 DOWNTO 0);
	SIGNAL avl_reset_na : std_logic;
	SIGNAL avl_o_vs_sync,avl_o_vs : std_logic;
	SIGNAL avl_fb_ena : std_logic;

	FUNCTION buf_next(a,b : natural RANGE 0 TO 2; freeze : std_logic := '0') RETURN natural IS
	BEGIN
		IF (freeze='1') THEN RETURN a; END IF;
		IF (a=0 AND b=1) OR (a=1 AND b=0) THEN RETURN 2; END IF;
		IF (a=1 AND b=2) OR (a=2 AND b=1) THEN RETURN 0; END IF;
		RETURN 1;
	END FUNCTION;
	FUNCTION buf_offset(b : natural RANGE 0 TO 2;
								base : unsigned(31 DOWNTO 0);
								size : unsigned(31 DOWNTO 0)) RETURN unsigned IS
	BEGIN
		IF b=1 THEN RETURN base+size; END IF;
		IF b=2 THEN RETURN base+(size(30 DOWNTO 0) & '0'); END IF;
		RETURN base;
	END FUNCTION;
	FUNCTION native_next(a,b : natural RANGE 0 TO 2) RETURN natural IS
	BEGIN
		FOR bank IN 0 TO 2 LOOP
			IF bank/=a AND bank/=b THEN RETURN bank; END IF;
		END LOOP;
		RETURN 0;
	END FUNCTION;

	----------------------------------------------------------
	-- Output
	SIGNAL o_run : std_logic;
	SIGNAL o_native_meta,o_native_sync,o_native_ack : std_logic := '0';
	SIGNAL o_native_capture : unsigned(36 DOWNTO 0) := (OTHERS =>'0');
	SIGNAL o_native_pending,o_native_phase : std_logic := '0';
	SIGNAL o_native_announced : std_logic := '0';
	SIGNAL o_native_epoch,o_native_reset_seen,o_native_valid,o_native_stream : std_logic := '0';
	SIGNAL o_epoch_meta,o_epoch_sync,o_native_refresh,o_native_epoch_wait : std_logic := '0';
	SIGNAL o_native_release : unsigned(2 DOWNTO 0) := "000";
	SIGNAL o_native_math_valid : unsigned(3 DOWNTO 0) := "0000";
	SIGNAL o_cfg_epoch : std_logic := '0';
	SIGNAL o_native_format : unsigned(1 DOWNTO 0) := "00";
	SIGNAL o_freeze : std_logic;
	SIGNAL o_bob_deint : std_logic;
	SIGNAL o_iwfl : std_logic_vector(2 DOWNTO 0);
	SIGNAL o_mode,o_hmode,o_vmode : unsigned(4 DOWNTO 0);
	SIGNAL o_format : unsigned(5 DOWNTO 0);
	SIGNAL o_fb_pal_dr : unsigned(23 DOWNTO 0);
	SIGNAL o_fb_pal_dr2 : unsigned(23 DOWNTO 0);
	SIGNAL o_fb_pal_dr_x2 : unsigned(47 DOWNTO 0);
	SIGNAL pal_idx: unsigned(7 DOWNTO 0);
	SIGNAL pal_idx_lsb: std_logic;
	SIGNAL pal1_mem : arr_uv48(0 TO 127+128*boolean'pos(CONFIG_HANDSHAKE));
	SIGNAL pal2_mem : arr_uv24(0 TO 255);
	ATTRIBUTE ramstyle of pal1_mem : signal is "no_rw_check";
	ATTRIBUTE ramstyle of pal2_mem : signal is "no_rw_check";
	SIGNAL o_htotal,o_hsstart,o_hsend : uint12;
	SIGNAL o_hmin,o_hmax,o_hdisp,o_v_hmin_adj : uint12;
	SIGNAL o_hsize,o_vsize : uint12;
	SIGNAL o_vtotal,o_vsstart,o_vsend : uint12;
	SIGNAL o_vrr,o_isync,o_isync2 : std_logic;
	SIGNAL o_vrr_sync,o_vrr_sync2 : boolean;
	SIGNAL o_vrr_min,o_vrr_min2 : boolean;
	SIGNAL o_vrr_max,o_vrr_max2 : boolean;
	SIGNAL o_vcpt_sync,o_vcpt_sync2, o_vrrmax : uint12;
	SIGNAL o_sync, o_sync_max : boolean;
	SIGNAL o_vmin,o_vmax,o_vdisp : uint12;
	SIGNAL o_divcpt : natural RANGE 0 TO 36;
	SIGNAL o_iendframe0,o_iendframe02,o_iendframe1,o_iendframe12 : std_logic;
	SIGNAL o_bufup0,o_bufup1,o_inter : std_logic;
	SIGNAL o_ibuf0,o_ibuf1,o_obuf0,o_obuf1 : natural RANGE 0 TO 2;
	TYPE enum_o_state IS (sDISP,sHSYNC,sREAD,sWAITREAD);
	SIGNAL o_state : enum_o_state;
	TYPE enum_o_copy IS (sWAIT,sSHIFT,sCOPY);
	SIGNAL o_copy : enum_o_copy;
	SIGNAL o_pshift : natural RANGE 0 TO 15;
	SIGNAL o_readack,o_readack_sync,o_readack_sync2 : std_logic := '0';
	SIGNAL o_readdataack,o_readdataack_sync,o_readdataack_sync2 : std_logic := '0';
	SIGNAL o_copyv : unsigned(0 TO 14);
	SIGNAL o_adrs : unsigned(31 DOWNTO 0); -- Avalon address
	SIGNAL o_adrs_pre : natural RANGE 0 TO 2**24-1;
	SIGNAL o_stride : unsigned(13 DOWNTO 0);
	SIGNAL o_adrsa,o_adrsb,o_rline : std_logic;
	SIGNAL o_ad,o_ad1,o_ad2,o_ad3 : natural RANGE 0 TO 2*BLEN-1;
	SIGNAL o_adturn : std_logic;
	SIGNAL o_dr : unsigned(N_DW-1 DOWNTO 0);
	SIGNAL o_shift : unsigned(0 TO N_DW+15);
	SIGNAL o_sh,o_sh1,o_sh2,o_sh3,o_sh4 : std_logic;
	SIGNAL o_reset_na : std_logic;
	SIGNAL cfg_req_meta,cfg_req_sync,cfg_ack_i,cfg_pending,cfg_initialized : std_logic := '0';
	SIGNAL i_cfg_initialized : std_logic := '0';
	SIGNAL pal_ready_meta,pal_ready_sync,pal_valid_meta,pal_valid_sync,o_palette_bank : std_logic := '0';
	SIGNAL cfg_capture,o_cfg_active : unsigned(269 DOWNTO 0) := (OTHERS =>'0');
	SIGNAL cfg_apply : std_logic;
	SIGNAL o_bootstrap,o_prime_started : std_logic := '0';
	SIGNAL o_prime_ready : std_logic;
	ATTRIBUTE preserve : boolean;
	ATTRIBUTE preserve OF cfg_req_meta,cfg_req_sync,cfg_capture : SIGNAL IS true;
	ATTRIBUTE preserve OF pal_ready_meta,pal_ready_sync,pal_valid_meta,pal_valid_sync : SIGNAL IS true;
	SIGNAL c_fb_ena,c_pal_n,c_swblack : std_logic;
	SIGNAL c_fb_hsize,c_fb_vsize : uint12;
	SIGNAL c_fb_format : unsigned(5 DOWNTO 0);
	SIGNAL c_fb_base : unsigned(31 DOWNTO 0);
	SIGNAL c_fb_stride : unsigned(13 DOWNTO 0);
	SIGNAL c_border : unsigned(23 DOWNTO 0);
	SIGNAL o_read_base,avl_read_base : unsigned(31 DOWNTO 0);
	SIGNAL avl_read_sync3,o_readack_sync3,o_readdataack_sync3 : std_logic := '0';
	-- Two burst completions may accumulate while o_clk is stopped. A toggle
	-- loses both; modulo-four Gray credits retain them without resetting phase.
	SIGNAL avl_completed,avl_completed_gray : unsigned(1 DOWNTO 0) := "00";
	SIGNAL o_completed_meta,o_completed_sync,o_completed_seen : unsigned(1 DOWNTO 0) := "00";
	ATTRIBUTE preserve OF avl_completed_gray,o_completed_meta,o_completed_sync : SIGNAL IS true;
	ATTRIBUTE preserve OF cfg_ack_i,cfg_initialized,o_cfg_active,o_palette_bank,
		o_read_base,avl_read_base,avl_read_sync,avl_read_sync2,
		o_readack_sync,o_readack_sync2,o_readdataack_sync,o_readdataack_sync2 : SIGNAL IS true;
	SIGNAL o_dpram : arr_dw(0 TO BLEN*2-1);
	ATTRIBUTE ramstyle OF o_dpram : SIGNAL IS "no_rw_check";
	SIGNAL o_line0,o_line1,o_line2,o_line3 : arr_pix(0 TO OHRESL-1);
	SIGNAL o_linf0,o_linf1,o_linf2,o_linf3 : arr_pix(0 TO OHRESM-1);

	ATTRIBUTE ramstyle OF o_line0 : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_line1 : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_line2 : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_line3 : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_linf0 : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_linf1 : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_linf2 : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_linf3 : SIGNAL IS "no_rw_check";	
	SIGNAL o_wadl,o_radl0,o_radl1,o_radl2,o_radl3 : natural RANGE 0 TO OHRESH-1;
	SIGNAL o_ldr0,o_ldr1,o_ldr2,o_ldr3,o_ldw : type_pix;
	SIGNAL o_ler0,o_ler1,o_ler2,o_ler3       : type_pix;
	SIGNAL o_lex0,o_lex1,o_lex2,o_lex3       : std_logic;
	SIGNAL o_wr : unsigned(3 DOWNTO 0);
	SIGNAL o_hcpt,o_vcpt,o_vcpt_pre,o_vcpt_pre2,o_vcpt_pre3,o_vcpt2 : uint12;
	SIGNAL o_ihsize,o_ihsizem,o_ivsize : uint12;
	SIGNAL o_ihsize_temp, o_ihsize_temp2 : natural RANGE 0 TO 32767;

	SIGNAL o_vfrac : unsigned(11 DOWNTO 0);
	SIGNAL o_hfrac : arr_frac(0 TO 9);
	ATTRIBUTE ramstyle OF o_hfrac : SIGNAL IS "logic"; -- avoid blockram shift register

	SIGNAL o_hacc,o_hacc_ini,o_hacc_next,o_vacc,o_vacc_next,o_vacc_ini : natural RANGE 0 TO 4*OHRESH-1;
	SIGNAL o_hsv,o_vsv,o_dev,o_pev,o_end : unsigned(0 TO 11);
	SIGNAL o_hsp,o_vss : std_logic;
	SIGNAL o_vcarrym,o_prim : boolean;
	SIGNAL o_read,o_read_pre : std_logic := '0';
	SIGNAL o_readlev,o_copylev : natural RANGE 0 TO 2 := 0;
	SIGNAL o_hbcpt : natural RANGE 0 TO 31;
	SIGNAL o_hburst_last : integer RANGE -1 TO 30;
	SIGNAL o_fload : natural RANGE 0 TO 3;
	SIGNAL o_acpt,o_acpt1,o_acpt2,o_acpt3,o_acpt4 : natural RANGE 0 TO 15; -- Alternance pixels FIFO
	SIGNAL o_dshi : natural RANGE 0 TO 3;
	SIGNAL o_first,o_last,o_last1,o_last2 : std_logic;
	SIGNAL o_lastt1,o_lastt2,o_lastt3,o_lastt4 : std_logic;
	SIGNAL o_alt,o_altx : unsigned(3 DOWNTO 0);
	SIGNAL o_hdown,o_vdown : std_logic;
	ATTRIBUTE preserve OF i_native_context,i_native_req,i_native_ack_meta,
		i_native_ack_sync,i_native_release,i_epoch_meta,i_epoch_sync,i_epoch_seen,
		i_stream_meta,i_stream_sync,i_write_done_meta,i_write_done_sync,
		i_write,i_wadrs,i_walt,i_wline,i_wbuf,avl_write_sync,avl_write_sync2,
		avl_write_sync3,avl_write_done,avl_wadrs,avl_walt,avl_wline,avl_wbuf,
		o_native_meta,o_native_sync,o_native_ack,o_native_release,
		o_native_epoch,o_epoch_meta,o_epoch_sync,o_native_stream,o_native_valid,
		o_native_capture : SIGNAL IS true;
	SIGNAL o_primv,o_lastv,o_bibv : unsigned(0 TO 2);
	TYPE arr_uint4 IS ARRAY (natural RANGE <>) OF natural RANGE 0 TO 15;
	SIGNAL o_off : arr_uint4(0 TO 2);
	SIGNAL o_altv : arr_uint4(0 TO 2);
	SIGNAL o_bibu : std_logic :='0';
	SIGNAL o_dcptv : arr_uint12(13 TO 14);
	SIGNAL o_dcpt_clr, o_dcpt_inc : std_logic;
	SIGNAL o_dcptv_clr, o_dcptv_inc : std_logic_vector(1 TO 12);
	SIGNAL o_hpixs,o_hpix0,o_hpix1,o_hpix2,o_hpix3 : type_pix;
	SIGNAL o_hpixq : arr_pixq(2 TO 8);
	ATTRIBUTE ramstyle OF o_hpixq : SIGNAL IS "logic"; -- avoid blockram shift register
	SIGNAL o_vpixq, o_vpixq_pre : arr_pix(0 TO 3);
	SIGNAL o_vpix_past, o_vpix_last : boolean;
	SIGNAL o_vpix_outer : arr_pix(0 TO 2);
	SIGNAL o_vpix_inner : arr_pix(0 TO 6);

	SIGNAL o_vpe : std_logic;
	SIGNAL o_div : arr_div(0 TO 2); --uint12;
	SIGNAL o_dir : arr_frac(0 TO 2);
	ATTRIBUTE ramstyle OF o_div, o_dir : SIGNAL IS "logic"; -- avoid blockram shift register
	SIGNAL o_vdivi : unsigned(12 DOWNTO 0);
	SIGNAL o_vdivr : unsigned(24 DOWNTO 0);
	SIGNAL o_divstart : std_logic;
	SIGNAL o_divrun : std_logic;
	SIGNAL o_hacpt,o_vacpt : unsigned(11 DOWNTO 0);
	SIGNAL o_vacptl : unsigned(1 DOWNTO 0);
	signal o_newres : integer range 0 to 3;

	-----------------------------------------------------------------------------
	FUNCTION shift_ishift(shift : unsigned(0 TO 119);
												pix   : type_pix;
												format : unsigned(1 DOWNTO 0)) RETURN unsigned IS
	BEGIN
		CASE format IS
			WHEN "01" => -- 24bpp
				RETURN shift(24 TO 119) & pix.r & pix.g & pix.b;
			WHEN "10" => -- 32bpp
				RETURN shift(32 TO 119) & pix.r & pix.g & pix.b & x"00";
			WHEN OTHERS => -- 16bpp 565
				RETURN shift(16 TO 119) &
					pix.g(4 DOWNTO 2) & pix.r(7 DOWNTO 3) &
					pix.b(7 DOWNTO 3) & pix.g(7 DOWNTO 5);
		END CASE;
	END FUNCTION;

	FUNCTION shift_ipack(i_dw   : unsigned(N_DW-1 DOWNTO 0);
	                     acpt   : natural RANGE 0 TO 15;
	                     shift  : unsigned(0 TO 119);
	                     pix    : type_pix;
	                     format : unsigned(1 DOWNTO 0)) RETURN unsigned IS
		VARIABLE dw : unsigned(N_DW-1 DOWNTO 0);
	BEGIN
		dw:=i_dw;
		CASE format IS
			WHEN "01" => -- 24bpp
				IF N_DW=128 THEN
					IF    acpt=5 THEN  dw:=shift(0 TO 119) & pix.r;
					ELSIF acpt=10 THEN dw:=shift(8 TO 119) & pix.r & pix.g;
					ELSIF acpt=15 THEN dw:=shift(16 TO 119) & pix.r & pix.g & pix.b;
					END IF;
				ELSE -- N_DW=64
					IF    (acpt MOD 8)=2 THEN dw:=shift(72 TO 119) & pix.r & pix.g;
					ELSIF (acpt MOD 8)=5 THEN dw:=shift(64 TO 119) & pix.r;
					ELSIF (acpt MOD 8)=7 THEN dw:=shift(80 TO 119) & pix.r & pix.g & pix.b;
					END IF;
				END IF;
			WHEN "10" => -- 32bpp
				IF (N_DW=128 AND (acpt MOD 4)=3) OR (N_DW=64 AND (acpt MOD 8)=7) THEN
					dw:=shift(128-N_DW+24 TO 119) & pix.r & pix.g & pix.b & x"00";
				END IF;
			WHEN OTHERS => -- 16bpp 565
				IF (N_DW=128 AND (acpt MOD 8)=7) OR (N_DW=64 AND (acpt MOD 4)=3) THEN
					dw:=shift(128-N_DW+8 TO 119) & pix.g(4 DOWNTO 2) & pix.r(7 DOWNTO 3) &
							 pix.b(7 DOWNTO 3) & pix.g(7 DOWNTO 5);
				END IF;
		END CASE;
		RETURN dw;
	END FUNCTION;

	FUNCTION shift_inext (acpt   : natural RANGE 0 TO 15;
								 format : unsigned(1 DOWNTO 0)) RETURN boolean IS
	BEGIN
		CASE format IS
			WHEN "01" => -- 24bpp
				RETURN (N_DW=128 AND (acpt=5 OR acpt=10 OR acpt=15)) OR
						 (N_DW=64  AND ((acpt MOD 8)=2 OR (acpt MOD 8)=5 OR (acpt MOD 8)=7));
			WHEN "10" => -- 32bpp
				RETURN (N_DW=128 AND ((acpt MOD 4)=3)) OR
						 (N_DW=64  AND ((acpt MOD 2)=1));
			WHEN OTHERS => -- 16bpp
				RETURN (N_DW=128 AND ((acpt MOD 8)=7)) OR
						 (N_DW=64  AND ((acpt MOD 4)=3));
		END CASE;
	END FUNCTION;

	FUNCTION shift_opack(acpt   : natural RANGE 0 TO 15;
								shift  : unsigned(0 TO N_DW+15);
								dr     : unsigned(N_DW-1 DOWNTO 0);
								format : unsigned(5 DOWNTO 0)) RETURN unsigned IS
		VARIABLE shift_v : unsigned(0 TO N_DW+15);
	BEGIN
		CASE format(2 DOWNTO 0) IS
			WHEN "011" => -- 8bpp
				IF (N_DW=128 AND acpt=0) OR (N_DW=64 AND (acpt MOD 8)=0) THEN
					shift_v:=dr & dr(15 DOWNTO 0);
				ELSE
					shift_v:=shift(8 TO N_DW+15) & dr(7 DOWNTO 0);
				END IF;

			WHEN "100" => -- 16bpp
				IF (N_DW=128 AND (acpt MOD 8)=0) OR (N_DW=64 AND (acpt MOD 4)=0) THEN
					shift_v:=dr & dr(15 DOWNTO 0);
				ELSE
					shift_v:=shift(16 TO N_DW+15) & dr(15 DOWNTO 0);
				END IF;

			WHEN "101" => -- 24bpp
				IF N_DW=128 THEN
					IF acpt=0 THEN
						shift_v:=dr & dr(15 DOWNTO 0);
					ELSIF acpt=5 THEN
						shift_v:=shift(24 TO 31) & dr & dr(7 DOWNTO 0);
					ELSIF acpt=10 THEN
						shift_v:=shift(24 TO 39) & dr;
					ELSE
						shift_v:=shift(24 TO N_DW+15) & dr(23 DOWNTO 0);
					END IF;
				ELSE -- N_DW=64
					IF (acpt MOD 8)=0 THEN
						shift_v:=dr & dr(15 DOWNTO 0);
					ELSIF (acpt MOD 8)=2 THEN
						shift_v:=shift(24 TO 39) & dr;
					ELSIF (acpt MOD 8)=5 THEN
						shift_v:=shift(24 TO 31) & dr & dr(7 DOWNTO 0);
					ELSE
						shift_v:=shift(24 TO N_DW+15) & dr(23 DOWNTO 0);
					END IF;
				END IF;
			WHEN OTHERS => -- 32bpp
				IF (N_DW=128 AND (acpt MOD 4)=0) OR (N_DW=64 AND (acpt MOD 2)=0) THEN
					shift_v:=dr & dr(15 DOWNTO 0);
				ELSE
					shift_v:=shift(32 TO N_DW+15) & dr(31 DOWNTO 0);
				END IF;
		END CASE;
		RETURN shift_v;
	END FUNCTION;

	FUNCTION shift_onext (acpt   : natural RANGE 0 TO 15;
								 format : unsigned(5 DOWNTO 0)) RETURN boolean IS
	BEGIN
		CASE format(2 DOWNTO 0) IS
			WHEN "011" => -- 8bpp
				RETURN (N_DW=128 AND acpt=0) OR
						 (N_DW=64  AND ((acpt MOD 8)=0));
			WHEN "100" => -- 16bpp
				RETURN (N_DW=128 AND ((acpt MOD 8)=0)) OR
						 (N_DW=64  AND ((acpt MOD 4)=0));
			WHEN "101" => -- 24bpp
				RETURN (N_DW=128 AND (acpt=0 OR acpt=5 OR acpt=10)) OR
						 (N_DW=64  AND ((acpt MOD 8)=0 OR (acpt MOD 8)=2 OR (acpt MOD 8)=5));
			WHEN OTHERS => -- 32bpp
				RETURN (N_DW=128 AND ((acpt MOD 4)=0)) OR
						 (N_DW=64  AND ((acpt MOD 2)=0));
		END CASE;
	END FUNCTION;

	FUNCTION shift_opix (shift  : unsigned(0 TO N_DW+15);
											 format : unsigned(5 DOWNTO 0)) RETURN type_pix IS
	BEGIN
		CASE format(3 DOWNTO 0) IS
			WHEN "0100" => -- 16bpp 565
				RETURN (b=>shift(8 TO 12) & shift(8 TO 10),
						  g=>shift(13 TO 15) & shift(0 TO 2) & shift(13 TO 14),
						  r=>shift(3 TO 7) & shift(3 TO 5));
			WHEN "1100" => -- 16bpp 1555
				RETURN (b=>shift(9 TO 13) & shift(9 TO 11),
						  g=>shift(14 TO 15) & shift(0 TO 2) & shift(14 TO 15) & shift(0),
						  r=>shift(3 TO 7) & shift(3 TO 5));
			WHEN "0101" | "0110" =>  -- 24bpp / 32bpp
				RETURN (r=>shift(0 TO 7),g=>shift(8 TO 15),b=>shift(16 TO 23));

			WHEN OTHERS =>
				RETURN (r=>shift(0 TO 7),g=>shift(8 TO 15),b=>shift(16 TO 23));

		END CASE;
	END FUNCTION;

	FUNCTION pixoffset(adrs   : unsigned(31 DOWNTO 0);
										 format : unsigned (5 DOWNTO 0)) RETURN natural IS
	BEGIN
		CASE format(2 DOWNTO 0) IS
			WHEN "011" => -- 8bbp
				RETURN to_integer(adrs(NB_LA-1 DOWNTO 0));
			WHEN "100" => -- 16bpp 565
				RETURN to_integer(adrs(NB_LA-1 DOWNTO 1));
			WHEN OTHERS => -- 32bpp
				RETURN to_integer(adrs(NB_LA-1 DOWNTO 2));
		END CASE;
	END FUNCTION;

	FUNCTION swap(d : unsigned(N_DW-1 DOWNTO 0)) RETURN unsigned IS
		VARIABLE e : unsigned(N_DW-1 DOWNTO 0);
	BEGIN
		IF BYTESWAP THEN
			FOR i IN 0 TO N_DW/8-1 LOOP
				e(i*8+7 DOWNTO i*8):=d(N_DW-i*8-1 DOWNTO N_DW-i*8-8);
			END LOOP;
			RETURN e;
		ELSE
			RETURN d;
		END IF;
	END FUNCTION swap;

	-----------------------------------------------------------------------------
	FUNCTION altx (a : unsigned(1 DOWNTO 0)) RETURN unsigned IS
	BEGIN
		CASE a IS
			WHEN "00"   => RETURN "0001";
			WHEN "01"   => RETURN "0010";
			WHEN "10"   => RETURN "0100";
			WHEN OTHERS => RETURN "1000";
		END CASE;
	END FUNCTION;

	-----------------------------------------------------------------------------
	FUNCTION bound(a : unsigned;
								 s : natural) RETURN unsigned IS
	BEGIN
		IF a(a'left)='1' THEN
			RETURN x"00";
		ELSIF a(a'left DOWNTO s)/=0 THEN
			RETURN x"FF";
		ELSE
			RETURN a(s-1 DOWNTO s-8);
		END IF;
	END FUNCTION bound;

	-----------------------------------------------------------------------------
	-- Nearest
	FUNCTION near_frac(f : unsigned) RETURN unsigned IS
		VARIABLE x : unsigned(FRAC-1 DOWNTO 0);
	BEGIN
		x:=(OTHERS =>f(f'left));
		RETURN x;
	END FUNCTION;

	SIGNAL o_h_near_frac,o_v_near_frac : unsigned(FRAC-1 DOWNTO 0);
	SIGNAL o_h_bil_frac,o_v_bil_frac : unsigned(FRAC-1 DOWNTO 0);
	SIGNAL o_h_bil_pix,o_v_bil_pix : type_pix;

	-----------------------------------------------------------------------------
	-- Nearest + Bilinear + Sharp Bilinear
	FUNCTION bil_frac(f : unsigned) RETURN unsigned IS
	BEGIN
		RETURN f(f'left DOWNTO f'left+1-FRAC);
	END FUNCTION;

	TYPE type_bil_t IS RECORD
		r,g,b : unsigned(8+FRAC DOWNTO 0);
	END RECORD;

	FUNCTION bil_calc(f : unsigned(FRAC-1 DOWNTO 0);
							p : arr_pix(0 TO 3)) RETURN type_bil_t IS
		VARIABLE fp,fn : unsigned(FRAC DOWNTO 0);
		VARIABLE u : unsigned(8+FRAC DOWNTO 0);
		VARIABLE x : type_bil_t;
		CONSTANT Z : unsigned(FRAC-1 DOWNTO 0):=(OTHERS =>'0');
	BEGIN
		fp:=('0' & f) + (Z & f(FRAC-1));
		fn:=('1' & Z) - fp;
		u:=p(2).r * fp + p(1).r * fn;
		x.r:=u;
		u:=p(2).g * fp + p(1).g * fn;
		x.g:=u;
		u:=p(2).b * fp + p(1).b * fn;
		x.b:=u;
		RETURN x;
	END FUNCTION;

	FUNCTION near_calc(f : unsigned(FRAC-1 DOWNTO 0);
							 p : arr_pix(0 TO 3)) RETURN type_bil_t IS
		VARIABLE fp,fn : unsigned(FRAC DOWNTO 0);
		VARIABLE u : unsigned(8+FRAC DOWNTO 0);
		VARIABLE x : type_bil_t;
		CONSTANT Z : unsigned(FRAC-1 DOWNTO 0):=(OTHERS =>'0');
	BEGIN
		IF f(FRAC-1)='0' THEN
			x.r := '0' & p(1).r & Z;
			x.g := '0' & p(1).g & Z;
			x.b := '0' & p(1).b & Z;
		ELSE
			x.r := '0' & p(2).r & Z;
			x.g := '0' & p(2).g & Z;
			x.b := '0' & p(2).b & Z;
		END IF;
		RETURN x;
	END FUNCTION;

	SIGNAL o_h_bil_t,o_v_bil_t : type_bil_t;
	SIGNAL o_h_near_t,o_v_near_t : type_bil_t;
	SIGNAL i_h_bil_t : type_bil_t;

	-----------------------------------------------------------------------------
	-- Sharp Bilinear
	--  <0.5 : x*x*x*4
	--  >0.5 : 1 - (1-x)*(1-x)*(1-x)*4

	TYPE type_sbil_tt IS RECORD
		f : unsigned(FRAC-1 DOWNTO 0);
		s : unsigned(FRAC-1 DOWNTO 0);
	END RECORD;

	SIGNAL o_h_sbil_t,o_v_sbil_t : type_sbil_tt;

	FUNCTION sbil_frac1(f : unsigned(11 DOWNTO 0)) RETURN type_sbil_tt IS
		VARIABLE u : unsigned(FRAC-1 DOWNTO 0);
		VARIABLE v : unsigned(2*FRAC-1 DOWNTO 0);
		VARIABLE x : type_sbil_tt;
	BEGIN
		IF f(11)='0' THEN
			u:=f(11 DOWNTO 12-FRAC);
		ELSE
			u:=NOT f(11 DOWNTO 12-FRAC);
		END IF;
		v:=u*u;
		x.f:=u;
		x.s:=v(2*FRAC-2 DOWNTO FRAC-1);
		RETURN x;
	END FUNCTION;

	FUNCTION sbil_frac2(f : unsigned(11 DOWNTO 0);
							  t : type_sbil_tt) RETURN unsigned IS
		VARIABLE v : unsigned(2*FRAC-1 DOWNTO 0);
	BEGIN
		v:=t.f*t.s;
		IF f(11)='0' THEN
			RETURN v(2*FRAC-2 DOWNTO FRAC-1);
		ELSE
			RETURN NOT v(2*FRAC-2 DOWNTO FRAC-1);
		END IF;
	END FUNCTION;

	-----------------------------------------------------------------------------
	-- Bicubic
	TYPE type_bic_abcd IS RECORD
		a  : unsigned(7 DOWNTO 0);  --  0.8
		b  : signed(8 DOWNTO 0);  --  0.9
		c  : signed(11 DOWNTO 0); -- 3.9
		d  : signed(10 DOWNTO 0); -- 2.9
		xx : signed(8 DOWNTO 0); -- X.X 1.8
	END RECORD;
	TYPE type_bic_pix_abcd IS RECORD
		r,g,b : type_bic_abcd;
	END RECORD;
	TYPE type_bic_tt1 IS RECORD -- Intermediate result
		r_bx,g_bx,b_bx    : signed(8 DOWNTO 0);  -- B.X 1.8
		r_cxx,g_cxx,b_cxx : signed(11 DOWNTO 0); -- C.XX 3.9
		r_dxx,g_dxx,b_dxx : signed(10 DOWNTO 0); -- D.XX 2.9
	END RECORD;
	TYPE type_bic_tt2 IS RECORD -- Intermediate result
		r_abxcxx,g_abxcxx,b_abxcxx : signed(9 DOWNTO 0); --  A + B.X + C.XX 2.8
		r_dxxx,g_dxxx,b_dxxx : signed(9 DOWNTO 0); -- D.X.X.X 2.8
	END RECORD;

	----------------------------------------------------------
	-- Y = A + B.X + C.X.X + D.X.X.X = A + X.(B + X.(C + X.D))
	-- A = Y(0)                                       0 .. 1    unsigned
	-- B = Y(1)/2 - Y(-1)/2                        -1/2 .. +1/2 signed
	-- C = Y(-1) - 5*Y(0)/2 + 2*Y(1) - Y(2)/2        -3 .. +3   signed
	-- D = -Y(-1)/2 + 3*Y(0)/2 - 3*Y(1)/2 + Y(2)/2   -2 .. +2   signed

	FUNCTION bic_calc0(f : unsigned(11 DOWNTO 0);
							 pm,p0,p1,p2 : unsigned(7 DOWNTO 0)) RETURN type_bic_abcd IS
		VARIABLE xx : signed(2*FRAC+1 DOWNTO 0); -- 2.(2*FRAC)
	BEGIN
		xx := signed('0' & f(11 DOWNTO 12-FRAC)) *
				signed('0' & f(11 DOWNTO 12-FRAC)); -- 2.(2*FRAC)
		RETURN type_bic_abcd'(
			a=>p0,-- 0.8
			b=>signed(('0' & p1) - ('0' & pm)), -- 0.9
			c=>signed(("000" & pm & '0') - ("00" & p0 & "00") - ("0000" & p0) +
						 ("00" & p1 & "00") - ("0000" & p2)), -- 3.9
			d=>signed(("00" & p0 & '0') - ("00" & p1 & '0') - ("000" & p1) +
						 ("000" & p0) + ("000" & p2) - ("000" & pm)), -- 2.9
			xx=>xx(2*FRAC DOWNTO 2*FRAC-8)); -- 1.8
	END FUNCTION;
	FUNCTION bic_calc0(f : unsigned(11 DOWNTO 0);
							 p : arr_pix(0 TO 3)) RETURN type_bic_pix_abcd IS
	BEGIN
		RETURN type_bic_pix_abcd'( r=>bic_calc0(f,p(0).r,p(1).r,p(2).r,p(3).r),
											g=>bic_calc0(f,p(0).g,p(1).g,p(2).g,p(3).g),
											b=>bic_calc0(f,p(0).b,p(1).b,p(2).b,p(3).b));
	END FUNCTION;

	----------------------------------------------------------
	-- Calc : B.X, C.XX, D.XX
	FUNCTION bic_calc1(f    : unsigned(11 DOWNTO 0);
							 abcd : type_bic_pix_abcd) RETURN type_bic_tt1 IS
		VARIABLE t : type_bic_tt1;
		VARIABLE bx : signed(9+FRAC DOWNTO 0); -- 1.(FRAC+9)
		VARIABLE cxx : signed(20 DOWNTO 0); -- 4.17
		VARIABLE dxx : signed(19 DOWNTO 0); -- 3.17
	BEGIN
		bx := abcd.r.b * signed('0' & f(11 DOWNTO 12-FRAC)); -- 1.(FRAC+9)
		t.r_bx:=bx(9+FRAC DOWNTO 9+FRAC-8); -- 1.8
		cxx:= abcd.r.c * abcd.r.xx; -- 3.9 * 1.8 = 4.17
		t.r_cxx:=cxx(19 DOWNTO 8); -- 3.9
		dxx:= abcd.r.d * abcd.r.xx; -- 2.9 * 1.8 = 3.17
		t.r_dxx:=dxx(18 DOWNTO 8); -- 2.9
		bx := abcd.g.b * signed('0' & f(11 DOWNTO 12-FRAC)); -- 1.(FRAC+9)
		t.g_bx:=bx(9+FRAC DOWNTO 9+FRAC-8); -- 1.8
		cxx:= abcd.g.c * abcd.g.xx; -- 3.9 * 1.8 = 4.17
		t.g_cxx:=cxx(19 DOWNTO 8); -- 3.9
		dxx:= abcd.g.d * abcd.g.xx; -- 2.9 * 1.8 = 3.17
		t.g_dxx:=dxx(18 DOWNTO 8); -- 2.9
		bx := abcd.b.b * signed('0' & f(11 DOWNTO 12-FRAC)); -- 1.(FRAC+9)
		t.b_bx:=bx(9+FRAC DOWNTO 9+FRAC-8); -- 1.8
		cxx:= abcd.b.c * abcd.b.xx; -- 3.9 * 1.8 = 4.17
		t.b_cxx:=cxx(19 DOWNTO 8); -- 3.9
		dxx:= abcd.b.d * abcd.b.xx; -- 2.9 * 1.8 = 3.17
		t.b_dxx:=dxx(18 DOWNTO 8); -- 2.9
		RETURN t;
	END FUNCTION;

	----------------------------------------------------------
	-- Calc A + BX + CXX , X.DXX
	FUNCTION bic_calc2(f    : unsigned(11 DOWNTO 0);
							 t    : type_bic_tt1;
							 abcd : type_bic_pix_abcd) RETURN type_bic_tt2 IS
		VARIABLE u : type_bic_tt2;
		VARIABLE x : signed(11+FRAC DOWNTO 0); -- 3.(9+FRAC)
	BEGIN
		u.r_abxcxx:=(t.r_bx(8) & t.r_bx) + ("00" & signed(abcd.r.a)) + t.r_cxx(10 DOWNTO 1); -- 2.8
		u.g_abxcxx:=(t.g_bx(8) & t.g_bx) + ("00" & signed(abcd.g.a)) + t.g_cxx(10 DOWNTO 1); -- 2.8
		u.b_abxcxx:=(t.b_bx(8) & t.b_bx) + ("00" & signed(abcd.b.a)) + t.b_cxx(10 DOWNTO 1); -- 2.8

		x:=t.r_dxx *  signed('0' & f(11 DOWNTO 12-FRAC)); --2.9 * 1.FRAC =3.(9+FRAC)
		u.r_dxxx:=x(10+FRAC DOWNTO 9+FRAC-8); -- 2.8
		x:=t.g_dxx *  signed('0' & f(11 DOWNTO 12-FRAC)); --2.9 * 1.FRAC =3.(9+FRAC)
		u.g_dxxx:=x(10+FRAC DOWNTO 9+FRAC-8); -- 2.8
		x:=t.b_dxx *  signed('0' & f(11 DOWNTO 12-FRAC)); --2.9 * 1.FRAC =3.(9+FRAC)
		u.b_dxxx:=x(10+FRAC DOWNTO 9+FRAC-8); -- 2.8
		RETURN u;
	END FUNCTION;

	----------------------------------------------------------
	-- Calc  (A + BX + CXX) + (DXXX)
	FUNCTION bic_calc3(f    : unsigned(11 DOWNTO 0);
							 t    : type_bic_tt2;
							 abcd : type_bic_pix_abcd) RETURN type_pix IS
		VARIABLE x : type_pix;
		VARIABLE v : signed(9 DOWNTO 0); -- 2.8
	BEGIN
		v:=t.r_abxcxx + t.r_dxxx;
		x.r:=bound(unsigned(v),8);
		v:=t.g_abxcxx + t.g_dxxx;
		x.g:=bound(unsigned(v),8);
		v:=t.b_abxcxx + t.b_dxxx;
		x.b:=bound(unsigned(v),8);
		RETURN x;
	END FUNCTION;

	-----------------------------------------------------------------------------
	SIGNAL o_h_bic_pix,o_v_bic_pix : type_pix;
	SIGNAL o_h_bic_abcd1,o_h_bic_abcd2 : type_bic_pix_abcd;
	SIGNAL o_v_bic_abcd1,o_v_bic_abcd2 : type_bic_pix_abcd;
	SIGNAL o_h_bic_tt1,o_v_bic_tt1 : type_bic_tt1;
	SIGNAL o_h_bic_tt2,o_v_bic_tt2 : type_bic_tt2;

	-----------------------------------------------------------------------------
	-- Polyphase
	-- 2.7
	TYPE poly_phase_t IS RECORD
		t0, t1, t2, t3  : signed(9 DOWNTO 0);
	END RECORD;

	-- 4.14
	TYPE poly_phase_interp_t IS RECORD
		t0, t1, t2, t3  : signed(17 DOWNTO 0);
	END RECORD;

	TYPE poly_phase_diff_t IS RECORD
		t0, t1, t2, t3 : signed(10 DOWNTO 0);
	END RECORD;
	TYPE poly_phase_product_t IS RECORD
		t0, t1, t2, t3 : signed(19 DOWNTO 0);
	END RECORD;

	-- 5.22
	TYPE type_poly_t IS RECORD
		r0,r1,b0,b1,g0,g1 : signed(26 DOWNTO 0);
	END RECORD;

	SIGNAL o_h_poly_mem : arr_uv40(0 TO 2**FRAC-1);
	SIGNAL o_v_poly_mem : arr_uv40(0 TO 2**FRAC-1);
	SIGNAL o_a_poly_mem : arr_uv40(0 TO 2**FRAC-1);
	ATTRIBUTE ramstyle OF o_h_poly_mem : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_v_poly_mem : SIGNAL IS "no_rw_check";
	ATTRIBUTE ramstyle OF o_a_poly_mem : SIGNAL IS "no_rw_check";
	SIGNAL o_a_poly_addr, o_v_poly_addr : integer RANGE 0 TO 2**FRAC-1;
	SIGNAL o_h_poly_phase_a,o_h_poly_phase_a2,o_h_poly_phase_a3, o_h_poly_phase_a4, o_h_poly_phase_a5 : poly_phase_t;
	SIGNAL o_v_poly_phase_a,o_v_poly_phase_a2,o_v_poly_phase_a3, o_v_poly_phase_a4, o_v_poly_phase_a5 : poly_phase_t;
	SIGNAL o_poly_phase_a, o_poly_phase_a2, o_poly_phase_a3 : poly_phase_t;
	SIGNAL o_poly_phase_b : poly_phase_t;
	SIGNAL o_poly_phase_diff : poly_phase_diff_t;
	SIGNAL o_poly_phase_product : poly_phase_product_t;
	SIGNAL o_v_poly_phase, o_v_poly_phase2, o_h_poly_phase, o_poly_phase1 : poly_phase_interp_t;
	SIGNAL o_v_poly_pix, o_h_poly_pix, o_h_lum_pix, o_v_lum_pix : type_pix;
	SIGNAL o_poly_lum, o_poly_lum1 : unsigned(7 DOWNTO 0);
	SIGNAL o_poly_lerp_t : signed(8 DOWNTO 0);
	SIGNAL o_h_poly_t,o_h_poly_t2,o_v_poly_t   : type_poly_t;

	SIGNAL o_v_poly_adaptive, o_h_poly_adaptive, o_v_poly_use_adaptive, o_h_poly_use_adaptive : std_logic;
	SIGNAL poly_wr_mode : std_logic_vector(2 DOWNTO 0);
	SIGNAL poly_tdw : unsigned(39 DOWNTO 0);
	SIGNAL poly_a2 : unsigned(FRAC-1 DOWNTO 0);

	FUNCTION poly_unpack(a : unsigned(39 DOWNTO 0)) RETURN poly_phase_t IS
		VARIABLE v : poly_phase_t;
	BEGIN
		 v.t0 := signed(a(39 DOWNTO 30));
		 v.t1 := signed(a(29 DOWNTO 20));
		 v.t2 := signed(a(19 DOWNTO 10));
		 v.t3 := signed(a( 9 DOWNTO  0));
		RETURN v;
	END FUNCTION;

	-- 6 DSP 18*18 + 18*18
	FUNCTION poly_calc(fi : poly_phase_interp_t;
							 p  : arr_pix(0 TO 3)) RETURN type_poly_t IS
		VARIABLE t : type_poly_t;
	BEGIN
		-- 3.15 * 1.8 = 4.23
		t.r0:=(fi.t0 * signed('0' & p(0).r) +
					 fi.t1 * signed('0' & p(1).r));
		t.r1:=(fi.t2 * signed('0' & p(2).r) +
					 fi.t3 * signed('0' & p(3).r));
		t.g0:=(fi.t0 * signed('0' & p(0).g) +
					 fi.t1 * signed('0' & p(1).g));
		t.g1:=(fi.t2 * signed('0' & p(2).g) +
					 fi.t3 * signed('0' & p(3).g));
		t.b0:=(fi.t0 * signed('0' & p(0).b) +
					 fi.t1 * signed('0' & p(1).b));
		t.b1:=(fi.t2 * signed('0' & p(2).b) +
					 fi.t3 * signed('0' & p(3).b));
		RETURN t;
	END FUNCTION;

	FUNCTION poly_final(t : type_poly_t) RETURN type_pix IS
		VARIABLE p : type_pix;
	BEGIN
		p.r:=bound(unsigned(t.r0(26 DOWNTO 8)+t.r1(26 DOWNTO 8)),15);
		p.g:=bound(unsigned(t.g0(26 DOWNTO 8)+t.g1(26 DOWNTO 8)),15);
		p.b:=bound(unsigned(t.b0(26 DOWNTO 8)+t.b1(26 DOWNTO 8)),15);
		RETURN p;
	END FUNCTION;

	FUNCTION poly_diff(a, b : poly_phase_t) RETURN poly_phase_diff_t IS
		VARIABLE v : poly_phase_diff_t;
	BEGIN
		v.t0 := resize(b.t0,11) - resize(a.t0,11);
		v.t1 := resize(b.t1,11) - resize(a.t1,11);
		v.t2 := resize(b.t2,11) - resize(a.t2,11);
		v.t3 := resize(b.t3,11) - resize(a.t3,11);
		RETURN v;
	END FUNCTION;

	FUNCTION poly_product(d : poly_phase_diff_t;
								 t : signed(8 DOWNTO 0)) RETURN poly_phase_product_t IS
		VARIABLE v : poly_phase_product_t;
	BEGIN
		v.t0 := d.t0 * t;
		v.t1 := d.t1 * t;
		v.t2 := d.t2 * t;
		v.t3 := d.t3 * t;
		RETURN v;
	END FUNCTION;

	-- A*(256-luma) + B*luma = A*256 + (B-A)*luma.
	-- Keep the original final slice: signed differences need all 11 bits.
	FUNCTION poly_lerp(a : poly_phase_t;
							 p : poly_phase_product_t) RETURN poly_phase_interp_t IS
		VARIABLE v : poly_phase_interp_t;
		VARIABLE t0,t1,t2,t3 : signed(19 DOWNTO 0);
	BEGIN
		t0 := resize(a.t0 & "00000000",20) + p.t0;
		t1 := resize(a.t1 & "00000000",20) + p.t1;
		t2 := resize(a.t2 & "00000000",20) + p.t2;
		t3 := resize(a.t3 & "00000000",20) + p.t3;

		-- 4.16 -> 3.15
		v.t0 := t0(18 DOWNTO 1);
		v.t1 := t1(18 DOWNTO 1);
		v.t2 := t2(18 DOWNTO 1);
		v.t3 := t3(18 DOWNTO 1);

		RETURN v;
	END FUNCTION;

	FUNCTION poly_cvt(a : poly_phase_t) RETURN poly_phase_interp_t IS
		VARIABLE v : poly_phase_interp_t;
	BEGIN
		v.t0 := resize(signed( a.t0 & "0000000" ), v.t0'length);
		v.t1 := resize(signed( a.t1 & "0000000" ), v.t1'length);
		v.t2 := resize(signed( a.t2 & "0000000" ), v.t2'length);
		v.t3 := resize(signed( a.t3 & "0000000" ), v.t3'length);
		RETURN v;
	END FUNCTION;

	-- Nearest neighbor polyphase ceoffs
	FUNCTION poly_nn(frac : unsigned(FRAC-1 DOWNTO 0)) RETURN poly_phase_t IS
		VARIABLE v : poly_phase_t;
	BEGIN
		IF frac(frac'left)='0' THEN
			v := (t1=>to_signed(256, 10), OTHERS=>to_signed(0, 10));
		ELSE
			v := (t2=>to_signed(256, 10), OTHERS=>to_signed(0, 10));
		END IF;
		RETURN v;
	END FUNCTION;


	FUNCTION poly_lum(p : type_pix) RETURN unsigned IS
		VARIABLE v : UNSIGNED(7 DOWNTO 0);
	BEGIN
		-- 0.375 R + 0.5 G + 0.125 B
		--v := ("00" & p.r(7 DOWNTO 2)) + ("000" & p.r(7 DOWNTO 3)) + ("0" & p.g(7 DOWNTO 1)) + ("000" & p.b(7 DOWNTO 3));

		-- 0.25 R + 0.5 G + 0.25 B
		-- v := ( ("00" & p.r(7 DOWNTO 2)) + ("0" & p.g(7 DOWNTO 1)) + ("00" & p.b(7 DOWNTO 2)) );

		-- Just OR them all together
		--v := (p.r OR p.g OR p.b);

		-- Maximum
		IF p.r > p.g THEN
			v := p.r;
		ELSE
			v := p.g;
		END IF;

		IF p.b > v THEN
			v := p.b;
		END IF;

		-- 100%
		-- v := "1111111";

		RETURN v;
	END FUNCTION;
BEGIN

	-----------------------------------------------------------------------------
	i_reset_meta<='0' WHEN reset_na='0' ELSE '1' WHEN rising_edge(i_clk);
	o_reset_meta<='0' WHEN reset_na='0' ELSE '1' WHEN rising_edge(o_clk);
	avl_reset_meta<='0' WHEN reset_na='0' ELSE '1' WHEN rising_edge(avl_clk);
	i_reset_na<='0'   WHEN reset_na='0' ELSE i_reset_meta WHEN rising_edge(i_clk);
	o_reset_na<='0'   WHEN reset_na='0' ELSE o_reset_meta WHEN rising_edge(o_clk);
	avl_reset_na<='0' WHEN reset_na='0' ELSE avl_reset_meta WHEN rising_edge(avl_clk);

	-- Do not reuse either burst-RAM half or change its interpretation while
	-- an old read, copy, or line-buffer write is still owned.
	cfg_apply <= '1' WHEN cfg_pending='1' AND pal_valid_sync='1' AND
		o_bootstrap='0' AND
		pal_ready_sync=cfg_req_sync AND o_readlev=0 AND o_copylev=0 AND
		o_state=sDISP AND o_copy=sWAIT AND o_hsp='0' AND
		o_copyv=(o_copyv'RANGE =>'0') AND o_wr="0000" AND
		(cfg_initialized='0' OR (o_vsv(1)='1' AND o_vsv(0)='0')) ELSE '0';
	cfg_ack<=cfg_ack_i;
	cfg_active<=cfg_initialized;
	o_prime_ready <= '1' WHEN o_prime_started='1' AND o_fload=0 AND
		(c_fb_ena='1' OR o_native_valid='1' OR NOT CONFIG_HANDSHAKE) AND
		o_readlev=0 AND o_copylev=0 AND o_state=sDISP AND o_copy=sWAIT AND
		o_copyv=(o_copyv'RANGE =>'0') AND o_wr="0000" ELSE '0';

	ConfigHandshake:IF CONFIG_HANDSHAKE GENERATE
		PROCESS(o_clk,o_reset_na) IS
		BEGIN
			IF o_reset_na='0' THEN
				cfg_req_meta<='0'; cfg_req_sync<='0'; cfg_ack_i<='0';
				cfg_pending<='0'; cfg_initialized<='0';
				o_bootstrap<='0';
				o_cfg_active<=(OTHERS =>'0');
				pal_ready_meta<='0'; pal_ready_sync<='0';
				pal_valid_meta<='0'; pal_valid_sync<='0'; o_palette_bank<='0';
			ELSIF rising_edge(o_clk) THEN
				cfg_req_meta<=cfg_req;
				cfg_req_sync<=cfg_req_meta;
				pal_ready_meta<=cfg_pal_ready; pal_ready_sync<=pal_ready_meta;
				pal_valid_meta<=cfg_pal_valid; pal_valid_sync<=pal_valid_meta;
				IF o_bootstrap='1' THEN
					IF o_prime_ready='1' AND o_hcpt+1=o_htotal THEN
						cfg_ack_i<=cfg_req_sync;
						o_bootstrap<='0';
					END IF;
				ELSIF cfg_apply='1' THEN
					o_cfg_active<=cfg_capture;
					o_cfg_epoch<=cfg_req_sync;
					IF cfg_initialized='0' OR (o_cfg_active(104)='1' AND cfg_capture(104)='0') THEN
						o_bootstrap<='1';
					ELSE
						cfg_ack_i<=cfg_req_sync;
					END IF;
					cfg_pending<='0';
					cfg_initialized<='1';
					o_palette_bank<=cfg_pal_bank;
				ELSIF cfg_pending='0' AND cfg_req_sync/=cfg_ack_i THEN
					cfg_capture<=cfg_data;
					cfg_pending<='1';
				END IF;
			END IF;
		END PROCESS;
		o_htotal <=to_integer(o_cfg_active(269 DOWNTO 258));
		o_hsstart<=to_integer(o_cfg_active(257 DOWNTO 246));
		o_hsend  <=to_integer(o_cfg_active(245 DOWNTO 234));
		o_hdisp  <=to_integer(o_cfg_active(233 DOWNTO 222));
		o_hmin   <=to_integer(o_cfg_active(221 DOWNTO 210));
		o_hmax   <=to_integer(o_cfg_active(209 DOWNTO 198));
		o_vtotal <=to_integer(o_cfg_active(197 DOWNTO 186));
		o_vsstart<=to_integer(o_cfg_active(185 DOWNTO 174));
		o_vsend  <=to_integer(o_cfg_active(173 DOWNTO 162));
		o_vdisp  <=to_integer(o_cfg_active(161 DOWNTO 150));
		o_vmin   <=to_integer(o_cfg_active(149 DOWNTO 138));
		o_vmax   <=to_integer(o_cfg_active(137 DOWNTO 126));
		o_mode<=o_cfg_active(125 DOWNTO 121);
		o_run<=o_cfg_active(118);
		o_vrr<=o_cfg_active(117);
		o_vrrmax<=to_integer(o_cfg_active(116 DOWNTO 105));
		c_fb_ena<=o_cfg_active(104);
		c_fb_hsize<=to_integer(o_cfg_active(103 DOWNTO 92));
		c_fb_vsize<=to_integer(o_cfg_active(91 DOWNTO 80));
		c_fb_format<=o_cfg_active(79 DOWNTO 74);
		c_fb_base<=o_cfg_active(73 DOWNTO 42);
		c_fb_stride<=o_cfg_active(41 DOWNTO 28);
		o_freeze<=o_cfg_active(27);
		o_bob_deint<=o_cfg_active(26);
		c_swblack<=o_cfg_active(25);
		c_pal_n<=o_cfg_active(24);
		c_border<=o_cfg_active(23 DOWNTO 0);
	END GENERATE;

	LegacyConfiguration:IF NOT CONFIG_HANDSHAKE GENERATE
		c_fb_ena<=o_fb_ena; c_fb_hsize<=o_fb_hsize; c_fb_vsize<=o_fb_vsize;
		c_fb_format<=o_fb_format; c_fb_base<=o_fb_base; c_fb_stride<=o_fb_stride;
		c_swblack<=swblack; c_pal_n<=pal_n; c_border<=o_border;
		PROCESS(o_clk) IS
		BEGIN
			IF rising_edge(o_clk) AND o_reset_na='1' THEN
				o_mode<=mode; o_run<=run;
				o_htotal<=htotal; o_hsstart<=hsstart; o_hsend<=hsend; o_hdisp<=hdisp;
				o_hmin<=hmin; o_hmax<=hmax;
				o_vtotal<=vtotal; o_vsstart<=vsstart; o_vsend<=vsend; o_vdisp<=vdisp;
				o_vmin<=vmin; o_vmax<=vmax;
				o_vrr<=vrr; o_vrrmax<=vrrmax;
				o_freeze<=freeze; o_bob_deint<=bob_deint;
			END IF;
		END PROCESS;
	END GENERATE;

	-----------------------------------------------------------------------------
	-- Input pixels FIFO and shreg
	InAT:PROCESS(i_clk,i_reset_na) IS
		CONSTANT Z : unsigned(FRAC-1 DOWNTO 0):=(OTHERS =>'0');
		VARIABLE frac_v : unsigned(FRAC-1 DOWNTO 0);
		VARIABLE div_v : unsigned(16 DOWNTO 0);
		VARIABLE dir_v : unsigned(11 DOWNTO 0);
		VARIABLE bil_t_v : type_bil_t;
	BEGIN
		IF i_reset_na='0' THEN
			IF NOT CONFIG_HANDSHAKE THEN i_write<='0'; END IF;
			i_cfg_initialized<='0';
			IF CONFIG_HANDSHAKE THEN i_wr<='0'; i_wreq<='0'; END IF;

		ELSIF rising_edge(i_clk) THEN
			i_push<='0';
			i_pushhead<='0';
			i_eol<='0'; -- End Of Line
			IF NOT CONFIG_HANDSHAKE THEN
				i_freeze <=freeze; -- <ASYNC>
				i_bob_deint <= bob_deint;
			END IF;
			i_iauto<=iauto; -- <ASYNC>
			i_wreq<='0';
			i_wr<='0';

			------------------------------------------------------
			i_head(127 DOWNTO 120)<=x"01"; -- Header type
			i_head(119 DOWNTO 112)<="000000" & i_format; -- Header format
			i_head(111 DOWNTO 96)<="0000" & to_unsigned(N_BURST,12); -- Header size
			i_head(95 DOWNTO 80)<=x"0000"; -- Attributes. TBD
			i_head(80)<=i_inter;
			i_head(81)<=i_flm;
			i_head(82)<=i_hdown;
			i_head(83)<=i_vdown;
			i_head(84)<=i_mode(3);
			i_head(87 DOWNTO 85)<=i_count;
			i_head(79 DOWNTO 64)<="0000" & to_unsigned(i_hrsize,12); -- Image width
			i_head(63 DOWNTO 48)<="0000" & to_unsigned(i_vrsize,12); -- Image height
			i_head(47 DOWNTO 32)<= to_unsigned(N_BURST * i_hburst,16); -- Line Length. Bytes
			i_head(31 DOWNTO 16)<="0000" & to_unsigned(i_ohsize,12);
			i_head(15 DOWNTO 0) <="0000" & to_unsigned(i_ovsize,12);

			------------------------------------------------------
			i_ppix<=(i_r,i_g,i_b);
			i_pvs<=i_vs;
			i_pfl<=i_fl;
			i_pde<=i_de;
			i_pce<=i_ce;

			------------------------------------------------------
			IF i_pce='1' THEN
				----------------------------------------------------
				i_vs_pre<=i_pvs;
				i_de_pre<=i_pde;
				i_fl_pre<=i_pfl;

				----------------------------------------------------
				-- Detect interlaced video
				IF NOT INTER THEN
					i_intercnt<=0;
				ELSIF i_pfl/=i_fl_pre THEN
					i_intercnt<=3;
				ELSIF i_pvs='1' AND i_vs_pre='0' AND i_intercnt>0 THEN
					i_intercnt<=i_intercnt-1;
				END IF;
				i_inter<=to_std_logic(i_intercnt>0);

				----------------------------------------------------
				IF i_pvs='1' AND i_vs_pre='0' THEN
					i_sof<='1';
				END IF;

				IF i_pde='1' AND i_de_pre='0' THEN
					i_flm<=i_pfl;
				END IF;

				IF i_pde='1' AND i_sof='1' THEN
					i_sof<='0';
					i_vcpt<=0;
					IF i_inter='1' AND i_flm='0' AND i_half='0' AND INTER THEN
						i_line<='1';
						IF CONFIG_HANDSHAKE THEN i_wfl(i_capture_bank)<='0';
						ELSE i_wfl(o_ibuf1) <= '0'; END IF;
						i_adrsi<=to_unsigned(N_BURST * i_hburst,32) +
									to_unsigned(N_BURST * to_integer(
									unsigned'("00") & to_std_logic(HEADER)),32);
					ELSE
						i_line<='0';
						IF CONFIG_HANDSHAKE THEN i_wfl(i_capture_bank)<='1';
						ELSE i_wfl(o_ibuf0) <= '1'; END IF;
						i_adrsi<=to_unsigned(N_BURST * to_integer(
									 unsigned'("00") & to_std_logic(HEADER)),32);
					END IF;
				END IF;

				i_ven<=to_std_logic(i_hcpt>=i_hmin AND i_hcpt<=i_hmax AND
														i_vcpt>=i_vmin AND i_vcpt<=i_vmax);

				-- Detects end of frame for triple buffering.
				i_endframe0<=i_vs AND (NOT i_inter OR i_flm OR i_bob_deint);
				i_endframe1<=i_vs AND (NOT i_inter OR NOT i_flm OR i_bob_deint);

				i_vss<=to_std_logic(i_vcpt>=i_vmin AND i_vcpt<=i_vmax);

				----------------------------------------------------
				IF i_pde='1' AND i_de_pre='0' THEN
					i_vimax<=i_vcpt;
					i_hcpt<=0;
				ELSE
					i_hcpt<=(i_hcpt+1) MOD 4096;
				END IF;

				IF i_pde='0' AND i_de_pre='1' THEN
					i_himax<=i_hcpt;
				END IF;

				IF i_iauto='1' THEN
					-- Auto-size
					i_hmin<=0;
					i_hmax<=i_himax;
					i_vmin<=0;
					IF i_pvs='1' AND i_vs_pre='0' AND (i_inter='0' OR i_pfl='0') THEN
						i_vmax<=i_vimax;
					END IF;
				ELSE
					-- Forced image
					i_hmin<=himin; -- <ASYNC>
					i_hmax<=himax; -- <ASYNC>
					i_vmin<=vimin; -- <ASYNC>
					IF i_pvs='1' AND i_vs_pre='0' AND (i_inter='0' OR i_pfl='0') THEN
						i_vmax<=vimax; -- <ASYNC>
					END IF;
				END IF;

				IF i_pvs='1' AND i_vs_pre='0' AND (i_inter='0' OR i_pfl='0') THEN
					i_vdmax<=i_vimax;
				END IF;
				i_hdmax<=i_himax;

				IF i_format="00" OR i_format="11" THEN -- 16bpp
					i_hburst<=(i_hrsize*2 + N_BURST - 1) / N_BURST;
				ELSIF i_format="01" THEN -- 24bpp
					i_hburst<=(i_hrsize*3 + N_BURST - 1) / N_BURST;
				ELSE -- 32bpp
					i_hburst<=(i_hrsize*4 + N_BURST - 1) / N_BURST;
				END IF;
				----------------------------------------------------
				IF CONFIG_HANDSHAKE THEN
					-- The source descriptor shares i_clk. Keep one image's
					-- packing/downscale controls fixed until its next VS.
					IF i_cfg_initialized='0' OR
						(i_pvs='1' AND i_vs_pre='0' AND (i_inter='0' OR i_pfl='0')) THEN
						i_cfg_initialized<='1';
						i_mode<=cfg_data(125 DOWNTO 121);
						i_format<=cfg_data(120 DOWNTO 119);
						i_ohsize<=to_integer(cfg_data(209 DOWNTO 198))-
							to_integer(cfg_data(221 DOWNTO 210))+1;
						i_ovsize<=to_integer(cfg_data(137 DOWNTO 126))-
							to_integer(cfg_data(149 DOWNTO 138))+1;
						i_freeze<=cfg_data(27);
						i_bob_deint<=cfg_data(26);
					END IF;
				ELSE
					i_mode<=mode; -- <ASYNC>
					i_format<=format; -- <ASYNC>
				END IF;

				-- Downscaling : Nearest or bilinear
				i_bil<=to_std_logic(i_mode(2 DOWNTO 0)/="000" AND NOT DOWNSCALE_NN);

				i_hdown<=to_std_logic(i_hsize>i_ohsize AND DOWNSCALE); --H downscale
				i_vdown<=to_std_logic(i_vsize>i_ovsize AND DOWNSCALE); --V downscale

				----------------------------------------------------
				i_hsize  <=(4096+i_hmax-i_hmin+1) MOD 4096;
				i_vmaxmin<=(4096+i_vmax-i_vmin+1) MOD 4096;

				IF i_inter='0' THEN
					-- Non interlaced
					i_vsize<=i_vmaxmin;
					i_half <='0';
				ELSIF i_ovsize<2*i_vmaxmin THEN
					-- Interlaced, but downscaling, use only half frames
					i_vsize<=i_vmaxmin;
					i_half <='1';
				ELSE
					-- Interlaced : Double image height
					i_vsize<=2*i_vmaxmin;
					i_half <='0';
				END IF;

				IF NOT CONFIG_HANDSHAKE THEN
					i_ohsize<=o_hsize; -- <ASYNC>
					i_ovsize<=o_vsize; -- <ASYNC>
				END IF;

				----------------------------------------------------
				-- Downscaling vertical
				i_divstart<='0';
				IF i_de_delay=16 THEN
					IF (i_vacc + 2*i_ovsize) < 2*i_vsize THEN
						i_vacc<=(i_vacc + 2*i_ovsize) MOD 8192;
						i_vnp<='0';
					ELSE
						i_vacc<=(i_vacc + 2*i_ovsize - 2*i_vsize + 8192) MOD 8192;
						i_vnp<='1';
					END IF;
					i_divstart<='1';

					IF i_vcpt=i_vmin THEN
					 i_vacc<=(i_vsize - i_ovsize + 8192) MOD 8192;
					 i_vnp<='1'; -- <AVOIR>
					END IF;
				END IF;

				IF i_vdown='0' THEN
					i_vnp<='1';
				END IF;

				-- Downscaling horizontal
				IF i_ven='1' THEN
					IF i_hacc + 2*i_ohsize < 2*i_hsize THEN
						i_hacc<=(i_hacc + 2*i_ohsize) MOD 8192;
						i_hnp<='0'; -- Skip. pix.
					ELSE
						i_hacc<=(i_hacc + 2*i_ohsize - 2*i_hsize + 8192) MOD 8192;
						i_hnp<='1';
					END IF;
				END IF;
				IF i_hdown='0' THEN
					i_hnp<='1';
				END IF;

				----------------------------------------------------
				-- Downscaling interpolation
				i_hpixp<=i_ppix;
				i_hpix0<=i_hpixp;
				i_hpix1<=i_hpix0;
				i_hpix2<=i_hpix1;
				i_hpix3<=i_hpix2;
				i_hpix4<=i_hpix3;

				i_hnp1<=i_hnp;  i_hnp2<=i_hnp1; i_hnp3<=i_hnp2; i_hnp4<=i_hnp3;
				i_ven1<=i_ven;  i_ven2<=i_ven1; i_ven3<=i_ven2; i_ven4<=i_ven3;
				i_ven5<=i_ven4; i_ven6<=i_ven5;

				-- C1 : DIV 1. Pipelined 4 bits non-restoring divider
				dir_v:=x"000";
				div_v:=to_unsigned(i_hacc * 16,17);

				div_v:=div_v-to_unsigned(i_hsize*16,17);
				dir_v(11):=NOT div_v(16);
				IF div_v(16)='0' THEN
					div_v:=div_v-to_unsigned(i_hsize*8,17);
				ELSE
					div_v:=div_v+to_unsigned(i_hsize*8,17);
				END IF;
				dir_v(10):=NOT div_v(16);
				i_div<=div_v;
				i_dir<=dir_v;

				-- C2 : DIV 2.
				div_v:=i_div;
				dir_v:=i_dir;
				IF div_v(16)='0' THEN
					div_v:=div_v-to_unsigned(i_hsize*4,17);
				ELSE
					div_v:=div_v+to_unsigned(i_hsize*4,17);
				END IF;
				dir_v(9):=NOT div_v(16);

				IF div_v(16)='0' THEN
					div_v:=div_v-to_unsigned(i_hsize*2,17);
				ELSE
					div_v:=div_v+to_unsigned(i_hsize*2,17);
				END IF;
				dir_v(8):=NOT div_v(16);
				i_h_frac<=dir_v;

				-- C4 : Horizontal Bilinear
				IF i_bil='0' THEN
					frac_v:=near_frac(i_h_frac);
					i_h_bil_t<=near_calc(frac_v,(i_hpix2,i_hpix2,i_hpix3,i_hpix3));
				ELSE
					frac_v:=bil_frac(i_h_frac);
					i_h_bil_t<=bil_calc(frac_v,(i_hpix2,i_hpix2,i_hpix3,i_hpix3));
				END IF;

				i_hpix.r<=bound(i_h_bil_t.r,8+FRAC);
				i_hpix.g<=bound(i_h_bil_t.g,8+FRAC);
				i_hpix.b<=bound(i_h_bil_t.b,8+FRAC);

				IF i_hdown='0' THEN
					i_hpix<=i_hpix4;
				END IF;

				-- C5 : Vertical Bilinear
				IF i_bil='0' THEN
					frac_v:=near_frac(i_v_frac(11 DOWNTO 0));
					bil_t_v:=near_calc(frac_v,(i_hpix,i_hpix,i_ldrm,i_ldrm));
				ELSE
					frac_v:=bil_frac(i_v_frac(11 DOWNTO 0));
					bil_t_v:=bil_calc(frac_v,(i_hpix,i_hpix,i_ldrm,i_ldrm));
				END IF;

				i_pix.r<=bound(bil_t_v.r,8+FRAC);
				i_pix.g<=bound(bil_t_v.g,8+FRAC);
				i_pix.b<=bound(bil_t_v.b,8+FRAC);

				IF i_vdown='0' THEN
					i_pix<=i_hpix;
				END IF;

				----------------------------------------------------
				-- VNP : Vert. downscaling line enable
				-- HNP : Horiz. downscaling pix. enable
				-- VEN : Enable pixel within displayed window

				IF (i_hnp4='1' AND i_ven6='1') OR i_pushend='1' THEN
					i_shift<=shift_ishift(i_shift,i_pix,i_format);
					i_dw<=shift_ipack(i_dw,i_acpt,i_shift,i_pix,i_format);

					IF shift_inext(i_acpt,i_format) AND i_vnp='1' THEN
						i_push<='1';
						i_pushend<='0';
					END IF;
					i_acpt<=(i_acpt+1) MOD 16;
				END IF;

				IF i_ven6='1' AND i_ven5='0' AND i_vnp='1' THEN
					i_pushend<='1';
				END IF;
				i_pushend2<=i_pushend;

				IF i_pushend2='1' AND i_pushend='0' THEN
					i_eol<='1';
				END IF;

				IF i_pde='0' AND i_de_pre='1' THEN
					i_de_delay<=0;
				ELSIF i_de_delay<18 THEN
					i_de_delay<=i_de_delay+1;
				END IF;

				IF i_de_delay=16 THEN
					i_lwad<=0;
					i_lrad<=0;
					i_vcpt<=i_vcpt+1;
					i_hacc<=(i_hsize - i_ohsize + 8192) MOD 8192;
					i_hbcpt<=0;
				END IF;
				IF i_de_delay=17 THEN
					i_acpt<=0;
					i_wad<=2*BLEN-1;
				END IF;

				IF i_pvs='0' AND i_vs_pre='1' THEN
					-- Push header
					i_pushhead<=to_std_logic(HEADER);
				END IF;

			END IF; -- IF i_pce='1'

			------------------------------------------------------
			-- Push pixels to downscaling line buffer
			i_lwr<=i_hnp4 AND i_ven5 AND i_pce;
			IF i_lwr='1' THEN
				i_lwad<=(i_lwad+1) MOD OHRESH;
			END IF;
			i_ldw<=i_hpix;

			IF i_hnp3='1' AND i_ven4='1' AND i_pce='1' THEN
				i_lrad<=(i_lrad+1) MOD OHRESH;
			END IF;

			------------------------------------------------------
			-- Write image properties header
			i_pushhead2<=i_pushhead; i_pushhead3<=i_pushhead2;

			IF i_pushhead='1' AND i_freeze='0' AND i_capture_allow='1' THEN
				i_dw<=i_head(127 DOWNTO 128-N_DW);
				i_count<=i_count+1;
				i_wr<='1';
				i_wad<=0;
				IF N_DW=128 THEN
					i_alt<='0';
					i_wreq<=NOT i_freeze;
					i_adrs<=(OTHERS =>'0');
				END IF;
			END IF;

			IF i_pushhead2='1' AND i_freeze='0' AND i_capture_allow='1' AND N_DW=64 THEN
				i_dw<=i_head(N_DW-1 DOWNTO 0);
				i_wr<='1';
				i_wad<=1;
				i_wreq<=NOT i_freeze;
				i_alt<='0';
				i_adrs<=(OTHERS =>'0');
			END IF;
			IF i_pushhead3='1' THEN
				i_wad<=BLEN-1;
			END IF;

			------------------------------------------------------
			-- Push pixels to DPRAM
			IF i_push='1' AND i_freeze='0' AND i_capture_allow='1' THEN
				i_wr<='1';
				i_wad<=(i_wad+1) MOD (BLEN*2);
				IF (i_wad+1) MOD BLEN=BLEN-1 AND i_hbcpt<i_hburst THEN
					i_hbcpt<=(i_hbcpt+1) MOD 32;
					i_wreq<=NOT i_freeze;
					i_alt<=to_std_logic((i_wad+1)/BLEN /= 0);
					i_adrs<=i_adrsi;
					i_adrsi<=i_adrsi+N_BURST;
				END IF;
			END IF;

			-- End of line
			IF i_eol='1' AND i_freeze='0' AND i_capture_allow='1' THEN
				IF (i_wad MOD BLEN)/=BLEN-1 AND i_hbcpt<i_hburst THEN
					-- Some pixels are in the partially filled buffer
					i_hbcpt<=(i_hbcpt+1) MOD 32;
					i_wreq<=NOT i_freeze;
					i_alt <=to_std_logic(i_wad/BLEN /= 0);
					i_adrs <=i_adrsi;
					IF i_inter='1' AND i_half='0' THEN
						-- Skip every other line for interlaced video
						i_adrsi<=i_adrsi + N_BURST * (i_hburst + 1);
					ELSE
						i_adrsi<=i_adrsi + N_BURST;
					END IF;
				ELSE
					IF i_inter='1' AND i_half='0' THEN
						-- Skip every other line for interlaced video
						i_adrsi<=i_adrsi + N_BURST * i_hburst;
					END IF;
				END IF;
			END IF;

			-- Push write accesses. Ensure a delay between consecutive writes
			IF i_wreq_mem='1' AND i_wdelay=5 AND
				(NOT CONFIG_HANDSHAKE OR i_write_done_sync=i_write) THEN
				i_write<=NOT i_write;
				i_wadrs<=i_wadrs_mem;
				i_walt <=i_walt_mem;
				i_wline<=i_wline_mem;
				i_wbuf<=i_wbuf_mem;
				i_wdelay<=0;
				i_wreq_mem<='0';
			ELSIF i_wdelay<5 THEN
				i_wdelay<=i_wdelay+1;
			END IF;
			IF i_wreq='1' AND i_queue_conflict='0' AND i_write_conflict='0' THEN
				i_wadrs_mem<=i_adrs;
				i_walt_mem <=i_alt;
				i_wline_mem<=i_line;
				i_wbuf_mem<=i_capture_bank;
				i_wreq_mem<='1';
			END IF;

		END IF;
	END PROCESS;

	-- If downscaling, export to the output part the downscaled size
	i_hrsize<=i_hsize WHEN i_hdown='0' ELSE i_ohsize;
	i_vrsize<=i_vsize WHEN i_vdown='0' ELSE i_ovsize;

	-- A context owns a completed image, not just an observed input VS.
	-- Held request/return phases survive logical reset, just like the read side.
	i_capture_allow<='1' WHEN NOT CONFIG_HANDSHAKE ELSE
		i_frame_active AND NOT i_frame_bad;
	i_queue_conflict<='1' WHEN CONFIG_HANDSHAKE AND i_wreq='1' AND i_wreq_mem='1'
		AND NOT (i_wdelay=5 AND i_write_done_sync=i_write) ELSE '0';
	i_write_conflict<='1' WHEN CONFIG_HANDSHAKE AND i_wr='1' AND
		((i_write_done_sync/=i_write AND i_wad/BLEN=to_integer(unsigned'("0" & i_walt))) OR
		 (i_wreq_mem='1' AND i_wad/BLEN=to_integer(unsigned'("0" & i_walt_mem)))) ELSE '0';

	NativeContext:IF CONFIG_HANDSHAKE GENERATE
		PROCESS(i_clk) IS
			VARIABLE context_v : unsigned(63 DOWNTO 0);
			VARIABLE fields_v : unsigned(1 DOWNTO 0);
		BEGIN
			IF rising_edge(i_clk) THEN
				i_native_ack_meta<=o_native_ack;
				i_native_ack_sync<=i_native_ack_meta;
				i_write_done_meta<=avl_write_done;
				i_write_done_sync<=i_write_done_meta;
				i_epoch_meta<=o_native_epoch; i_epoch_sync<=i_epoch_meta;
				i_stream_meta<=o_native_stream; i_stream_sync<=i_stream_meta;
				IF i_native_ack_sync/=i_native_ack_seen THEN
					i_native_ack_seen<=i_native_ack_sync;
					i_native_release<=o_native_release;
				END IF;
				IF i_reset_na='0' OR i_epoch_seen/=i_epoch_sync THEN
					-- Do not acknowledge a refresh with an older held context
					-- still outstanding, even across repeated clock-stopped resets.
					IF i_native_req=i_native_ack_seen THEN i_epoch_seen<=i_epoch_sync; END IF;
					i_frame_active<='0'; i_frame_drain<='0'; i_frame_bad<='0';
					i_native_delivered<='0'; i_field_seen<="00";
				ELSE
					IF i_write_conflict='1' OR i_queue_conflict='1' THEN
						i_frame_bad<='1';
					END IF;
					IF (i_frame_active='1' OR i_frame_drain='1') AND
						(i_frame_context(35)/=cfg_req OR cfg_data(104)='1') THEN
						i_frame_bad<='1';
					END IF;
					IF i_frame_active='1' AND
						(i_hrsize/=to_integer(i_frame_context(11 DOWNTO 0)) OR
						 i_vrsize/=to_integer(i_frame_context(23 DOWNTO 12)) OR
						 i_format/=i_frame_context(27 DOWNTO 26) OR
						 i_hdown/=i_frame_context(28) OR i_vdown/=i_frame_context(29) OR
						 i_inter/=i_frame_context(30) OR i_half/=i_frame_context(31)) THEN
						i_frame_bad<='1';
					END IF;
					IF i_pce='1' AND i_frame_active='1' AND
						i_pde='0' AND i_de_pre='1' AND
						i_hcpt+1/=to_integer(i_frame_context(48 DOWNTO 37)) THEN
						i_frame_bad<='1';
					END IF;
					IF i_pce='1' AND i_pvs='1' AND i_vs_pre='0' AND i_frame_active='1' THEN
						fields_v:=i_field_seen;
						fields_v(to_integer(unsigned'("0" & i_flm))):='1';
						i_field_seen<=fields_v;
						IF (i_inter='0' OR i_half='1' OR fields_v="11") THEN
							i_frame_active<='0'; i_frame_drain<='1';
						END IF;
						IF i_vimax+1/=to_integer(i_frame_context(60 DOWNTO 49)) THEN
							i_frame_bad<='1';
						END IF;
					END IF;
					IF i_frame_drain='1' AND i_wr='0' AND i_wreq='0' AND
						i_wreq_mem='0' AND i_write_done_sync=i_write AND
						i_native_req=i_native_ack_seen THEN
						i_frame_drain<='0';
						IF i_frame_bad='0' THEN
							i_native_context<=i_frame_context(36 DOWNTO 0);
							i_native_context(34 DOWNTO 32)<=unsigned(i_wfl);
							i_native_req<=NOT i_native_req;
							i_native_delivered<='1';
							IF i_native_release(2)='1' THEN
								i_capture_bank<=native_next(i_capture_bank,to_integer(i_native_release(1 DOWNTO 0)));
							ELSE
								i_capture_bank<=native_next(i_capture_bank,i_capture_bank);
							END IF;
						END IF;
					END IF;
					-- VS falling precedes header/pixel production; all measured
					-- size pipelines have settled during the actual input VS.
					IF i_pce='1' AND i_pvs='0' AND i_vs_pre='1' AND
						i_frame_active='0' AND i_frame_drain='0' AND
						i_wr='0' AND i_wreq='0' AND i_wreq_mem='0' AND
						i_write_done_sync=i_write AND i_cfg_initialized='1' AND
						cfg_data(104)='0' AND i_freeze='0' AND
						i_hrsize>0 AND i_vrsize>0 AND
						(i_mode(3)='1' OR i_native_delivered='0' OR i_stream_sync='1') THEN
						context_v:=(OTHERS =>'0');
						context_v(11 DOWNTO 0):=to_unsigned(i_hrsize,12);
						context_v(23 DOWNTO 12):=to_unsigned(i_vrsize,12);
						IF i_mode(3)='0' THEN
							i_capture_bank<=0;
							context_v(25 DOWNTO 24):="00";
						ELSIF i_native_release(2)='1' AND
							i_capture_bank=to_integer(i_native_release(1 DOWNTO 0)) THEN
							i_capture_bank<=native_next(i_capture_bank,i_capture_bank);
							context_v(25 DOWNTO 24):=to_unsigned(native_next(i_capture_bank,i_capture_bank),2);
						ELSE
							context_v(25 DOWNTO 24):=to_unsigned(i_capture_bank,2);
						END IF;
						context_v(27 DOWNTO 26):=i_format;
						context_v(28):=i_hdown; context_v(29):=i_vdown;
						context_v(30):=i_inter; context_v(31):=i_half;
						context_v(35):=cfg_req; context_v(36):=i_epoch_sync;
						-- Validate the observed DE raster separately from its
						-- configured crop/downscale dimensions.
						context_v(48 DOWNTO 37):=to_unsigned((i_himax+1) MOD 4096,12);
						context_v(60 DOWNTO 49):=to_unsigned((i_vimax+1) MOD 4096,12);
						i_frame_context<=context_v;
						i_frame_active<='1'; i_frame_bad<='0'; i_field_seen<="00";
					END IF;
				END IF;
			END IF;
		END PROCESS;
		PROCESS(o_clk) IS
		BEGIN
			IF rising_edge(o_clk) THEN
				o_native_meta<=i_native_req; o_native_sync<=o_native_meta;
				o_epoch_meta<=i_epoch_seen; o_epoch_sync<=o_epoch_meta;
				o_native_reset_seen<=NOT o_reset_na;
				IF o_native_refresh='1' AND o_epoch_sync=o_native_epoch THEN
					o_native_epoch<=NOT o_native_epoch;
					o_native_refresh<='0'; o_native_epoch_wait<='1';
				END IF;
				IF o_native_epoch_wait='1' AND o_epoch_sync=o_native_epoch AND
					o_native_refresh='0' THEN
					o_native_epoch_wait<='0';
				END IF;
				IF o_reset_na='0' AND o_native_reset_seen='0' THEN
					o_native_refresh<='1'; o_native_epoch_wait<='1';
				ELSIF cfg_apply='1' AND o_cfg_active(104)='1' AND cfg_capture(104)='0' THEN
					o_native_refresh<='1'; o_native_epoch_wait<='1';
				END IF;
			END IF;
		END PROCESS;
	END GENERATE;

	-----------------------------------------------------------------------------
	-- Input Divider. For downscaling.
	-- Vfrac = IVacc / IVsize 12 / 12 --> 12
	IDividers:PROCESS (i_clk,i_reset_na) IS
	BEGIN
		IF i_reset_na='0' THEN
--pragma synthesis_off
			i_v_frac<=x"000";
--pragma synthesis_on
			NULL;
		ELSIF rising_edge(i_clk) THEN
			i_vdivi<=to_unsigned(2*i_vsize,13);
			i_vdivr<=to_unsigned(i_vacc*4096,25);

			------------------------------------------------------
			IF i_divstart='1' THEN
				i_divcpt<=0;
				i_divrun<='1';

			ELSIF i_divrun='1' THEN
				----------------------------------------------------
				IF i_divcpt=6 THEN
					i_divrun<='0';
					i_v_frac<=i_vdivr(4 DOWNTO 0) & NOT i_vdivr(24) & "000000";
				ELSE
					i_divcpt<=i_divcpt+1;
				END IF;

				IF i_vdivr(24)='0' THEN
					i_vdivr(24 DOWNTO 12)<=i_vdivr(23 DOWNTO 11) - i_vdivi;
				ELSE
					i_vdivr(24 DOWNTO 12)<=i_vdivr(23 DOWNTO 11) + i_vdivi;
				END IF;
				i_vdivr(11 DOWNTO 0)<=i_vdivr(10 DOWNTO 0) & NOT i_vdivr(24);

				----------------------------------------------------
			END IF;
		END IF;
	END PROCESS IDividers;

	-----------------------------------------------------------------------------
	-- DPRAM Input. Double buffer for RAM bursts.
	PROCESS (i_clk) IS
	BEGIN
		IF rising_edge(i_clk) THEN
			IF i_wr='1' AND i_write_conflict='0' THEN
				i_dpram(i_wad)<=i_dw;
			END IF;
		END IF;
	END PROCESS;

	avl_dr<=i_dpram(avl_rad_c) WHEN rising_edge(avl_clk);

	-- Line buffer for downscaling with interpolation
	DownLine:IF DOWNSCALE GENERATE
		ILBUF:PROCESS(i_clk) IS
		BEGIN
			IF rising_edge(i_clk) THEN
				IF i_lwr='1' THEN
					i_mem(i_lwad MOD IHRES)<=i_ldw;
				END IF;
				IF i_pce='1' THEN
					i_ldrm<=i_mem(i_lrad MOD IHRES);
				END IF;
			END IF;
		END PROCESS ILBUF;
	END GENERATE DownLine;

	-----------------------------------------------------------------------------
	-- AVALON interface
	Avaloir:PROCESS(avl_clk,avl_reset_na) IS
		VARIABLE adr_v : unsigned(31 DOWNTO 0);
	BEGIN
		IF NOT CONFIG_HANDSHAKE AND avl_reset_na='0' THEN
			avl_state<=sIDLE;
			avl_write_sr<='0';
			avl_read_sr<='0';
			avl_readdataack<='0';
			avl_readack<='0';
			IF CONFIG_HANDSHAKE THEN avl_wad<=2*BLEN-1; END IF;
			IF CONFIG_HANDSHAKE THEN
				avl_read_sync<='0'; avl_read_sync2<='0'; avl_read_sync3<='0';
				avl_read_pulse<='0';
			END IF;

		ELSIF rising_edge(avl_clk) THEN
			----------------------------------
			avl_write_sync<=i_write; -- <ASYNC>
			avl_write_sync2<=avl_write_sync;
			avl_write_sync3<=avl_write_sync2;
			IF CONFIG_HANDSHAKE THEN
				avl_write_pulse<=avl_write_sync2 XOR avl_write_sync3;
			ELSE
				avl_write_pulse<=avl_write_sync XOR avl_write_sync2;
			END IF;
			IF avl_write_pulse='1' THEN
				avl_wadrs <=i_wadrs AND (RAMSIZE - 1); -- <ASYNC>
				avl_wline <=i_wline; -- <ASYNC>
				avl_walt  <=i_walt; -- <ASYNC>
				avl_wbuf<=i_wbuf;
			END IF;

			----------------------------------
			avl_read_sync<=o_read; -- <ASYNC>
			avl_read_sync2<=avl_read_sync;
			IF CONFIG_HANDSHAKE THEN
				avl_read_sync3<=avl_read_sync2;
				avl_read_pulse<=avl_read_sync2 XOR avl_read_sync3;
			ELSE
				avl_read_pulse<=avl_read_sync XOR avl_read_sync2;
			END IF;
			IF CONFIG_HANDSHAKE THEN
				IF avl_read_pulse='1' THEN
					avl_radrs<=o_adrs;
					avl_read_base<=o_read_base;
				END IF;
			ELSE
				avl_radrs <=o_adrs; -- <ASYNC>
				avl_rline <=o_rline; -- <ASYNC>
			END IF;

			--------------------------------------------
			avl_o_vs_sync<=o_vsv(0); -- <ASYNC>
			avl_o_vs<=avl_o_vs_sync;

			IF NOT CONFIG_HANDSHAKE THEN
			avl_fb_ena<=o_fb_ena; -- <ASYNC>
			IF avl_fb_ena='0' THEN
				IF HEADER THEN
					avl_o_offset0<=buf_offset(o_obuf0,RAMBASE,RAMSIZE) + N_BURST;  -- <ASYNC>
					avl_o_offset1<=buf_offset(o_obuf1,RAMBASE,RAMSIZE) + N_BURST;  -- <ASYNC>
				ELSE
					avl_o_offset0<=buf_offset(o_obuf0,RAMBASE,RAMSIZE);  -- <ASYNC>
					avl_o_offset1<=buf_offset(o_obuf1,RAMBASE,RAMSIZE);  -- <ASYNC>
				END IF;
			ELSIF avl_o_vs_sync='0' AND avl_o_vs='1' THEN
				-- Copy framebuffer base address at VS falling edge
				avl_o_offset0<=o_fb_base; -- <ASYNC>
				avl_o_offset1<=o_fb_base; -- <ASYNC>
			END IF;
			END IF;

			avl_i_offset0<=buf_offset(o_ibuf0,RAMBASE,RAMSIZE);  -- <ASYNC>
			avl_i_offset1<=buf_offset(o_ibuf1,RAMBASE,RAMSIZE);  -- <ASYNC>

			--------------------------------------------
			avl_dw<=swap(unsigned(avl_readdata));
			avl_read_i<='0';
			avl_write_i<='0';

			avl_write_sr<=(avl_write_sr OR avl_write_pulse) AND NOT avl_write_clr;
			avl_read_sr <=(avl_read_sr  OR avl_read_pulse)  AND NOT avl_read_clr;
			avl_write_clr<='0';
			avl_read_clr <='0';

			avl_rad<=avl_rad_c;

			--------------------------------------------
			CASE avl_state IS
				WHEN sIDLE =>
					IF avl_write_sr='1' THEN
						avl_state<=sWRITE;
						avl_write_clr<='1';
						IF avl_walt='0' THEN
							avl_rad<=0;
						ELSE
							avl_rad<=BLEN;
						END IF;
						IF CONFIG_HANDSHAKE THEN
							adr_v:=buf_offset(avl_wbuf,RAMBASE,RAMSIZE)+avl_wadrs;
							avl_address<=std_logic_vector(adr_v(N_AW+NB_LA-1 DOWNTO NB_LA));
						ELSIF avl_wline='0' THEN
							avl_address<=std_logic_vector(
								avl_wadrs(N_AW+NB_LA-1 DOWNTO NB_LA) +
								avl_i_offset0(N_AW+NB_LA-1 DOWNTO NB_LA));
						ELSE
							avl_address<=std_logic_vector(
								avl_wadrs(N_AW+NB_LA-1 DOWNTO NB_LA) +
								avl_i_offset1(N_AW+NB_LA-1 DOWNTO NB_LA));
						END IF;
					ELSIF avl_read_sr='1' THEN
						IF CONFIG_HANDSHAKE THEN avl_state<=sREAD_ADDR;
						ELSE avl_state<=sREAD; END IF;
						avl_read_clr<='1';
					END IF;

				WHEN sWRITE =>
					avl_write_i<='1';
					IF avl_write_i='1' AND avl_waitrequest='0' THEN
						IF (avl_rad MOD BLEN)=BLEN-1 THEN
							avl_write_i<='0';
							avl_state<=sIDLE;
							avl_write_done<=avl_write_sync3;
						END IF;
					END IF;

				WHEN sREAD_ADDR =>
					-- Split the address carry before offering the transaction.
					-- The held descriptor remains owned through read ACK.
					avl_read_low<=('0' & avl_radrs(15 DOWNTO 0)) +
						('0' & avl_read_base(15 DOWNTO 0));
					avl_read_high<=avl_radrs(31 DOWNTO 16) + avl_read_base(31 DOWNTO 16);
					avl_state<=sREAD_SET;

				WHEN sREAD_SET =>
					adr_v:=(avl_read_high + resize(avl_read_low(16 DOWNTO 16),16)) & avl_read_low(15 DOWNTO 0);
					avl_address<=std_logic_vector(adr_v(N_AW+NB_LA-1 DOWNTO NB_LA));
					avl_state<=sREAD;

				WHEN sREAD =>
					IF NOT CONFIG_HANDSHAKE THEN
					IF avl_rline='0' THEN
						adr_v:=avl_radrs + avl_o_offset0;
					ELSE
						adr_v:=avl_radrs + avl_o_offset1;
					END IF;
					avl_address<=std_logic_vector(adr_v(N_AW+NB_LA-1 DOWNTO NB_LA));
					END IF;

					avl_read_i<='1';
					IF avl_read_i='1' AND avl_waitrequest='0' THEN
						avl_state<=sIDLE;
						avl_read_i<='0';
						avl_readack<=NOT avl_readack;
					END IF;
			END CASE;

			--------------------------------------------
			-- Pipelined data read
			avl_wr<='0';
			IF avl_readdatavalid='1' THEN
				avl_wr<='1';
				avl_wad<=(avl_wad+1) MOD (2*BLEN);
				IF (avl_wad MOD BLEN)=BLEN-2 THEN
					avl_readdataack<=NOT avl_readdataack;
					IF CONFIG_HANDSHAKE THEN
						avl_completed<=avl_completed+1;
						avl_completed_gray<=((avl_completed+1) SRL 1) XOR (avl_completed+1);
					END IF;
				END IF;
			END IF;

			IF NOT CONFIG_HANDSHAKE AND avl_o_vs_sync='0' AND avl_o_vs='1' THEN
				avl_wad<=2*BLEN-1;
			END IF;

			--------------------------------------------
		END IF;
	END PROCESS Avaloir;

	avl_read<=avl_read_i;
	avl_write<=avl_write_i;
	avl_writedata<=std_logic_vector(swap(avl_dr));
	avl_burstcount<=std_logic_vector(to_unsigned(BLEN,8));
	avl_byteenable<=(OTHERS =>'1');

	avl_rad_c<=(avl_rad+1) MOD (2*BLEN)
					WHEN avl_write_i='1' AND avl_waitrequest='0' ELSE avl_rad;

	-----------------------------------------------------------------------------
	-- DPRAM Output. Double buffer for RAM bursts.
	PROCESS (avl_clk) IS
	BEGIN
		IF rising_edge(avl_clk) THEN
			IF avl_wr='1' THEN
				o_dpram(avl_wad)<=avl_dw;
			END IF;
		END IF;
	END PROCESS;

	o_dr<=o_dpram(o_ad3) WHEN rising_edge(o_clk);

	-----------------------------------------------------------------------------
	-- Output Vertical Divider
	-- Vfrac = Vacc / Vsize
	ODivider:PROCESS (o_clk,o_reset_na) IS
	BEGIN
		IF o_reset_na='0' THEN
--pragma synthesis_off
			o_vfrac<=x"000";
--pragma synthesis_on
		ELSIF rising_edge(o_clk) THEN
			o_vdivi<=to_unsigned(2*o_vsize,13);
			o_vdivr<=to_unsigned(o_vacc*4096,25);
			------------------------------------------------------
			IF o_divstart='1' THEN
				o_divcpt<=0;
				o_divrun<='1';

			ELSIF o_divrun='1' THEN
				----------------------------------------------------
				IF o_divcpt=12 THEN
					o_divrun<='0';
					o_vfrac<=o_vdivr(10 DOWNTO 0) & NOT o_vdivr(24);
				ELSE
					o_divcpt<=o_divcpt+1;
				END IF;

				IF o_vdivr(24)='0' THEN
					o_vdivr(24 DOWNTO 12)<=o_vdivr(23 DOWNTO 11) - o_vdivi;
				ELSE
					o_vdivr(24 DOWNTO 12)<=o_vdivr(23 DOWNTO 11) + o_vdivi;
				END IF;
				o_vdivr(11 DOWNTO 0)<=o_vdivr(10 DOWNTO 0) & NOT o_vdivr(24);
				----------------------------------------------------
			END IF;
		END IF;
	END PROCESS ODivider;

	-----------------------------------------------------------------------------
	Scalaire:PROCESS (o_clk,o_reset_na) IS
		VARIABLE lev_inc_v,lev_dec_v : std_logic;
		VARIABLE prim_v,last_v,bib_v : std_logic;
		VARIABLE shift_v : unsigned(0 TO N_DW+15);
		VARIABLE hpix_v : type_pix;
		VARIABLE hcarry_v,vcarry_v : boolean;
		VARIABLE dif_v : natural RANGE 0 TO 8*OHRESH-1;
		VARIABLE off_v : natural RANGE 0 TO 15;
	BEGIN
		IF NOT CONFIG_HANDSHAKE AND o_reset_na='0' THEN
			o_copy<=sWAIT;
			o_state<=sDISP;
			o_read_pre<='0';
			o_readlev<=0;
			o_copylev<=0;
			o_hsp<='0';
			IF CONFIG_HANDSHAKE THEN
				o_bibu<='0';
				o_copyv(0)<='0';
				o_readack_sync<='0'; o_readack_sync2<='0'; o_readack_sync3<='0';
				o_readdataack_sync<='0'; o_readdataack_sync2<='0'; o_readdataack_sync3<='0';
				o_readack<='0'; o_readdataack<='0';
			END IF;

		ELSIF rising_edge(o_clk) THEN
			-- Transport phase, offered reads and return credits are independent
			-- of logical configuration reset. Never manufacture an ACK by reset.
			o_readack_sync<=avl_readack; -- <ASYNC>
			o_readack_sync2<=o_readack_sync;
			IF CONFIG_HANDSHAKE THEN
				o_readack_sync3<=o_readack_sync2;
				o_readack<=o_readack_sync2 XOR o_readack_sync3;
				o_completed_meta<=avl_completed_gray; -- <ASYNC>
				o_completed_sync<=o_completed_meta;
				o_readdataack<='0';
				IF ((o_completed_seen SRL 1) XOR o_completed_seen)/=o_completed_sync THEN
					o_completed_seen<=o_completed_seen+1;
					o_readdataack<='1';
				END IF;
				o_read<=o_read_pre;
			ELSE
				o_readack<=o_readack_sync XOR o_readack_sync2;
				o_readdataack_sync<=avl_readdataack; -- <ASYNC>
				o_readdataack_sync2<=o_readdataack_sync;
				o_readdataack<=o_readdataack_sync XOR o_readdataack_sync2;
			END IF;

			lev_inc_v:='0';
			lev_dec_v:='0';
			IF CONFIG_HANDSHAKE THEN
				o_isync<='0'; o_isync2<=o_isync;
				IF o_native_pending='0' AND o_native_sync/=o_native_ack THEN
					o_native_capture<=i_native_context;
					o_native_phase<=o_native_sync;
					o_native_pending<='1'; o_native_announced<='0';
				ELSIF o_native_pending='1' AND
					(o_reset_na='0' OR o_native_refresh='1' OR
					 o_native_capture(36)/=o_native_epoch OR
					 o_native_capture(35)/=cfg_req_sync) THEN
					o_native_ack<=o_native_phase;
					o_native_pending<='0'; o_native_announced<='0';
				END IF;
			END IF;
			IF CONFIG_HANDSHAKE AND (o_reset_na='0' OR cfg_initialized='0') THEN
				-- Discard completed old-epoch copies, including a cancelled
				-- partial copy. Keep offered metadata and both burst-RAM phases.
				o_copy<=sWAIT; o_state<=sDISP; o_hsp<='0';
				o_copyv(0)<='0';
				o_sh<='0'; o_sh1<='0'; o_sh2<='0'; o_sh3<='0'; o_sh4<='0';
				o_fload<=0; o_adrsa<='0'; o_adrsb<='0';
				o_prim<=true; o_vcarrym<=false;
				o_prime_started<='0';
				o_native_valid<='0'; o_native_stream<='0'; o_native_math_valid<="0000";
				IF o_copylev>0 THEN lev_dec_v:='1'; END IF;
			ELSE
			------------------------------------------------------
			IF CONFIG_HANDSHAKE THEN
				o_format<="0001" & o_native_format;
			ELSE
				o_format<="0001" & format; -- <ASYNC>
			END IF;

			o_hsize  <=o_hmax - o_hmin + 1;
			o_vsize  <=o_vmax - o_vmin + 1;

			--------------------------------------------
			-- Triple buffering.
			-- For intelaced video, half frames are updated independently
			-- Input : Toggle buffer at end of input frame
			IF NOT CONFIG_HANDSHAKE THEN
			o_isync <= '0';
			o_isync2 <= o_isync;
			o_iwfl <= i_wfl;
			o_inter  <=i_inter; -- <ASYNC>
			o_iendframe0<=i_endframe0; -- <ASYNC>
			o_iendframe02<=o_iendframe0;
			IF o_iendframe0='1' AND o_iendframe02='0' THEN
				o_ibuf0<=buf_next(o_ibuf0,o_obuf0,o_freeze);
				o_bufup0<='1';
				o_isync <= '1';
			END IF;
			o_iendframe1<=i_endframe1; -- <ASYNC>
			o_iendframe12<=o_iendframe1;
			IF o_iendframe1='1' AND o_iendframe12='0' THEN
				o_ibuf1<=buf_next(o_ibuf1,o_obuf1,o_freeze);
				o_bufup1<='1';
				o_isync <= '1';
			END IF;

			-- Output : Change framebuffer, and image properties, at VS falling edge
			IF o_vsv(1)='1' AND o_vsv(0)='0' AND o_bufup0='1' THEN
				o_obuf0<=buf_next(o_obuf0,o_ibuf0,o_freeze);
				o_bufup0<='0';
			END IF;
			IF o_vsv(1)='1' AND o_vsv(0)='0' AND o_bufup1='1' THEN
				o_obuf1<=buf_next(o_obuf1,o_ibuf1,o_freeze);
				o_bufup1<='0';
				o_ihsize<=i_hrsize; -- <ASYNC>
				o_ivsize<=i_vrsize; -- <ASYNC>
				o_hdown<=i_hdown; -- <ASYNC>
				o_vdown<=i_vdown; -- <ASYNC>

				IF (o_newres > 0) then
					o_newres <= o_newres- 1;
				END IF;
			END IF;

			IF (c_swblack = '1' and c_fb_ena = '0' and (o_ihsize /= i_hrsize or o_ivsize /= i_vrsize)) then
				o_newres <= 3;
			END IF;

			-- Simultaneous change of input and output framebuffers
			IF o_vsv(1)='1' AND o_vsv(0)='0' AND
				o_iendframe0='1' AND o_iendframe02='0' THEN
				o_bufup0<='0';
				o_obuf0<=o_ibuf0;
			END IF;
			IF o_vsv(1)='1' AND o_vsv(0)='0' AND
				o_iendframe1='1' AND o_iendframe12='0' THEN
				o_bufup1<='0';
				o_obuf1<=o_ibuf1;
			END IF;

			-- Non-interlaced, use same buffer for even and odd lines
			IF o_inter='0' THEN
				o_ibuf1<=o_ibuf0;
				o_obuf1<=o_obuf0;
			END IF;

			-- Triple buffer disabled
			IF o_mode(3)='0' THEN
				o_obuf0<=0;
				o_obuf1<=0;
				o_ibuf0<=0;
				o_ibuf1<=0;
			END IF;
			ELSE
				o_native_math_valid<=o_native_math_valid(2 DOWNTO 0) & o_native_valid;
				IF cfg_apply='1' THEN o_native_math_valid<="0000"; END IF;
				IF cfg_apply='1' AND cfg_capture(104)='0' AND o_cfg_active(104)='1' THEN
					o_native_valid<='0'; o_prime_started<='0'; o_native_stream<='0';
				END IF;
				IF c_fb_ena='1' OR o_mode(3)='1' THEN o_native_stream<='0'; END IF;
				IF o_native_valid='1' AND o_bootstrap='0' AND c_fb_ena='0' AND
					o_mode(3)='0' AND o_vsv(1)='1' AND o_vsv(0)='0' THEN
					-- Low-latency mode keeps its existing single-buffer streaming
					-- semantics, but only after the first owned frame is displayed.
					o_native_stream<='1';
				END IF;
				IF o_native_pending='1' AND o_native_refresh='0' AND o_native_epoch_wait='0' AND
					o_native_capture(36)=o_native_epoch AND
					o_native_capture(35)=cfg_req_sync AND o_native_capture(35)=o_cfg_epoch THEN
					IF c_fb_ena='1' THEN
						o_native_ack<=o_native_phase; o_native_pending<='0';
					ELSE
					-- Availability is not adoption. VRR needs the completed
					-- eligible image during the current adjustable porch.
					IF o_native_announced='0' THEN
						o_isync<='1'; o_native_announced<='1';
					END IF;
					IF (o_native_valid='0' OR (o_vsv(1)='1' AND o_vsv(0)='0')) AND
						o_readlev=0 AND o_copylev=0 AND o_state=sDISP AND o_copy=sWAIT AND
						o_copyv=(o_copyv'RANGE =>'0') AND o_wr="0000" THEN
						o_ihsize<=to_integer(o_native_capture(11 DOWNTO 0));
						o_ivsize<=to_integer(o_native_capture(23 DOWNTO 12));
						o_obuf0<=to_integer(o_native_capture(25 DOWNTO 24));
						o_obuf1<=to_integer(o_native_capture(25 DOWNTO 24));
						o_native_format<=o_native_capture(27 DOWNTO 26);
						o_hdown<=o_native_capture(28); o_vdown<=o_native_capture(29);
						o_inter<=o_native_capture(30);
						o_iwfl<=std_logic_vector(o_native_capture(34 DOWNTO 32));
						o_native_release<='1' & o_native_capture(25 DOWNTO 24);
						o_native_ack<=o_native_phase; o_native_valid<='1'; o_native_pending<='0';
						o_native_math_valid<="0000";
						IF c_swblack='1' AND
							(o_ihsize/=to_integer(o_native_capture(11 DOWNTO 0)) OR
							 o_ivsize/=to_integer(o_native_capture(23 DOWNTO 12))) THEN
							o_newres<=3;
						ELSIF o_newres>0 THEN o_newres<=o_newres-1; END IF;
					END IF;
					END IF;
				END IF;
			END IF;

			-- Framebuffer mode.
			IF c_fb_ena='1' THEN
				o_ihsize<=c_fb_hsize;
				o_ivsize<=c_fb_vsize;
				o_format<=c_fb_format;
				o_hdown<='0';
				o_vdown<='0';
			END IF;

			-- 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
			CASE o_format(2 DOWNTO 0) IS
				WHEN "011" => o_ihsize_temp <= o_ihsize;
				WHEN "100" => o_ihsize_temp <= o_ihsize * 2;
				WHEN "110" => o_ihsize_temp <= o_ihsize * 4;
				WHEN OTHERS => o_ihsize_temp <= o_ihsize * 3;
			END CASE;

			o_ihsize_temp2 <= (o_ihsize_temp + N_BURST - 1);
			-- Encode the terminal count at the original configuration stage.
			-- -1 preserves the zero-burst comparison, including initialization.
			o_hburst_last <= o_ihsize_temp2 / N_BURST - 1;

			IF c_fb_ena='1' AND c_fb_stride /= 0 THEN
				o_stride<=c_fb_stride;
			ELSE
				o_stride<=to_unsigned(o_ihsize_temp2,14);
				o_stride(NB_BURST-1 DOWNTO 0)<=(OTHERS =>'0');
			END IF;
			------------------------------------------------------
			o_hmode<=o_mode;
			IF o_hdown='1' AND DOWNSCALE THEN
				-- Force nearest if downscaling : Downscaled framebuffer
				o_hmode(2 DOWNTO 0)<="000";
			END IF;

			o_vmode<=o_mode;
			IF o_vdown='1' AND DOWNSCALE THEN
				-- Force nearest if downscaling : Downscaled framebuffer
				o_vmode(2 DOWNTO 0)<="000";
			END IF;

			------------------------------------------------------
			-- acpt : Pixel position within current data word
			-- dcpt : Destination image position

			-- Force preload 2 lines at top of screen
			IF o_hsv(0)='1' AND o_hsv(1)='0' THEN
				IF (o_vcpt_pre3=o_vmin OR o_bootstrap='1') AND o_prime_started='0' AND
					(NOT CONFIG_HANDSHAKE OR c_fb_ena='1' OR o_native_math_valid(3)='1') THEN
					o_fload<=2;
					IF o_bootstrap='1' THEN o_prime_started<='1'; END IF;
					IF NOT CONFIG_HANDSHAKE THEN o_bibu<='0'; END IF;
				END IF;
				o_hsp<='1';
			END IF;
			IF o_vsv(1)='1' AND o_vsv(0)='0' THEN o_prime_started<='0'; END IF;

			o_vpe<=to_std_logic(o_vcpt_pre<o_vmax AND o_vcpt_pre>=o_vmin);
			o_divstart<='0';
			o_adrsa<='0';
			o_adrsb<=o_adrsa;

			o_vacc_ini<=(o_vsize - o_ivsize + 8192) MOD 8192;
			o_hacc_ini<=(o_hsize + o_ihsize + 8192) MOD 8192;

			--Alternate phase
			--o_vacc_ini<=o_ivsize;
			--o_hacc_ini<=(2*o_hsize - o_ihsize + 8192) MOD 8192;

			CASE o_state IS
					--------------------------------------------------
				WHEN sDISP =>
					IF o_hsp='1' THEN
						o_state<=sHSYNC;
						o_hsp<='0';
					END IF;
					o_prim<=true;
					o_vcarrym<=false;

					--------------------------------------------------
				WHEN sHSYNC =>
					dif_v :=(o_vacc_next - 2*o_vsize + 16384) MOD 16384;
					IF o_prim THEN
						IF dif_v>=8192 THEN
							o_vacc     <=o_vacc_next;
						ELSE
							o_vacc     <=dif_v;
						END IF;
					END IF;
					IF dif_v>=8192 THEN
						o_vacc_next<=(o_vacc_next + 2*o_ivsize) MOD 8192;
						vcarry_v:=false;
					ELSE
						o_vacc_next<=dif_v;
						vcarry_v:=true;
					END IF;

					IF o_vcpt_pre2=o_vmin OR o_bootstrap='1' THEN
						o_vacc     <=o_vacc_ini;
						o_vacc_next<=o_vacc_ini + 2*o_ivsize;
						o_vacpt <=x"001";
						o_vacptl<="01";
						vcarry_v:=false;
					END IF;

					IF vcarry_v THEN
						o_vacpt<=o_vacpt+1;
					END IF;
					IF vcarry_v AND o_prim THEN
						o_vacptl<=o_vacptl+1;
					END IF;
					o_vcarrym <= o_vcarrym OR vcarry_v;
					o_prim <= false;
					o_hbcpt<=0; -- Clear burst counter on line
					o_divstart<=to_std_logic(NOT vcarry_v);
					IF NOT vcarry_v  OR o_fload>0 THEN
						IF (o_vpe='1' AND o_vcarrym) OR o_fload>0 THEN
							o_state<=sREAD;
						ELSE
							o_state<=sDISP;
						END IF;
					END IF;
					IF o_bootstrap='1' AND o_fload=0 THEN o_state<=sDISP; END IF;

				WHEN sREAD =>
					-- Read a block
					IF o_readlev<2 AND o_adrsb='1' AND (NOT CONFIG_HANDSHAKE OR o_run='1') THEN
						lev_inc_v:='1';
						o_read_pre<=NOT o_read_pre;
						o_state <=sWAITREAD;
						o_bibu<=NOT o_bibu;
						IF CONFIG_HANDSHAKE THEN
							IF c_fb_ena='1' THEN
								o_read_base<=c_fb_base;
							ELSIF o_rline='0' THEN
								o_read_base<=buf_offset(o_obuf0,RAMBASE,RAMSIZE);
								IF HEADER THEN o_read_base<=buf_offset(o_obuf0,RAMBASE,RAMSIZE)+N_BURST; END IF;
							ELSE
								o_read_base<=buf_offset(o_obuf1,RAMBASE,RAMSIZE);
								IF HEADER THEN o_read_base<=buf_offset(o_obuf1,RAMBASE,RAMSIZE)+N_BURST; END IF;
							END IF;
						END IF;
					END IF;
					prim_v:=to_std_logic(o_hbcpt=0);
					last_v:=to_std_logic(o_hbcpt=o_hburst_last);
					bib_v :=o_bibu;
					off_v :=pixoffset(o_adrs + c_fb_base(NB_LA-1 DOWNTO 0),c_fb_format);
					IF c_fb_ena='0' THEN
						off_v:=0;
					END IF;
					o_adrsa<='1';

				WHEN sWAITREAD =>
					IF o_readack='1' THEN
						o_hbcpt<=o_hbcpt+1;
						IF o_hbcpt<o_hburst_last THEN
							-- If not finshed line, read more
							o_state<=sREAD;
						ELSE
							o_state<=sDISP;
							IF o_fload>=1 THEN
								o_fload<=o_fload-1;
							END IF;
						END IF;
					END IF;

					--------------------------------------------------
			END CASE;

			IF NOT CONFIG_HANDSHAKE THEN o_read<=o_read_pre AND o_run; END IF;
			o_rline<=o_vacpt(0); -- Even/Odd line for interlaced video

			----
			-- When bob deinterlacing we read lines from one buffer (the most current) but we read them twice
			-- (in contrast to weave deinterlacing where we read each 480p line from alternating buffers)
			-- To counteract the severe vibrating/motion with bob deinterlacing, we need to offset one field
			-- by a half-line. This is done by only reading the first line of the 'even' frame once

			IF o_inter='1' AND o_bob_deint='1' THEN
				IF o_iwfl(o_obuf0)='0' THEN
					IF o_vacpt=0 OR o_rline='1' THEN
						o_adrs_pre <= to_integer(o_vacpt) * to_integer(o_stride);
					ELSE
						o_adrs_pre <= (to_integer(o_vacpt)-1) * to_integer(o_stride);
					END IF;
				ELSE
					o_adrs_pre <= to_integer(o_vacpt(11 DOWNTO 1) & "0") * to_integer(o_stride);
				END IF;
			ELSE
				o_adrs_pre<=to_integer(o_vacpt) * to_integer(o_stride);
			END IF;

			IF o_adrsa='1' THEN
				IF o_fload=2 THEN
					o_adrs<=to_unsigned(o_hbcpt * N_BURST,32);
					o_alt<="1111";
				ELSIF o_fload=1 THEN
					o_adrs<=to_unsigned(o_hbcpt * N_BURST,32) + o_stride;
					o_alt<="0100";
				ELSE
					o_adrs<=to_unsigned(o_adrs_pre + (o_hbcpt * N_BURST),32);
					o_alt<=altx(o_vacptl + 1);
				END IF;
			END IF;

			------------------------------------------------------
			-- Copy from buffered memory to pixel lines
			o_sh<='0';
			o_dcpt_clr <= '0';
			o_dcpt_inc <= '0';

			CASE o_copy IS
				WHEN sWAIT =>
					o_copyv(0)<='0';
					-- The previous copy can still be shifting/writing its tail
					-- after sCOPY retires. Do not rearm left-edge metadata yet.
					IF o_copylev>0 AND o_copyv=(o_copyv'RANGE =>'0') AND
						o_sh='0' AND o_sh1='0' AND o_sh2='0' AND o_sh3='0' AND o_sh4='0' AND o_wr="0000" THEN
						o_copy<=sCOPY;
						IF o_off(0)>0 AND o_primv(0)='1' THEN
							o_copy<=sSHIFT;
						END IF;
						IF CONFIG_HANDSHAKE THEN o_altx<=to_unsigned(o_altv(0),4);
						ELSE o_altx<=o_alt; END IF;
					o_adturn<='0';
					o_pshift<=(o_off(0) + 15) MOD 16;
					IF o_primv(0)='1' THEN
						-- First memcopy of a horizontal line, carriage return !
						o_ihsizem<=o_ihsize + o_off(0) - 2;
						o_hacc     <=o_hacc_ini;
						o_hacc_next<=o_hacc_ini + 2*o_ihsize;
						o_hacpt    <=x"000";
						o_dcpt_clr <= '1';
						o_dshi<=2;
						o_acpt<=0;
						o_first<='1';
						o_last<='0';
					END IF;

					IF o_bibv(0)='0' THEN
						o_ad<=0;
					ELSE
						o_ad<=BLEN;
					END IF;
					END IF;

				WHEN sSHIFT =>
					o_hacpt<=o_hacpt+1;
					o_sh<='1';
					o_acpt<=(o_acpt+1) MOD 16;
					IF shift_onext(o_acpt,o_format) THEN
						o_ad<=(o_ad+1) MOD (2*BLEN);
					END IF;
					o_pshift<=(o_pshift+15) MOD 16;
					IF o_pshift=0 THEN
						o_copy<=sCOPY;
					END IF;

				WHEN sCOPY =>
					-- dshi : Force shift first two or three pixels of each line
					IF o_dshi=0 THEN
						dif_v:=(o_hacc_next - 2*o_hsize + (8*OHRESH)) MOD (8*OHRESH);
						IF dif_v>=4*OHRESH THEN
							o_hacc<=o_hacc_next;
							o_hacc_next<=o_hacc_next + 2*o_ihsize;
							hcarry_v:=false;
						ELSE
							o_hacc<=dif_v;
							o_hacc_next<=(dif_v + 2*o_ihsize + (4*OHRESH)) MOD (4*OHRESH);
							hcarry_v:=true;
						END IF;
						o_dcpt_inc <= '1';
					ELSE
						o_dshi<=o_dshi-1;
						hcarry_v:=false;
					END IF;
					IF o_dshi<=1 THEN
						o_copyv(0)<='1';
					END IF;
					IF hcarry_v THEN
						o_hacpt<=o_hacpt+1;
						o_last <=to_std_logic(o_hacpt>=o_ihsizem);
					END IF;

					IF hcarry_v OR o_dshi>0 THEN
						o_sh<='1';
						o_acpt<=(o_acpt+1) MOD 16;

						-- Shift two more pixels to the right before ending line.
						o_last1<=o_last;
						o_last2<=o_last1;

						IF shift_onext(o_acpt,o_format) THEN
							o_ad<=(o_ad+1) MOD (2*BLEN);
						END IF;

						IF o_adturn='1' AND (shift_onext((o_acpt+1) MOD 16,o_format)) AND
							(((o_ad MOD BLEN=0) AND o_lastv(0)='0') OR o_last2='1')  THEN
							o_copy<=sWAIT;
							lev_dec_v:='1';
						END IF;

						IF o_ad MOD BLEN=4 THEN
							o_adturn<='1';
						END IF;
					END IF;
			END CASE;

			o_acpt1<=o_acpt; o_acpt2<=o_acpt1; o_acpt3<=o_acpt2; o_acpt4<=o_acpt3;
			o_ad1<=o_ad; o_ad2<=o_ad1; o_ad3<=o_ad2;
			o_sh1<=o_sh; o_sh2<=o_sh1; o_sh3<=o_sh2; o_sh4<=o_sh3;
			o_lastt1<=o_last;   o_lastt2<=o_lastt1;
			o_lastt3<=o_lastt2; o_lastt4<=o_lastt3;

			------------------------------------------------------
			IF o_sh3='1' THEN
				shift_v:=shift_opack(o_acpt4,o_shift,o_dr,o_format);
				o_shift<=shift_v;
				o_hpixs<=shift_opix(shift_v,o_format);
			END IF;

			IF o_sh4='1' THEN
				hpix_v:=o_hpixs;
				IF o_format(4)='1' THEN -- Swap B <-> R
					hpix_v:=(r=>o_hpixs.b,g=>o_hpixs.g,b=>o_hpixs.r);
				END IF;
				IF o_format(2 DOWNTO 0)="011" THEN
					-- 8bpp indexed colour mode
					hpix_v:=(r=>o_fb_pal_dr(23 DOWNTO 16),g=>o_fb_pal_dr(15 DOWNTO 8),
									 b=>o_fb_pal_dr(7 DOWNTO 0));
				END IF;
				IF (o_newres > 0) then
					hpix_v := (others => (others => '0'));
				END IF;
				o_hpix0<=hpix_v;
				o_hpix1<=o_hpix0;
				o_hpix2<=o_hpix1;
				o_hpix3<=o_hpix2;

				IF o_first='1' THEN
					-- Left edge. Duplicate first pixel
					o_hpix1<=hpix_v;
					o_hpix2<=hpix_v;
					o_first<='0';
				END IF;
				IF o_lastt4='1' THEN
					-- Right edge. Keep last pixel.
					o_hpix0<=o_hpix0;
				END IF;
			END IF;

			END IF;
			------------------------------------------------------
			-- lev_inc : read start
			-- lev_dec : end of copy
			-- READLEV : Number of ongoing Avalon Reads
			IF lev_dec_v='0' AND lev_inc_v='1' THEN
				ASSERT o_readlev<2 REPORT "Scaler read ownership overflow" SEVERITY failure;
				o_readlev<=o_readlev+1;
			ELSIF lev_dec_v='1' AND lev_inc_v='0' THEN
				ASSERT o_readlev>0 REPORT "Scaler read ownership underflow" SEVERITY failure;
				o_readlev<=o_readlev-1;
			END IF;

			-- COPYLEV : Number of ongoing copies to line buffers
			IF lev_dec_v='1' AND o_readdataack='0' THEN
				ASSERT o_copylev>0 REPORT "Scaler orphan copy" SEVERITY failure;
				o_copylev<=o_copylev-1;
			ELSIF lev_dec_v='0' AND o_readdataack='1' THEN
				ASSERT o_copylev<2 REPORT "Scaler completion ownership overflow" SEVERITY failure;
				o_copylev<=o_copylev+1;
			END IF;

			-- FIFOs
			IF lev_dec_v='1' THEN
				o_primv(0 TO 1)<=o_primv(1 TO 2); -- First buffer of line
				o_lastv(0 TO 1)<=o_lastv(1 TO 2); -- Last buffer of line
				o_bibv (0 TO 1)<=o_bibv (1 TO 2); -- Double buffer select
				o_off  (0 TO 1)<=o_off  (1 TO 2); -- Start offset
				o_altv (0 TO 1)<=o_altv (1 TO 2); -- Owned line-buffer write mask
			END IF;

			IF lev_inc_v='1' THEN
				IF o_readlev=0 OR (o_readlev=1 AND lev_dec_v='1') THEN
					o_primv(0)<=prim_v;
					o_lastv(0)<=last_v;
					o_bibv (0)<=bib_v;
					o_off  (0)<=off_v;
					o_altv (0)<=to_integer(o_alt);
				ELSIF (o_readlev=1 AND lev_dec_v='0') OR
							(o_readlev=2 AND lev_dec_v='1') THEN
					o_primv(1)<=prim_v;
					o_lastv(1)<=last_v;
					o_bibv (1)<=bib_v;
					o_off  (1)<=off_v;
					o_altv (1)<=to_integer(o_alt);
				END IF;
				o_primv(2)<=prim_v;
				o_lastv(2)<=last_v;
				o_bibv (2)<=bib_v;
				o_off  (2)<=off_v;
				o_altv (2)<=to_integer(o_alt);
			END IF;

			------------------------------------------------------
		END IF;
	END PROCESS Scalaire;

	-- Fetch polyphase coefficients
	PolyFetch:PROCESS (o_clk) IS
		VARIABLE hfrac3_v, vfrac_v : unsigned(FRAC-1 DOWNTO 0);
	BEGIN
		IF rising_edge(o_clk) THEN
			hfrac3_v:=o_hfrac(3)(11 DOWNTO 12-FRAC);
			vfrac_v:=o_vfrac(11 DOWNTO 12-FRAC);

			o_v_poly_use_adaptive <= to_std_logic((o_vmode(2 DOWNTO 0)/="000") AND (o_v_poly_adaptive = '1'));
			o_h_poly_use_adaptive <= to_std_logic((o_hmode(2 DOWNTO 0)/="000") AND (o_h_poly_adaptive = '1'));
			o_v_poly_addr<=to_integer(o_vfrac(11 DOWNTO 12-FRAC));

			-- C3 / HC3 / VC4
			IF o_vmode(2 DOWNTO 0)/="000" THEN
				o_v_poly_phase_a<=poly_unpack(o_v_poly_mem(o_v_poly_addr));
			ELSE
				o_v_poly_phase_a<=poly_nn(vfrac_v);
			END IF;

			IF o_hmode(2 DOWNTO 0)/="000" THEN
				o_h_poly_phase_a<=poly_unpack(o_h_poly_mem(to_integer(hfrac3_v)));
			ELSE
				o_h_poly_phase_a<=poly_nn(hfrac3_v);
			END IF;

			IF o_v_poly_use_adaptive='1' THEN
				o_poly_lum<=poly_lum(o_v_lum_pix);
				o_a_poly_addr<=o_v_poly_addr;
			ELSIF o_h_poly_use_adaptive='1' THEN
				o_poly_lum<=poly_lum(o_h_lum_pix);
				o_a_poly_addr<=to_integer(hfrac3_v);
			END IF;

			-- C4 / HC4 / VC5
			o_poly_phase_b<=poly_unpack(o_a_poly_mem(o_a_poly_addr));

			IF o_v_poly_use_adaptive='1' THEN
				o_poly_phase_a<=o_v_poly_phase_a;
			ELSIF o_h_poly_use_adaptive = '1' THEN
				o_poly_phase_a<=o_h_poly_phase_a;
			END IF;

			o_h_poly_phase_a2<=o_h_poly_phase_a;
			o_v_poly_phase_a2<=o_v_poly_phase_a;
			o_poly_lum1<=o_poly_lum;

			-- C5 / HC5 / VC6
			o_poly_lerp_t<=signed('0' & o_poly_lum1);
			o_poly_phase_diff<=poly_diff(o_poly_phase_a, o_poly_phase_b);
			o_poly_phase_a2<=o_poly_phase_a;

			o_h_poly_phase_a3<=o_h_poly_phase_a2;
			o_v_poly_phase_a3<=o_v_poly_phase_a2;

			-- C6 / HC6 / VC7
			-- Four products instead of four sum-of-two-products DSP cones.
			-- The former C7 delay now adds A*256; coefficient latency is unchanged.
			o_poly_phase_product<=poly_product(o_poly_phase_diff, o_poly_lerp_t);
			o_poly_phase_a3<=o_poly_phase_a2;
			o_h_poly_phase_a4<=o_h_poly_phase_a3;
			o_v_poly_phase_a4<=o_v_poly_phase_a3;

			-- C7 / HC7 / VC8
			o_h_poly_phase_a5<=o_h_poly_phase_a4;
			o_v_poly_phase_a5<=o_v_poly_phase_a4;
			o_poly_phase1<=poly_lerp(o_poly_phase_a3, o_poly_phase_product);

			-- C8 / HC8 / VC9
			o_v_poly_phase<=poly_cvt(o_v_poly_phase_a5);
			o_h_poly_phase<=poly_cvt(o_h_poly_phase_a5);

			IF o_v_poly_use_adaptive = '1' THEN
				o_v_poly_phase<=o_poly_phase1;
			ELSIF o_h_poly_use_adaptive = '1' THEN
				o_h_poly_phase<=o_poly_phase1;
			END IF;

		END IF;
	END PROCESS PolyFetch;


	-- Framebuffer palette
	GenPal1:IF PALETTE GENERATE
		Tempera1:PROCESS(pal1_clk) IS
		BEGIN
			IF rising_edge(pal1_clk) THEN
				IF pal1_wr='1' THEN
					IF CONFIG_HANDSHAKE THEN
						pal1_mem(to_integer(pal1_bank & pal1_a))<=pal1_dw;
					ELSE
						pal1_mem(to_integer(pal1_a))<=pal1_dw;
					END IF;
				END IF;
				IF CONFIG_HANDSHAKE THEN
					pal1_dr<=pal1_mem(to_integer(pal1_bank & pal1_a));
				ELSE
					pal1_dr<=pal1_mem(to_integer(pal1_a));
				END IF;
			END IF;
		END PROCESS;

		pal_idx <= shift_opack(o_acpt4,o_shift,o_dr,o_format)(0 TO 7);
		pal_idx_lsb <= pal_idx(0) WHEN rising_edge(o_clk);
		BankedPalette:IF CONFIG_HANDSHAKE GENERATE
			o_fb_pal_dr_x2<=pal1_mem(to_integer(o_palette_bank & pal_idx(7 DOWNTO 1)))
				WHEN rising_edge(o_clk);
		END GENERATE;
		UnbankedPalette:IF NOT CONFIG_HANDSHAKE GENERATE
			o_fb_pal_dr_x2<=pal1_mem(to_integer(pal_idx(7 DOWNTO 1))) WHEN rising_edge(o_clk);
		END GENERATE;
	END GENERATE GenPal1;

	GenPal2:IF PALETTE and PALETTE2 GENERATE
		Tempera2:PROCESS(pal2_clk) IS
		BEGIN
			IF rising_edge(pal2_clk) THEN
				IF pal2_wr='1' THEN
					pal2_mem(to_integer(pal2_a))<=pal2_dw;
				END IF;
				pal2_dr<=pal2_mem(to_integer(pal2_a));
			END IF;
		END PROCESS;

		o_fb_pal_dr2 <= pal2_mem(to_integer(pal_idx(7 DOWNTO 0))) WHEN rising_edge(o_clk);
		o_fb_pal_dr <= o_fb_pal_dr2 when c_pal_n = '1' else o_fb_pal_dr_x2(47 DOWNTO 24) WHEN pal_idx_lsb = '1' ELSE o_fb_pal_dr_x2(23 DOWNTO 0);
	END GENERATE GenPal2;

	GenPal1not2:IF PALETTE and not PALETTE2 GENERATE
		o_fb_pal_dr <= o_fb_pal_dr_x2(47 DOWNTO 24) WHEN pal_idx_lsb = '1' ELSE o_fb_pal_dr_x2(23 DOWNTO 0);
	END GENERATE GenPal1not2;

	GenNoPal:IF NOT PALETTE GENERATE
		o_fb_pal_dr<=x"000000";
	END GENERATE GenNoPal;

	-----------------------------------------------------------------------------
	-- Polyphase ROMs
	Polikarpov:PROCESS(poly_clk) IS
	BEGIN
		IF rising_edge(poly_clk) THEN
			IF poly_wr='1' THEN
				poly_tdw(9+10*(3-to_integer(poly_a(1 DOWNTO 0))) DOWNTO
									 10*(3-to_integer(poly_a(1 DOWNTO 0))))<=poly_dw;
			END IF;

			poly_wr_mode(0)<=poly_wr AND NOT poly_a(FRAC+2);
			poly_wr_mode(1)<=poly_wr AND poly_a(FRAC+2);
			poly_wr_mode(2)<=poly_wr AND poly_a(FRAC+3) AND to_std_logic(ADAPTIVE);
			poly_a2<=poly_a(FRAC+1 DOWNTO 2);

			CASE poly_wr_mode IS
				WHEN "001" => -- horiz
					o_h_poly_mem(to_integer(poly_a2))<=poly_tdw;
					o_h_poly_adaptive<='0';
				WHEN "010" => -- vert
					o_v_poly_mem(to_integer(poly_a2))<=poly_tdw;
					o_v_poly_adaptive<='0';
				WHEN "101" => -- horiz adaptive
					o_a_poly_mem(to_integer(poly_a2))<=poly_tdw;
					o_h_poly_adaptive<='1';
				WHEN "110" => -- vert adaptive
					o_a_poly_mem(to_integer(poly_a2))<=poly_tdw;
					o_v_poly_adaptive<='1';
				WHEN OTHERS => NULL;
			END CASE;
		END IF;
	END PROCESS Polikarpov;

	-----------------------------------------------------------------------------
	-- Horizontal Scaler
	HSCAL:PROCESS(o_clk) IS
		VARIABLE div_v : unsigned(20 DOWNTO 0);
		VARIABLE dir_v : unsigned(11 DOWNTO 0);
		VARIABLE mag_v : unsigned(19 DOWNTO 0);
		VARIABLE ge2_v,ge4_v,ge6_v : std_logic;
	BEGIN
		IF rising_edge(o_clk) THEN
			-- Pipeline signals
			-----------------------------------
			-- Pipelined 8 bits non-restoring divider. Cycle 1
			dir_v:=x"000";
			div_v:=to_unsigned(o_hacc * 256,21);

			div_v:=div_v-to_unsigned(o_hsize*256,21);
			dir_v(11):=NOT div_v(20);
			IF div_v(20)='0' THEN
				div_v:=div_v-to_unsigned(o_hsize*128,21);
			ELSE
				div_v:=div_v+to_unsigned(o_hsize*128,21);
			END IF;
			dir_v(10):=NOT div_v(20);

			o_div(0)<=div_v;
			o_dir(0)<=dir_v;

			-- Cycle 2
			div_v:=o_div(0);
			dir_v:=o_dir(0);
			IF div_v(20)='0' THEN
				div_v:=div_v-to_unsigned(o_hsize*64,21);
			ELSE
				div_v:=div_v+to_unsigned(o_hsize*64,21);
			END IF;
			dir_v( 9):=NOT div_v(20);

			IF div_v(20)='0' THEN
				div_v:=div_v-to_unsigned(o_hsize*32,21);
			ELSE
				div_v:=div_v+to_unsigned(o_hsize*32,21);
			END IF;
			dir_v( 8):=NOT div_v(20);

			o_div(1)<=div_v;
			o_dir(1)<=dir_v;

			-- Cycle 3
			div_v:=o_div(1);
			dir_v:=o_dir(1);
			IF FRAC>4 THEN
				IF div_v(20)='0' THEN
					div_v:=div_v-to_unsigned(o_hsize*16,21);
				ELSE
					div_v:=div_v+to_unsigned(o_hsize*16,21);
				END IF;
				dir_v(7):=NOT div_v(20);

				IF div_v(20)='0' THEN
					div_v:=div_v-to_unsigned(o_hsize*8,21);
				ELSE
					div_v:=div_v+to_unsigned(o_hsize*8,21);
				END IF;
				dir_v(6):=NOT div_v(20);
			END IF;
			o_div(2)<=div_v;
			o_dir(2)<=dir_v;

			div_v:=o_div(2);
			dir_v:=o_dir(2);
			IF FRAC>6 THEN
				-- Two quotient bits in parallel, without a serial remainder carry.
				-- For negative x, NOT x = -x-1 preserves the exact zero boundary.
				mag_v:=div_v(19 DOWNTO 0) XOR (19 DOWNTO 0 => div_v(20));
				ge2_v:=to_std_logic(mag_v>=to_unsigned(o_hsize*2,20));
				ge4_v:=to_std_logic(mag_v>=to_unsigned(o_hsize*4,20));
				ge6_v:=to_std_logic(mag_v>=to_unsigned(o_hsize*6,20));
				dir_v(5):=ge4_v XOR div_v(20);
				dir_v(4):=((ge2_v AND NOT ge4_v) OR ge6_v) XOR div_v(20);
			END IF;

			-----------------------------------
			o_hfrac(1)<=dir_v;
			o_hfrac(2 TO 9) <= o_hfrac(1 TO 8);

			o_copyv(1 TO 14)<=o_copyv(0 TO 13);
			o_dcptv_clr(1 TO 12)<=o_dcpt_clr & o_dcptv_clr(1 TO 11);
			o_dcptv_inc(1 TO 12)<=o_dcpt_inc & o_dcptv_inc(1 TO 11);

			IF o_dcptv_clr(12)='1' THEN
				o_dcptv(13) <= 0;
			ELSIF o_dcptv_inc(12)='1' THEN
				o_dcptv(13) <= (o_dcptv(13) + 1) MOD OHRESH;
			END IF;
			o_dcptv(14)<=o_dcptv(13);

			IF o_dcptv(13)>=o_hsize THEN
				o_copyv(14)<='0';
			END IF;

			-- C2
			o_hpixq(2)<=(o_hpix3,o_hpix2,o_hpix1,o_hpix0);
			o_hpixq(3 TO 8)<=o_hpixq(2 TO 7);

			-- BILINEAR / SHARP BILINEAR ---------------
			-- C7 : Pre-calc Sharp Bilinear
			o_h_sbil_t<=sbil_frac1(o_hfrac(6));

			-- C8 : Select
			o_h_bil_frac<=(OTHERS =>'0');
			IF o_hmode(0)='1' THEN -- Bilinear
				IF MASK(MASK_BILINEAR)='1' THEN
					o_h_bil_frac<=bil_frac(o_hfrac(7));
				END IF;
			ELSE -- Sharp Bilinear
				IF MASK(MASK_SHARP_BILINEAR)='1' THEN
					o_h_bil_frac<=sbil_frac2(o_hfrac(7),o_h_sbil_t);
				END IF;
			END IF;

			-- C9 : Opposite frac
			o_h_bil_t<=bil_calc(o_h_bil_frac,o_hpixq(8));

			-- C10 : Bilinear / Sharp Bilinear
			o_h_bil_pix.r<=bound(o_h_bil_t.r,8+FRAC);
			o_h_bil_pix.g<=bound(o_h_bil_t.g,8+FRAC);
			o_h_bil_pix.b<=bound(o_h_bil_t.b,8+FRAC);

			-- BICUBIC -------------------------------------------
			-- C8 : Bicubic coefficients A,B,C,D
			-- C8 : Bicubic calc T1 = X.D + C
			o_h_bic_abcd1<=bic_calc0(o_hfrac(7),o_hpixq(6));
			o_h_bic_tt1<=bic_calc1(o_hfrac(7),
										 bic_calc0(o_hfrac(7),o_hpixq(6)));

			-- C9 : Bicubic calc T2 = X.T1 + B
			o_h_bic_abcd2<=o_h_bic_abcd1;
			o_h_bic_tt2<=bic_calc2(o_hfrac(8),o_h_bic_tt1,o_h_bic_abcd1);

			-- C10 : Bicubic final Y = X.T2 + A
			o_h_bic_pix<=bic_calc3(o_hfrac(9),o_h_bic_tt2,o_h_bic_abcd2);

			-- POLYPHASE -----------------------------------------
			-- C2
			IF o_hfrac(2)(o_hfrac(2)'left)='0' THEN
				o_h_lum_pix<=o_hpix2;
			ELSE
				o_h_lum_pix<=o_hpix1;
			END IF;

			-- C3-C8 in PolyFetch

			-- C9 : Apply Polyphase
			o_h_poly_t<=poly_calc(o_h_poly_phase,o_hpixq(8));

			-- C10 : Sum and bound
			o_h_poly_pix<=poly_final(o_h_poly_t);

			-- C11 : Select interpoler ----------------------------
			o_wadl<=o_dcptv(14);
			o_wr<=o_altx AND (o_copyv(14) & o_copyv(14) & o_copyv(14) & o_copyv(14));
			o_ldw<=(x"00",x"00",x"00");

			CASE o_hmode(2 DOWNTO 0) IS
				WHEN "000"  => -- Nearest
					IF MASK(MASK_NEAREST)='1' THEN
						o_ldw<=o_h_poly_pix;
				 END IF;
				WHEN "001" | "010" => -- Bilinear | Sharp Bilinear
					IF MASK(MASK_BILINEAR)='1' OR
						 MASK(MASK_SHARP_BILINEAR)='1' THEN
						o_ldw<=o_h_bil_pix;
				 END IF;
				WHEN "011" => -- BiCubic
					IF MASK(MASK_BICUBIC)='1' THEN
						o_ldw<=o_h_bic_pix;
					END IF;
				WHEN OTHERS => -- PolyPhase
					IF MASK(MASK_POLY)='1' THEN
						o_ldw<=o_h_poly_pix;
					END IF;
			END CASE;
			------------------------------------------------------
		END IF;
	END PROCESS HSCAL;

	-----------------------------------------------------------------------------
	-- Line buffers 4 x OHRES x (R+G+B)
	OLBUF:PROCESS(o_clk) IS
	BEGIN
		IF rising_edge(o_clk) THEN
			-----------------------------------------------
			-- WRITES
			IF o_wr(0)='1' AND o_wadl < OHRESL  THEN o_line0(o_wadl MOD OHRESL)<=o_ldw; END IF;
			IF o_wr(1)='1' AND o_wadl < OHRESL  THEN o_line1(o_wadl MOD OHRESL)<=o_ldw; END IF;
			IF o_wr(2)='1' AND o_wadl < OHRESL  THEN o_line2(o_wadl MOD OHRESL)<=o_ldw; END IF;
			IF o_wr(3)='1' AND o_wadl < OHRESL  THEN o_line3(o_wadl MOD OHRESL)<=o_ldw; END IF;
			IF OHRES = 2304 OR OHRES = 2560 THEN
				IF o_wr(0)='1' AND o_wadl >= OHRESL THEN o_linf0(o_wadl MOD OHRESM)<=o_ldw; END IF;
				IF o_wr(1)='1' AND o_wadl >= OHRESL THEN o_linf1(o_wadl MOD OHRESM)<=o_ldw; END IF;
				IF o_wr(2)='1' AND o_wadl >= OHRESL THEN o_linf2(o_wadl MOD OHRESM)<=o_ldw; END IF;
				IF o_wr(3)='1' AND o_wadl >= OHRESL THEN o_linf3(o_wadl MOD OHRESM)<=o_ldw; END IF;
			END IF;

			-----------------------------------------------
			-- READS
			o_ldr0<=o_line0(o_radl0 MOD OHRESL);
			o_ldr1<=o_line1(o_radl1 MOD OHRESL);
			o_ldr2<=o_line2(o_radl2 MOD OHRESL);
			o_ldr3<=o_line3(o_radl3 MOD OHRESL);

			IF OHRES = 2304 OR OHRES = 2560 THEN
				o_ler0<=o_linf0(o_radl0 MOD OHRESM);
				o_ler1<=o_linf1(o_radl1 MOD OHRESM);
				o_ler2<=o_linf2(o_radl2 MOD OHRESM);
				o_ler3<=o_linf3(o_radl3 MOD OHRESM);
			END IF;

			o_lex0 <= to_std_logic(o_radl0 >= OHRESL);
			o_lex1 <= to_std_logic(o_radl1 >= OHRESL);
			o_lex2 <= to_std_logic(o_radl2 >= OHRESL);
			o_lex3 <= to_std_logic(o_radl3 >= OHRESL);
			-----------------------------------------------

		END IF;
	END PROCESS OLBUF;

	-----------------------------------------------------------------------------
	-- Output video sweep
	OSWEEP:PROCESS(o_clk) IS
	BEGIN
		IF rising_edge(o_clk) THEN

			IF o_ce='1' THEN
				-- Output pixels count
				IF o_hcpt+1<o_htotal THEN
					o_hcpt<=(o_hcpt+1) MOD 4096;
				ELSE
					o_hcpt<=0;

					IF o_vcpt_sync /= 4095 THEN
						o_vcpt_sync <= o_vcpt_sync+1;
					END IF;

					IF o_vcpt_pre3+1>=o_vtotal THEN
						o_vcpt_pre3<=0;
					ELSIF o_vrr_sync2 THEN
						o_vcpt_pre3<=o_vsstart;
						o_sync<=false;
					ELSE
						o_vcpt_pre3<=(o_vcpt_pre3+1) MOD 4096;
					END IF;

					o_vcpt_pre2<=o_vcpt_pre3;
					o_vcpt_pre<=o_vcpt_pre2;
					o_vcpt<=o_vcpt_pre;
				END IF;

				o_end(0)<=to_std_logic(o_vcpt>=o_vdisp);
				o_dev(0)<=to_std_logic(o_hcpt<o_hdisp AND o_vcpt<o_vdisp);
				o_pev(0)<=to_std_logic(o_hcpt>=o_hmin AND o_hcpt<=o_hmax AND
											  o_vcpt>=o_vmin AND o_vcpt<=o_vmax);
				o_hsv(0)<=to_std_logic(o_hcpt>=o_hsstart AND o_hcpt<o_hsend);
				o_vsv(0)<=to_std_logic((o_vcpt=o_vsstart AND o_hcpt>=o_hsstart) OR
											  (o_vcpt>o_vsstart AND o_vcpt<o_vsend) OR
											  (o_vcpt=o_vsend   AND o_hcpt<o_hsstart));

				o_vss<=to_std_logic(o_vcpt_pre2>=o_vmin AND o_vcpt_pre2<=o_vmax);
				o_hsv(1 TO 11)<=o_hsv(0 TO 10);
				o_vsv(1 TO 11)<=o_vsv(0 TO 10);
				o_dev(1 TO 11)<=o_dev(0 TO 10);
				o_pev(1 TO 11)<=o_pev(0 TO 10);
				o_end(1 TO 11)<=o_end(0 TO 10);

				IF o_run='0' THEN
					o_hsv(2)<='0';
					o_vsv(2)<='0';
					o_dev(2)<='0';
					o_pev(2)<='0';
					o_end(2)<='0';
				END IF;
				IF CONFIG_HANDSHAKE AND cfg_initialized='0' THEN
					o_hcpt<=0;
					o_hsv<=(OTHERS =>'0'); o_vsv<=(OTHERS =>'0');
					o_dev<=(OTHERS =>'0'); o_pev<=(OTHERS =>'0');
					o_end<=(OTHERS =>'1');
				END IF;
				IF CONFIG_HANDSHAKE AND (cfg_initialized='0' OR o_bootstrap='1') THEN
					-- Extend only the pre-active vertical blank. HS keeps its
					-- configured period while actual two-line copies complete.
					-- Release at a line boundary; the next row is displayed0.
					o_vcpt<=4095; o_vcpt_pre<=0;
					o_vcpt_pre2<=1; o_vcpt_pre3<=2;
				END IF;
			END IF;

			o_vcpt_sync2<=o_vcpt_sync;
			o_vrr_min<=(o_vcpt_sync2<o_vtotal);
			o_vrr_min2<=o_vrr_min;
			o_vrr_max<=(o_vcpt_sync2<o_vrrmax);
			o_vrr_max2<=o_vrr_max;

			IF o_isync2='1' THEN
				o_vcpt_sync<=0;
				o_sync_max<=o_vrr_max2;
				IF o_vrr_min2 THEN
					o_sync<=true;
				END iF;
			END IF;

			o_vcpt2<=o_vcpt_pre3;
			o_vrr_sync<=(o_vrr='1' AND (o_sync OR o_sync_max) AND o_vcpt2>=o_vdisp AND o_vcpt2<o_vsstart);
			o_vrr_sync2<=o_vrr_sync;

	 END IF;
	END PROCESS OSWEEP;

	-----------------------------------------------------------------------------
	-- Vertical Scaler
	VSCAL:PROCESS(o_clk) IS
		VARIABLE pixq_v : arr_pix(0 TO 3);
		VARIABLE vlumpix_v : type_pix;
		VARIABLE r1_v, r2_v : natural RANGE 0 TO OHRESH-1;
		VARIABLE fracnn_v : std_logic;
		VARIABLE o_l0_v, o_l1_v, o_l2_v, o_l3_v : type_pix;
	BEGIN
		IF rising_edge(o_clk) THEN
			IF o_ce='1' THEN
				o_v_hmin_adj<=o_hmin + 5;

				fracnn_v := o_vfrac(o_vfrac'left);
				r1_v := (o_hcpt - o_v_hmin_adj + OHRESH) MOD OHRESH;
				r2_v := (o_hcpt - o_hmin       + OHRESH) MOD OHRESH;

				-- CYCLE 1 -----------------------------------------
				-- Read mem
				o_radl0<=r1_v;
				o_radl1<=r1_v;
				o_radl2<=r1_v;
				o_radl3<=r1_v;

				IF fracnn_v = '0' THEN
					CASE o_vacptl IS
						WHEN "10"   => o_radl1<=r2_v;
						WHEN "11"   => o_radl2<=r2_v;
						WHEN "00"   => o_radl3<=r2_v;
						WHEN OTHERS => o_radl0<=r2_v;
					END CASE;
				ELSE
					CASE o_vacptl IS
						WHEN "10"   => o_radl2<=r2_v;
						WHEN "11"   => o_radl3<=r2_v;
						WHEN "00"   => o_radl0<=r2_v;
						WHEN OTHERS => o_radl1<=r2_v;
					END CASE;
				END IF;

				-- CYCLE 2 -----------------------------------------
				-- Lines reordering
				IF o_lex0='0' THEN o_l0_v := o_ldr0; ELSE o_l0_v := o_ler0; END IF;
				IF o_lex1='0' THEN o_l1_v := o_ldr1; ELSE o_l1_v := o_ler1; END IF;
				IF o_lex2='0' THEN o_l2_v := o_ldr2; ELSE o_l2_v := o_ler2; END IF;
				IF o_lex3='0' THEN o_l3_v := o_ldr3; ELSE o_l3_v := o_ler3; END IF;

				CASE o_vacptl IS
					WHEN "10"   => pixq_v:=(o_l0_v,o_l1_v,o_l2_v,o_l3_v);
					WHEN "11"   => pixq_v:=(o_l1_v,o_l2_v,o_l3_v,o_l0_v);
					WHEN "00"   => pixq_v:=(o_l2_v,o_l3_v,o_l0_v,o_l1_v);
					WHEN OTHERS => pixq_v:=(o_l3_v,o_l0_v,o_l1_v,o_l2_v);
				END CASE;

				IF fracnn_v = '0' THEN
					o_vpix_outer<=(pixq_v(0), pixq_v(2), pixq_v(3));
					o_vpix_inner(0)<=pixq_v(1);
				ELSE
					o_vpix_outer<=(pixq_v(0), pixq_v(1), pixq_v(3));
					o_vpix_inner(0)<=pixq_v(2);
				END IF;

				-- CYCLE 3-7
				o_vpix_inner(1 TO 5)<=o_vpix_inner(0 TO 4);

				-- CYCLE 8
				-- Register edge predicates with the unextended pixels, so the
				-- wide comparison does not also drive the pixel mux this cycle.
				o_vpix_past<=to_integer(o_vacpt)>o_ivsize;
				o_vpix_last<=to_integer(o_vacpt)=o_ivsize;
				IF fracnn_v = '0' THEN
					o_vpixq_pre<=(o_vpix_outer(0), o_vpix_inner(5), o_vpix_outer(1), o_vpix_outer(2));
				ELSE
					o_vpixq_pre<=(o_vpix_outer(0), o_vpix_outer(1), o_vpix_inner(5), o_vpix_outer(2));
				END IF;

				-- CYCLE 9
				-- Extend the bottom edge in the existing delay stage. Both the
				-- predicates and pixels hold together when o_ce is low.
				pixq_v:=o_vpixq_pre;
				IF o_vpix_past THEN
					pixq_v(2):=o_vpixq_pre(1);
					pixq_v(3):=o_vpixq_pre(1);
				ELSIF o_vpix_last THEN
					pixq_v(3):=o_vpixq_pre(2);
				END IF;
				o_vpixq<=pixq_v;

				-- BILINEAR / SHARP BILINEAR -----------------------
				-- C8 : Pre-calc Sharp Bilinear
				o_v_sbil_t<=sbil_frac1(o_vfrac);

				-- C9 : Select
				o_v_bil_frac<=(OTHERS =>'0');
				IF o_vmode(0)='1' THEN -- Bilinear
					IF MASK(MASK_BILINEAR)='1' THEN
						o_v_bil_frac<=bil_frac(o_vfrac);
					END IF;
				ELSE  -- Sharp Bilinear
					IF MASK(MASK_SHARP_BILINEAR)='1' THEN
						o_v_bil_frac<=sbil_frac2(o_vfrac,o_v_sbil_t);
					END IF;
				END IF;

				-- C10 :
				o_v_bil_t<=bil_calc(o_v_bil_frac,o_vpixq);

				-- C11 : Nearest / Bilinear / Sharp Bilinear
				o_v_bil_pix.r<=bound(o_v_bil_t.r,8+FRAC);
				o_v_bil_pix.g<=bound(o_v_bil_t.g,8+FRAC);
				o_v_bil_pix.b<=bound(o_v_bil_t.b,8+FRAC);

				-- BICUBIC -----------------------------------------
				-- C9 : Bicubic coefficients A,B,C,D
				-- C9 : Bicubic calc T1 = X.D + C
				o_v_bic_abcd1<=bic_calc0(o_vfrac,o_vpixq);
				o_v_bic_tt1<=bic_calc1(o_vfrac,bic_calc0(o_vfrac,o_vpixq));

				-- C10 : Bicubic calc T2 = X.T1 + B
				o_v_bic_abcd2<=o_v_bic_abcd1;
				o_v_bic_tt2<=bic_calc2(o_vfrac,o_v_bic_tt1,o_v_bic_abcd1);

				-- C11 : Bicubic final Y = X.T2 + A
				o_v_bic_pix<=bic_calc3(o_vfrac,o_v_bic_tt2,o_v_bic_abcd2);

				-- POLYPHASE ---------------------------------------
				-- C3 : Setup luminance
				o_v_lum_pix<=o_vpix_inner(0);

				-- C4-C9 in PolyFetch

				-- C10 : Apply polyphase
				o_v_poly_t<=poly_calc(o_v_poly_phase,o_vpixq);

				-- C11 : Bound
				o_v_poly_pix<=poly_final(o_v_poly_t);

				-- CYCLE 12 -----------------------------------------
				o_hs<=o_hsv(11);
				o_vs<=o_vsv(11);
				o_de<=o_dev(11);
				o_vbl<=o_end(11);
				o_r<=x"00";
				o_g<=x"00";
				o_b<=x"00";
				o_brd<= not o_pev(11);

				CASE o_vmode(2 DOWNTO 0) IS
					WHEN "000" => -- Nearest
						IF MASK(MASK_NEAREST)='1' THEN
							o_r<=o_v_poly_pix.r;
							o_g<=o_v_poly_pix.g;
							o_b<=o_v_poly_pix.b;
						END IF;
					WHEN "001" | "010" => -- Bilinear | Sharp Bilinear
						IF MASK(MASK_BILINEAR)='1' OR
							 MASK(MASK_SHARP_BILINEAR)='1' THEN
							o_r<=o_v_bil_pix.r;
							o_g<=o_v_bil_pix.g;
							o_b<=o_v_bil_pix.b;
						END IF;
					WHEN "011" => -- BiCubic
						IF MASK(MASK_BICUBIC)='1' THEN
							o_r<=o_v_bic_pix.r;
							o_g<=o_v_bic_pix.g;
							o_b<=o_v_bic_pix.b;
						END IF;

					WHEN OTHERS => -- Polyphase
						IF MASK(MASK_POLY)='1' THEN
							o_r<=o_v_poly_pix.r;
							o_g<=o_v_poly_pix.g;
							o_b<=o_v_poly_pix.b;
						END IF;
				END CASE;

				IF o_pev(11)='0' THEN
					o_r<=c_border(23 DOWNTO 16); -- Copy border colour
					o_g<=c_border(15 DOWNTO 8);
					o_b<=c_border(7 DOWNTO 0);
				END IF;

				----------------------------------------------------
			END IF;
		END IF;
	END PROCESS VSCAL;

	-----------------------------------------------------------------------------
	-- Low Lag syntoniser interface
	o_lltune<=(0 => i_vss,
						 1 => i_pde,
						 2 => i_inter,
						 3 => i_flm,
						 4 => o_vss,
						 5 => i_pce,
						 6 => i_clk,
						 7 => o_clk,
						 OTHERS =>'0');

	----------------------------------------------------------------------------
END ARCHITECTURE rtl;
