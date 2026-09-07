library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity ascal_timing_tb is end;
architecture test of ascal_timing_tb is
TYPE type_pix IS RECORD
		r,g,b : unsigned(7 DOWNTO 0); -- 0.8
	END RECORD;
TYPE poly_phase_t IS RECORD
		t0, t1, t2, t3  : signed(9 DOWNTO 0);
	END RECORD;
TYPE poly_phase_interp_t IS RECORD
		t0, t1, t2, t3  : signed(17 DOWNTO 0);
	END RECORD;
TYPE poly_phase_diff_t IS RECORD
		t0, t1, t2, t3 : signed(10 DOWNTO 0);
	END RECORD;
TYPE poly_phase_product_t IS RECORD
		t0, t1, t2, t3 : signed(19 DOWNTO 0);
	END RECORD;
TYPE arr_pix IS ARRAY (natural RANGE <>) OF type_pix;
SUBTYPE uint12 IS natural RANGE 0 TO 4095;
SIGNAL o_format : unsigned(5 DOWNTO 0);
SIGNAL o_fb_pal_dr : unsigned(23 DOWNTO 0);
SIGNAL o_sh,o_sh1,o_sh2,o_sh3,o_sh4 : std_logic;
SIGNAL o_ihsize,o_ihsizem,o_ivsize : uint12;
SIGNAL o_vfrac : unsigned(11 DOWNTO 0);
SIGNAL o_first,o_last,o_last1,o_last2 : std_logic;
SIGNAL o_lastt1,o_lastt2,o_lastt3,o_lastt4 : std_logic;
SIGNAL o_hpixs,o_hpix0,o_hpix1,o_hpix2,o_hpix3 : type_pix;
SIGNAL o_vpixq, o_vpixq_pre : arr_pix(0 TO 3);
SIGNAL o_vpix_past, o_vpix_last : boolean;
SIGNAL o_vpix_outer : arr_pix(0 TO 2);
SIGNAL o_vpix_inner : arr_pix(0 TO 6);
SIGNAL o_hacpt,o_vacpt : unsigned(11 DOWNTO 0);
signal o_newres : integer range 0 to 3;
SIGNAL o_h_poly_phase_a,o_h_poly_phase_a2,o_h_poly_phase_a3, o_h_poly_phase_a4, o_h_poly_phase_a5 : poly_phase_t;
SIGNAL o_v_poly_phase_a,o_v_poly_phase_a2,o_v_poly_phase_a3, o_v_poly_phase_a4, o_v_poly_phase_a5 : poly_phase_t;
SIGNAL o_poly_phase_a, o_poly_phase_a2, o_poly_phase_a3 : poly_phase_t;
SIGNAL o_poly_phase_b : poly_phase_t;
SIGNAL o_poly_phase_diff : poly_phase_diff_t;
SIGNAL o_poly_phase_product : poly_phase_product_t;
SIGNAL o_v_poly_phase, o_v_poly_phase2, o_h_poly_phase, o_poly_phase1 : poly_phase_interp_t;
SIGNAL o_poly_lum, o_poly_lum1 : unsigned(7 DOWNTO 0);
SIGNAL o_poly_lerp_t : signed(8 DOWNTO 0);
SIGNAL o_v_poly_adaptive, o_h_poly_adaptive, o_v_poly_use_adaptive, o_h_poly_use_adaptive : std_logic;
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
signal o_clk : std_logic := '0';
signal o_ce : std_logic := '0';
signal seed, first_seed : std_logic := '0';
type phase_queue is array (0 to 3) of poly_phase_interp_t;
type pix_array is array (0 to 3) of type_pix;
function pix(n : natural) return type_pix is
begin
  return (to_unsigned(n mod 256,8), to_unsigned((n+71) mod 256,8),
          to_unsigned((n+157) mod 256,8));
end;
function coeff(n : natural) return poly_phase_t is
begin
  return (to_signed((n mod 1024)-512,10),
          to_signed(((n+257) mod 1024)-512,10),
          to_signed(((n+511) mod 1024)-512,10),
          to_signed(((n+769) mod 1024)-512,10));
end;
function oracle(a,b : signed(9 downto 0); lum : natural) return signed is
  variable s : integer;
begin
  s := to_integer(a)*(256-lum) + to_integer(b)*lum;
  if s < 0 then s := s-1; end if; -- VHDL integer division truncates toward zero.
  return to_signed(s/2,18);
