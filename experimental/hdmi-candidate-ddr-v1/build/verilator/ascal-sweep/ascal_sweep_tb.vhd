
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity ascal_sweep_tb is end;
architecture test of ascal_sweep_tb is
subtype uint12 is natural range 0 to 4095;
signal clock : std_logic := '0';
signal enable, config_reset_n : std_logic := '0';
signal htotal : uint12 := 0;
FUNCTION to_std_logic (a : boolean) RETURN std_logic IS
	BEGIN
		IF a THEN RETURN '1';
		ELSE RETURN '0';
		END IF;
	END FUNCTION to_std_logic;
	SIGNAL ref_o_run : std_logic;
	SIGNAL ref_o_htotal,ref_o_hsstart,ref_o_hsend : uint12;
	SIGNAL ref_o_hmin,ref_o_hmax,ref_o_hdisp,ref_o_v_hmin_adj : uint12;
	SIGNAL ref_o_vtotal,ref_o_vsstart,ref_o_vsend : uint12;
	SIGNAL ref_o_vrr,ref_o_isync,ref_o_isync2 : std_logic;
	SIGNAL ref_o_vrr_sync,ref_o_vrr_sync2 : boolean;
	SIGNAL ref_o_vrr_min,ref_o_vrr_min2 : boolean;
	SIGNAL ref_o_vrr_max,ref_o_vrr_max2 : boolean;
	SIGNAL ref_o_vcpt_sync,ref_o_vcpt_sync2, ref_o_vrrmax : uint12;
	SIGNAL ref_o_sync, ref_o_sync_max : boolean;
	SIGNAL ref_o_vmin,ref_o_vmax,ref_o_vdisp : uint12;
	SIGNAL ref_o_hcpt,ref_o_vcpt,ref_o_vcpt_pre,ref_o_vcpt_pre2,ref_o_vcpt_pre3,ref_o_vcpt2 : uint12;
	SIGNAL ref_o_hsv,ref_o_vsv,ref_o_dev,ref_o_pev,ref_o_end : unsigned(0 TO 11);
	SIGNAL ref_o_hsp,ref_o_vss : std_logic;
	SIGNAL dut_o_run : std_logic;
	SIGNAL dut_o_hlast,dut_o_hsstart,dut_o_hsend : uint12;
	SIGNAL dut_o_hmin,dut_o_hmax,dut_o_hdisp,dut_o_v_hmin_adj : uint12;
	SIGNAL dut_o_vtotal,dut_o_vsstart,dut_o_vsend : uint12;
	SIGNAL dut_o_vrr,dut_o_isync,dut_o_isync2 : std_logic;
	SIGNAL dut_o_vrr_sync,dut_o_vrr_sync2 : boolean;
	SIGNAL dut_o_vrr_min,dut_o_vrr_min2 : boolean;
	SIGNAL dut_o_vrr_max,dut_o_vrr_max2 : boolean;
	SIGNAL dut_o_vcpt_sync,dut_o_vcpt_sync2, dut_o_vrrmax : uint12;
	SIGNAL dut_o_sync, dut_o_sync_max : boolean;
	SIGNAL dut_o_vmin,dut_o_vmax,dut_o_vdisp : uint12;
	SIGNAL dut_o_hcpt,dut_o_vcpt,dut_o_vcpt_pre,dut_o_vcpt_pre2,dut_o_vcpt_pre3,dut_o_vcpt2 : uint12;
	SIGNAL dut_o_hsv,dut_o_vsv,dut_o_dev,dut_o_pev,dut_o_end : unsigned(0 TO 11);
	SIGNAL dut_o_hsp,dut_o_vss : std_logic;
function old_continue(c,t : uint12) return boolean is
begin return c+1<t; end;
function new_continue(c,t : uint12) return boolean is
  variable last_pixel : uint12;
begin
  IF t>0 THEN -- <ASYNC> ?
				last_pixel:=t-1;
			ELSE
				last_pixel:=0;
			END IF;
  return c<last_pixel;
end;
begin
ref_sweep:PROCESS(clock) IS
	BEGIN
		IF rising_edge(clock) THEN

			IF enable='1' THEN
				-- Output pixels count
				IF ref_o_hcpt+1<ref_o_htotal THEN
					ref_o_hcpt<=(ref_o_hcpt+1) MOD 4096;
				ELSE
					ref_o_hcpt<=0;

					IF ref_o_vcpt_sync /= 4095 THEN
						ref_o_vcpt_sync <= ref_o_vcpt_sync+1;
					END IF;

					IF ref_o_vcpt_pre3+1>=ref_o_vtotal THEN
						ref_o_vcpt_pre3<=0;
					ELSIF ref_o_vrr_sync2 THEN
						ref_o_vcpt_pre3<=ref_o_vsstart;
						ref_o_sync<=false;
					ELSE
						ref_o_vcpt_pre3<=(ref_o_vcpt_pre3+1) MOD 4096;
					END IF;

					ref_o_vcpt_pre2<=ref_o_vcpt_pre3;
					ref_o_vcpt_pre<=ref_o_vcpt_pre2;
					ref_o_vcpt<=ref_o_vcpt_pre;
				END IF;

				ref_o_end(0)<=to_std_logic(ref_o_vcpt>=ref_o_vdisp);
				ref_o_dev(0)<=to_std_logic(ref_o_hcpt<ref_o_hdisp AND ref_o_vcpt<ref_o_vdisp);
				ref_o_pev(0)<=to_std_logic(ref_o_hcpt>=ref_o_hmin AND ref_o_hcpt<=ref_o_hmax AND
											  ref_o_vcpt>=ref_o_vmin AND ref_o_vcpt<=ref_o_vmax);
				ref_o_hsv(0)<=to_std_logic(ref_o_hcpt>=ref_o_hsstart AND ref_o_hcpt<ref_o_hsend);
				ref_o_vsv(0)<=to_std_logic((ref_o_vcpt=ref_o_vsstart AND ref_o_hcpt>=ref_o_hsstart) OR
											  (ref_o_vcpt>ref_o_vsstart AND ref_o_vcpt<ref_o_vsend) OR
											  (ref_o_vcpt=ref_o_vsend   AND ref_o_hcpt<ref_o_hsstart));

				ref_o_vss<=to_std_logic(ref_o_vcpt_pre2>=ref_o_vmin AND ref_o_vcpt_pre2<=ref_o_vmax);
				ref_o_hsv(1 TO 11)<=ref_o_hsv(0 TO 10);
				ref_o_vsv(1 TO 11)<=ref_o_vsv(0 TO 10);
				ref_o_dev(1 TO 11)<=ref_o_dev(0 TO 10);
				ref_o_pev(1 TO 11)<=ref_o_pev(0 TO 10);
				ref_o_end(1 TO 11)<=ref_o_end(0 TO 10);

				IF ref_o_run='0' THEN
					ref_o_hsv(2)<='0';
					ref_o_vsv(2)<='0';
					ref_o_dev(2)<='0';
					ref_o_pev(2)<='0';
					ref_o_end(2)<='0';
				END IF;
			END IF;

			ref_o_vcpt_sync2<=ref_o_vcpt_sync;
			ref_o_vrr_min<=(ref_o_vcpt_sync2<ref_o_vtotal);
			ref_o_vrr_min2<=ref_o_vrr_min;
			ref_o_vrr_max<=(ref_o_vcpt_sync2<ref_o_vrrmax);
			ref_o_vrr_max2<=ref_o_vrr_max;

			IF ref_o_isync2='1' THEN
				ref_o_vcpt_sync<=0;
				ref_o_sync_max<=ref_o_vrr_max2;
				IF ref_o_vrr_min2 THEN
					ref_o_sync<=true;
				END iF;
			END IF;

			ref_o_vcpt2<=ref_o_vcpt_pre3;
			ref_o_vrr_sync<=(ref_o_vrr='1' AND (ref_o_sync OR ref_o_sync_max) AND ref_o_vcpt2>=ref_o_vdisp AND ref_o_vcpt2<ref_o_vsstart);
			ref_o_vrr_sync2<=ref_o_vrr_sync;

	 END IF;
	END PROCESS ref_sweep;