end;
function oracle(a,b : poly_phase_t; lum : natural) return poly_phase_interp_t is
begin
  return (oracle(a.t0,b.t0,lum), oracle(a.t1,b.t1,lum),
          oracle(a.t2,b.t2,lum), oracle(a.t3,b.t3,lum));
end;
begin
coefficient_pipeline: process(o_clk) begin
  if rising_edge(o_clk) then
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
	
end process;
pixel_mux: process(o_clk)
  variable hpix_v : type_pix;
begin
  if rising_edge(o_clk) then
    if seed='1' then
      o_hpix0<=pix(11); o_hpix1<=pix(37);
      o_hpix2<=pix(91); o_hpix3<=pix(183);
      o_first<=first_seed;
    else
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

			
    end if;
  end if;
end process;
vertical_edge: process(o_clk)
  variable fracnn_v : std_logic;
  variable pixq_v : arr_pix(0 to 3);
begin
  if rising_edge(o_clk) then
    if o_ce='1' then
fracnn_v := o_vfrac(o_vfrac'left);
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

				
    end if;
  end if;
end process;
stimulus: process
  variable aq,hq,vq : phase_queue;
  variable a,b,ha,va : poly_phase_t;
  variable expected_h,expected_v : poly_phase_interp_t;
  variable pixels,prior : pix_array;
  variable p : type_pix;
  variable first : std_logic;
  variable cycles : natural := 0;
  variable vertical_cycles, vertical_valid : natural := 0;
  variable vertical_pending, vertical_expected : arr_pix(0 to 3);
  variable rng : unsigned(31 downto 0) := x"4A730CD1";
  procedure tick is
  begin
    o_clk<='0'; wait for 1 ns; o_clk<='1'; wait for 1 ns;
  end;
  procedure sample(ai,bi,lum,control : natural) is
  begin
    a:=coeff(ai); b:=coeff(bi);
    ha:=coeff((ai+73) mod 1024); va:=coeff((bi+167) mod 1024);
    o_poly_phase_a<=a; o_poly_phase_b<=b;
    o_poly_lum1<=to_unsigned(lum,8);
    o_h_poly_phase_a2<=ha; o_v_poly_phase_a2<=va;
    o_h_poly_use_adaptive<=to_unsigned(control,2)(0);
    o_v_poly_use_adaptive<=to_unsigned(control,2)(1);
    aq(1 to 3):=aq(0 to 2);
    hq(1 to 3):=hq(0 to 2); vq(1 to 3):=vq(0 to 2);
    aq(0):=oracle(a,b,lum);
    hq(0):=oracle(ha,ha,0); vq(0):=oracle(va,va,0);
    tick;
    if cycles>=2 then
      assert o_poly_phase1=aq(2) report "C7 adaptive coefficient/latency" severity failure;
    end if;
    if cycles>=3 then
      expected_h:=hq(3); expected_v:=vq(3);
      if control>=2 then expected_v:=aq(3);
      elsif control=1 then expected_h:=aq(3); end if;
      assert o_h_poly_phase=expected_h report "C8 horizontal select/latency" severity failure;
      assert o_v_poly_phase=expected_v report "C8 vertical select/latency" severity failure;
    end if;
    cycles:=cycles+1;
  end;
  procedure vsample(count,height,frac : natural; enable : std_logic) is
    variable outer : arr_pix(0 to 2);
    variable inner : type_pix;
    variable selected : arr_pix(0 to 3);
  begin
    outer:=(pix(count+vertical_cycles),pix(height+vertical_cycles+71),
            pix(count+height+vertical_cycles+143));
    inner:=pix(count+height+vertical_cycles+211);
    o_vacpt<=to_unsigned(count,12); o_ivsize<=height;
    o_vfrac<=to_unsigned(frac*2048,12); o_ce<=enable;
    o_vpix_outer<=outer; o_vpix_inner<=(others=>inner);
    if count>height then
      if frac=0 then selected:=(outer(0),inner,inner,inner);
      else selected:=(outer(0),outer(1),outer(1),outer(1)); end if;
    elsif count=height then
      if frac=0 then selected:=(outer(0),inner,outer(1),outer(1));
      else selected:=(outer(0),outer(1),inner,inner); end if;
    else
      if frac=0 then selected:=(outer(0),inner,outer(1),outer(2));
      else selected:=(outer(0),outer(1),inner,outer(2)); end if;
    end if;
    if enable='1' then
      vertical_expected:=vertical_pending;
      vertical_pending:=selected;
      vertical_valid:=vertical_valid+1;
    end if;
    tick;
    if vertical_valid>=2 then
      assert o_vpixq=vertical_expected
        report "Vertical edge pixels/phase/CE/latency mismatch at cycle " &
               integer'image(vertical_cycles) severity failure;
    end if;
    vertical_cycles:=vertical_cycles+1;
  end;
begin
  seed<='1'; first_seed<='0';
  o_sh4<='0'; o_lastt4<='0'; o_newres<=0; o_format<=(others=>'0');
  o_hpixs<=pix(0); o_fb_pal_dr<=x"79E235";
  -- Every signed 10-bit coefficient at every luma, including both maximum
  -- difference signs and negative odd results, while controls change each edge.
  for ai in 0 to 1023 loop
    for lum in 0 to 255 loop
      sample(ai,1023-ai,lum,cycles mod 4);
      sample(ai,0,lum,cycles mod 4);
      sample(ai,1023,lum,cycles mod 4);
    end loop;
  end loop;
  for i in 0 to 65535 loop
    rng:=rng xor shift_left(rng,13);
    rng:=rng xor shift_right(rng,17);
    rng:=rng xor shift_left(rng,5);
    sample(to_integer(rng(9 downto 0)),to_integer(rng(19 downto 10)),
           to_integer(rng(27 downto 20)),to_integer(rng(31 downto 30)));
  end loop;
  for i in 0 to 3 loop sample(0,1023,i,i); end loop;
  report "PASS adaptive pipeline: " & integer'image(cycles) & " cycles";
  -- All six format bits, all resolution-blank states, swap/index priority,
  -- first-pixel duplication, right-edge hold, and clock-enable hold.
  for fmt in 0 to 63 loop
    for blank in 0 to 3 loop
      for controls in 0 to 7 loop
        seed<='1'; first_seed<=to_unsigned(controls,3)(0); tick;
        pixels:=(pix(11),pix(37),pix(91),pix(183));
        first:=to_unsigned(controls,3)(0);
        seed<='0';
        for step in 0 to 3 loop
          o_format<=to_unsigned(fmt,6); o_newres<=blank;
          o_hpixs<=pix(fmt+controls+step*29);
          o_lastt4<=to_unsigned(controls,3)(1);
          o_sh4<=to_unsigned(controls,3)(2);
          prior:=pixels;
          if controls>=4 then
            p:=pix(fmt+controls+step*29);
            if (fmt/16) mod 2=1 then p:=(p.b,p.g,p.r); end if;
            if fmt mod 8=3 then p:=(x"79",x"E2",x"35"); end if;
            if blank>0 then p:=(others=>(others=>'0')); end if;
            pixels:=(p,prior(0),prior(1),prior(2));
            if first='1' then pixels(1):=p; pixels(2):=p; first:='0'; end if;
            if (controls/2) mod 2=1 then pixels(0):=prior(0); end if;
          end if;
          tick;
          assert o_hpix0=pixels(0) and o_hpix1=pixels(1) and
                 o_hpix2=pixels(2) and o_hpix3=pixels(3) and o_first=first
            report "Pixel format/blank/edge/enable mismatch" severity failure;
        end loop;
      end loop;
    end loop;
  end loop;
  report "PASS pixel mux: 8192 cycles, all 64 format codes, four blank states";
  for count in 0 to 4095 loop
    for frac in 0 to 1 loop
      vsample(count,count,frac,'1');
      vsample((count+1) mod 4096,count,1-frac,'0');
      vsample((count+1) mod 4096,count,frac,'1');
      vsample(count,(count+1) mod 4096,frac,'1');
      vsample(count,0,frac,'1');
      vsample(count,4095,frac,'1');
    end loop;
  end loop;
  for i in 0 to 65535 loop
    rng:=rng xor shift_left(rng,13);
    rng:=rng xor shift_right(rng,17);
    rng:=rng xor shift_left(rng,5);
    vsample(to_integer(rng(11 downto 0)),to_integer(rng(23 downto 12)),
            to_integer(rng(24 downto 24)),rng(25));
  end loop;
  vsample(4095,4095,1,'1'); vsample(0,0,0,'1');
  report "PASS vertical edge: " & integer'image(vertical_cycles) &
         " cycles, boundaries/phase/geometry changes/CE holds";
  stop;
  wait;
end process;
end;