ref_capture: process(clock) begin
  if rising_edge(clock) then
    if config_reset_n='1' then
      ref_o_htotal <=htotal; -- <ASYNC> ?
    end if;
  end if;
end process;

dut_sweep:PROCESS(clock) IS
	BEGIN
		IF rising_edge(clock) THEN

			IF enable='1' THEN
				-- Output pixels count
				IF dut_o_hcpt<dut_o_hlast THEN
					dut_o_hcpt<=(dut_o_hcpt+1) MOD 4096;
				ELSE
					dut_o_hcpt<=0;

					IF dut_o_vcpt_sync /= 4095 THEN
						dut_o_vcpt_sync <= dut_o_vcpt_sync+1;
					END IF;

					IF dut_o_vcpt_pre3+1>=dut_o_vtotal THEN
						dut_o_vcpt_pre3<=0;
					ELSIF dut_o_vrr_sync2 THEN
						dut_o_vcpt_pre3<=dut_o_vsstart;
						dut_o_sync<=false;
					ELSE
						dut_o_vcpt_pre3<=(dut_o_vcpt_pre3+1) MOD 4096;
					END IF;

					dut_o_vcpt_pre2<=dut_o_vcpt_pre3;
					dut_o_vcpt_pre<=dut_o_vcpt_pre2;
					dut_o_vcpt<=dut_o_vcpt_pre;
				END IF;

				dut_o_end(0)<=to_std_logic(dut_o_vcpt>=dut_o_vdisp);
				dut_o_dev(0)<=to_std_logic(dut_o_hcpt<dut_o_hdisp AND dut_o_vcpt<dut_o_vdisp);
				dut_o_pev(0)<=to_std_logic(dut_o_hcpt>=dut_o_hmin AND dut_o_hcpt<=dut_o_hmax AND
											  dut_o_vcpt>=dut_o_vmin AND dut_o_vcpt<=dut_o_vmax);
				dut_o_hsv(0)<=to_std_logic(dut_o_hcpt>=dut_o_hsstart AND dut_o_hcpt<dut_o_hsend);
				dut_o_vsv(0)<=to_std_logic((dut_o_vcpt=dut_o_vsstart AND dut_o_hcpt>=dut_o_hsstart) OR
											  (dut_o_vcpt>dut_o_vsstart AND dut_o_vcpt<dut_o_vsend) OR
											  (dut_o_vcpt=dut_o_vsend   AND dut_o_hcpt<dut_o_hsstart));

				dut_o_vss<=to_std_logic(dut_o_vcpt_pre2>=dut_o_vmin AND dut_o_vcpt_pre2<=dut_o_vmax);
				dut_o_hsv(1 TO 11)<=dut_o_hsv(0 TO 10);
				dut_o_vsv(1 TO 11)<=dut_o_vsv(0 TO 10);
				dut_o_dev(1 TO 11)<=dut_o_dev(0 TO 10);
				dut_o_pev(1 TO 11)<=dut_o_pev(0 TO 10);
				dut_o_end(1 TO 11)<=dut_o_end(0 TO 10);

				IF dut_o_run='0' THEN
					dut_o_hsv(2)<='0';
					dut_o_vsv(2)<='0';
					dut_o_dev(2)<='0';
					dut_o_pev(2)<='0';
					dut_o_end(2)<='0';
				END IF;
			END IF;

			dut_o_vcpt_sync2<=dut_o_vcpt_sync;
			dut_o_vrr_min<=(dut_o_vcpt_sync2<dut_o_vtotal);
			dut_o_vrr_min2<=dut_o_vrr_min;
			dut_o_vrr_max<=(dut_o_vcpt_sync2<dut_o_vrrmax);
			dut_o_vrr_max2<=dut_o_vrr_max;

			IF dut_o_isync2='1' THEN
				dut_o_vcpt_sync<=0;
				dut_o_sync_max<=dut_o_vrr_max2;
				IF dut_o_vrr_min2 THEN
					dut_o_sync<=true;
				END iF;
			END IF;

			dut_o_vcpt2<=dut_o_vcpt_pre3;
			dut_o_vrr_sync<=(dut_o_vrr='1' AND (dut_o_sync OR dut_o_sync_max) AND dut_o_vcpt2>=dut_o_vdisp AND dut_o_vcpt2<dut_o_vsstart);
			dut_o_vrr_sync2<=dut_o_vrr_sync;

	 END IF;
	END PROCESS dut_sweep;

dut_capture: process(clock) begin
  if rising_edge(clock) then
    if config_reset_n='1' then
      IF htotal>0 THEN -- <ASYNC> ?
				dut_o_hlast<=htotal-1;
			ELSE
				dut_o_hlast<=0;
			END IF;
    end if;
  end if;
end process;

stimulus: process
  variable rng : unsigned(31 downto 0) := x"BCA01237";
begin
  for t in 0 to 4095 loop
    for c in 0 to 4095 loop
      assert old_continue(c,t)=new_continue(c,t)
        report "terminal-count boundary mismatch" severity failure;
    end loop;
  end loop;
  report "PASS sweep arithmetic: 16777216 counter/total pairs";
  for step in 0 to 65535 loop
    rng:=rng xor shift_left(rng,13);
    rng:=rng xor shift_right(rng,17);
    rng:=rng xor shift_left(rng,5);
    clock<='0';
    enable<=rng(0);
    if step mod 257<3 then config_reset_n<='0';
    else config_reset_n<='1'; end if;
    case step mod 8 is
      when 0 => htotal<=0;
      when 1 => htotal<=1;
      when 2 => htotal<=4095;
      when others => htotal<=to_integer(rng(11 downto 0));
    end case;
ref_o_hdisp<=(to_integer(rng(11 downto 0))+0) mod 4096; dut_o_hdisp<=(to_integer(rng(11 downto 0))+0) mod 4096;
ref_o_hmax<=(to_integer(rng(11 downto 0))+37) mod 4096; dut_o_hmax<=(to_integer(rng(11 downto 0))+37) mod 4096;
ref_o_hmin<=(to_integer(rng(11 downto 0))+74) mod 4096; dut_o_hmin<=(to_integer(rng(11 downto 0))+74) mod 4096;
ref_o_hsend<=(to_integer(rng(11 downto 0))+111) mod 4096; dut_o_hsend<=(to_integer(rng(11 downto 0))+111) mod 4096;
ref_o_hsstart<=(to_integer(rng(11 downto 0))+148) mod 4096; dut_o_hsstart<=(to_integer(rng(11 downto 0))+148) mod 4096;
ref_o_isync2<=rng(5); dut_o_isync2<=rng(5);
ref_o_run<=rng(6); dut_o_run<=rng(6);
ref_o_vdisp<=(to_integer(rng(11 downto 0))+259) mod 4096; dut_o_vdisp<=(to_integer(rng(11 downto 0))+259) mod 4096;
ref_o_vmax<=(to_integer(rng(11 downto 0))+296) mod 4096; dut_o_vmax<=(to_integer(rng(11 downto 0))+296) mod 4096;
ref_o_vmin<=(to_integer(rng(11 downto 0))+333) mod 4096; dut_o_vmin<=(to_integer(rng(11 downto 0))+333) mod 4096;
ref_o_vrr<=rng(10); dut_o_vrr<=rng(10);
ref_o_vrrmax<=(to_integer(rng(11 downto 0))+407) mod 4096; dut_o_vrrmax<=(to_integer(rng(11 downto 0))+407) mod 4096;
ref_o_vsend<=(to_integer(rng(11 downto 0))+444) mod 4096; dut_o_vsend<=(to_integer(rng(11 downto 0))+444) mod 4096;
ref_o_vsstart<=(to_integer(rng(11 downto 0))+481) mod 4096; dut_o_vsstart<=(to_integer(rng(11 downto 0))+481) mod 4096;
ref_o_vtotal<=(to_integer(rng(11 downto 0))+518) mod 4096; dut_o_vtotal<=(to_integer(rng(11 downto 0))+518) mod 4096;
    if step<4100 then
      enable<='1'; config_reset_n<='1'; htotal<=4095;
    end if;
    wait for 1 ns;
    if step>=4100 and step mod 5=0 then
      -- Deliberately change the captured timing value in the clock-edge delta.
      htotal<=to_integer(rng(23 downto 12));
    end if;
    clock<='1'; wait for 1 ns;
assert std_logic_vector(ref_o_dev)=std_logic_vector(dut_o_dev) report "o_dev cycle/CE mismatch" severity failure;
assert std_logic_vector(ref_o_end)=std_logic_vector(dut_o_end) report "o_end cycle/CE mismatch" severity failure;
assert ref_o_hcpt=dut_o_hcpt report "o_hcpt cycle/CE mismatch" severity failure;
assert std_logic_vector(ref_o_hsv)=std_logic_vector(dut_o_hsv) report "o_hsv cycle/CE mismatch" severity failure;
assert std_logic_vector(ref_o_pev)=std_logic_vector(dut_o_pev) report "o_pev cycle/CE mismatch" severity failure;
assert ref_o_sync=dut_o_sync report "o_sync cycle/CE mismatch" severity failure;
assert ref_o_sync_max=dut_o_sync_max report "o_sync_max cycle/CE mismatch" severity failure;
assert ref_o_vcpt=dut_o_vcpt report "o_vcpt cycle/CE mismatch" severity failure;
assert ref_o_vcpt2=dut_o_vcpt2 report "o_vcpt2 cycle/CE mismatch" severity failure;
assert ref_o_vcpt_pre=dut_o_vcpt_pre report "o_vcpt_pre cycle/CE mismatch" severity failure;
assert ref_o_vcpt_pre2=dut_o_vcpt_pre2 report "o_vcpt_pre2 cycle/CE mismatch" severity failure;
assert ref_o_vcpt_pre3=dut_o_vcpt_pre3 report "o_vcpt_pre3 cycle/CE mismatch" severity failure;
assert ref_o_vcpt_sync=dut_o_vcpt_sync report "o_vcpt_sync cycle/CE mismatch" severity failure;
assert ref_o_vcpt_sync2=dut_o_vcpt_sync2 report "o_vcpt_sync2 cycle/CE mismatch" severity failure;
assert ref_o_vrr_max=dut_o_vrr_max report "o_vrr_max cycle/CE mismatch" severity failure;
assert ref_o_vrr_max2=dut_o_vrr_max2 report "o_vrr_max2 cycle/CE mismatch" severity failure;
assert ref_o_vrr_min=dut_o_vrr_min report "o_vrr_min cycle/CE mismatch" severity failure;
assert ref_o_vrr_min2=dut_o_vrr_min2 report "o_vrr_min2 cycle/CE mismatch" severity failure;
assert ref_o_vrr_sync=dut_o_vrr_sync report "o_vrr_sync cycle/CE mismatch" severity failure;
assert ref_o_vrr_sync2=dut_o_vrr_sync2 report "o_vrr_sync2 cycle/CE mismatch" severity failure;
assert ref_o_vss=dut_o_vss report "o_vss cycle/CE mismatch" severity failure;
assert std_logic_vector(ref_o_vsv)=std_logic_vector(dut_o_vsv) report "o_vsv cycle/CE mismatch" severity failure;
    if step=4094 then
      assert ref_o_hcpt=4094 report "maximum-total count missing" severity failure;
    elsif step=4095 then
      assert ref_o_hcpt=0 report "maximum-total wrap missing" severity failure;
    end if;
  end loop;
  report "PASS sweep pipeline: 65536 cycles, geometry/reset/CE/VRR/DE/sync";
  stop;
  wait;
end process;
end;
