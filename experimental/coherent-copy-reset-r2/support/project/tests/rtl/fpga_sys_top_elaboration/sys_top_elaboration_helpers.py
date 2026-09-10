"""Whole-top adapters; generated vendor declarations remain in ignored build/.

No design module is replaced. Only the explicitly listed Intel hard interfaces
are extracted from installed libraries. The vendor synchronizer retains its body.
"""

import re
from pathlib import Path


HPS_ATOMS = (
    "mpu_general_purpose", "peripheral_uart", "interrupts", "peripheral_i2c",
    "peripheral_spi_master", "clocks_resets", "tpiu_trace", "boot_from_fpga",
    "fpga2hps", "hps2fpga", "fpga2sdram",
)
VENDOR_FILES = (
    "cyclonev_atoms.v", "altera_mf.v", "altera_lnsim.sv",
    "cyclonev_wysiwyg_components.vhd", "stratixv_atoms.v",
    "arriav_atoms.v", "arriavgz_atoms.v",
)
ASCAL_SPECIALIZATION = {
    "CONFIG_HANDSHAKE": "true",
    "MASK": 'x"FF"', "RAMBASE": 'x"20000000"', "RAMSIZE": 'x"00800000"',
    "INTER": "true", "HEADER": "true", "DOWNSCALE": "true",
    "BYTESWAP": "true", "PALETTE": "true", "PALETTE2": "false",
    "ADAPTIVE": "true", "DOWNSCALE_NN": "false", "FRAC": "8",
    "OHRES": "2304", "IHRES": "2048", "N_DW": "128", "N_AW": "28",
    "N_BURST": "256",
}

def ascal_vertical_edge_stages(text):
    vertical = text[text.index("VSCAL:PROCESS"):]
    return vertical[vertical.index("-- CYCLE 8"):vertical.index("-- BILINEAR / SHARP BILINEAR")]


def write_ascal_timing_tb(source: Path, output: Path):
    """Exercise actual coefficient, pixel mux and vertical-edge stages."""
    text = source.read_text()
    pipeline = text[text.index("-- C5 / HC5 / VC6"):text.index("END PROCESS PolyFetch;")]
    pixel = text[text.index("IF o_sh4='1' THEN"):]
    end_pixel = "\n\t\t\tEND IF;"
    pixel = pixel[:pixel.index(end_pixel) + len(end_pixel)]
    vertical = ascal_vertical_edge_stages(text)
    phase = "fracnn_v := o_vfrac(o_vfrac'left);"
    names = set(re.findall(r"\bo_\w+\b", pipeline + pixel + vertical + phase))
    declarations = []
    for declaration in re.findall(r"\bSIGNAL\b[^;]+;", text, re.I):
        if names.intersection(re.findall(r"\bo_\w+\b", declaration.split(":")[0])):
            declarations.append(declaration)
    records = []
    for name in ("type_pix", "poly_phase_t", "poly_phase_interp_t",
                 "poly_phase_diff_t", "poly_phase_product_t"):
        match = re.search(r"\bTYPE " + name + r"\b.*?END RECORD;", text, re.S)
        if match:
            records.append(match.group())
    records.append(re.search(r"\bTYPE arr_pix\b[^;]+;", text).group())
    records.append(re.search(r"\bSUBTYPE uint12\b[^;]+;", text, re.I).group())
    functions = re.findall(r"\bFUNCTION poly_(?:diff|product|lerp|cvt)\b.*?END FUNCTION;",
                           text, re.S)
    output.write_text(
        """library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity ascal_timing_tb is end;
architecture test of ascal_timing_tb is
"""
        + "\n".join(records + declarations + functions)
        + """
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
"""
        + pipeline
        + """
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
"""
        + pixel
        + """
    end if;
  end if;
end process;
vertical_edge: process(o_clk)
  variable fracnn_v : std_logic;
  variable pixq_v : arr_pix(0 to 3);
begin
  if rising_edge(o_clk) then
    if o_ce='1' then
"""
        + phase + "\n" + vertical
        + """
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
""")


def write_ascal_sweep_tb(reference: Path, candidate: Path, output: Path):
    """Compare actual sweep/config stages, including changing geometry and CE."""
    sources = [reference.read_text(), candidate.read_text()]
    process = re.compile(r"OSWEEP:PROCESS\(o_clk\).*?END PROCESS OSWEEP;", re.S)
    sweeps = [process.search(text).group() for text in sources]
    capture = re.compile(r"o_htotal\s*<=htotal;[^\n]*|IF htotal>0 THEN.*?END IF;", re.S)
    captures = [capture.search(text).group() for text in sources]
    targets = sorted(set(re.findall(r"\b(o_\w+)\s*(?:\([^;\n]*?\))?\s*<=", sweeps[0])))
    names = set(re.findall(r"\bo_\w+\b", "\n".join(sweeps + captures)))
    controls = names - set(targets) - {"o_clk", "o_ce", "o_htotal", "o_hlast"}
    kinds = {}
    declarations = []
    bodies = []

    def rename(text, prefix):
        return re.sub(r"\bo_\w+\b", lambda m: {
            "o_clk": "clock", "o_ce": "enable",
        }.get(m.group(), prefix + m.group()), text)

    for text, sweep, sample, prefix in zip(sources, sweeps, captures, ("ref_", "dut_")):
        for declaration in re.findall(r"^\s*SIGNAL\b[^;]+;", text, re.I | re.M):
            left, kind = declaration.split(":", 1)
            if names.intersection(re.findall(r"\bo_\w+\b", left)):
                declarations.append(rename(declaration, prefix))
                for name in re.findall(r"\bo_\w+\b", left):
                    kinds[name] = kind.rstrip(";").strip().lower()
        bodies.append(rename(sweep, prefix).replace("OSWEEP", prefix + "sweep"))
        bodies.append(f"""
{prefix}capture: process(clock) begin
  if rising_edge(clock) then
    if config_reset_n='1' then
      {rename(sample, prefix)}
    end if;
  end if;
end process;
""")
    drives = []
    for index, name in enumerate(sorted(controls)):
        if kinds[name] == "uint12":
            value = f"(to_integer(rng(11 downto 0))+{index * 37}) mod 4096"
        elif kinds[name] == "std_logic":
            value = f"rng({index % 32})"
        elif kinds[name] == "boolean":
            value = f"rng({index % 32})='1'"
        else:
            raise ValueError(f"Unsupported sweep input {name}: {kinds[name]}")
        drives.append(f"ref_{name}<={value}; dut_{name}<={value};")
    assertions = []
    for name in targets:
        left, right = f"ref_{name}", f"dut_{name}"
        if kinds[name].startswith("unsigned("):
            # Compare matching uninitialized pipeline bits before their first CE.
            left, right = f"std_logic_vector({left})", f"std_logic_vector({right})"
        assertions.append(
            f'assert {left}={right} report "{name} cycle/CE mismatch" severity failure;')
    assertions = "\n".join(assertions)
    convert = re.search(r"FUNCTION to_std_logic\b.*?END FUNCTION to_std_logic;",
                        sources[0], re.S).group()
    old_condition = re.search(r"IF (o_hcpt[^ \n]+) THEN", sweeps[0]).group(1)
    new_condition = re.search(r"IF (o_hcpt[^ \n]+) THEN", sweeps[1]).group(1)
    old_condition = old_condition.replace("o_hcpt", "c").replace("o_htotal", "t")
    new_condition = new_condition.replace("o_hcpt", "c").replace("o_hlast", "last_pixel")
    new_capture = re.sub(r"\bhtotal\b", "t", captures[1])
    new_capture = new_capture.replace("o_hlast", "last_pixel").replace("<=", ":=")
    output.write_text("""
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
""" + convert + "\n" + "\n".join(declarations) + f"""
function old_continue(c,t : uint12) return boolean is
begin return {old_condition}; end;
function new_continue(c,t : uint12) return boolean is
  variable last_pixel : uint12;
begin
  {new_capture}
  return {new_condition};
end;
begin
""" + "\n".join(bodies) + """
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
""" + "\n".join(drives) + """
    if step<4100 then
      enable<='1'; config_reset_n<='1'; htotal<=4095;
    end if;
    wait for 1 ns;
    if step>=4100 and step mod 5=0 then
      -- Deliberately change the captured timing value in the clock-edge delta.
      htotal<=to_integer(rng(23 downto 12));
    end if;
    clock<='1'; wait for 1 ns;
""" + assertions + """
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
""")


def arithmetic_projection(reference: Path, candidate: Path, output: Path, kind):
    """Replay actual arithmetic into its old whole-file equivalence harness.

    Framework reset/configuration changes are deliberately NOT arithmetic
    equivalence claims. Whole-ascal and actual-bridge tests cover those changes.
    Existing arithmetic assertions and cycle/sample budgets remain untouched.
    """
    before, after = reference.read_text(), candidate.read_text()
    if kind == "fraction":
        pattern = r"HSCAL:PROCESS\(o_clk\).*?END PROCESS HSCAL;"
        old = re.search(pattern, before, re.S).group()
        actual = re.search(pattern, after, re.S).group()
        projected = before.replace(old, actual)
        if ascal_fraction_unchanged(before) != ascal_fraction_unchanged(projected):
            raise ValueError("Actual HSCAL changed more than the qualified fraction cone")
    elif kind == "burst":
        old_decl = "\tSIGNAL o_hburst,o_hbcpt : natural RANGE 0 TO 31;"
        actual_decl = re.search(
            r"\tSIGNAL o_hbcpt : natural RANGE 0 TO 31;\n"
            r"\tSIGNAL o_hburst_last : integer RANGE -1 TO 30;", after).group()
        old_capture = "\t\t\to_hburst <= o_ihsize_temp2 / N_BURST;"
        actual_capture = re.search(
            r"\t\t\t-- Encode the terminal count.*?\n"
            r"\t\t\to_hburst_last <= o_ihsize_temp2 / N_BURST - 1;", after, re.S).group()
        projected = before.replace(old_decl, actual_decl).replace(old_capture, actual_capture)
        projected = projected.replace("o_hburst-1", "o_hburst_last")
        for pattern in (r"last_v:=to_std_logic\(o_hbcpt=[^;]+;",
                        r"WHEN sWAITREAD =>.*?END CASE;"):
            if re.search(pattern, after, re.S).group() != re.search(pattern, projected, re.S).group():
                raise ValueError("Actual terminal decision/FSM differs from projected arithmetic")
        if len(re.findall(r"\bo_hburst_last\b", after)) != 4:
            raise ValueError("Unexpected terminal-count consumers")
    else:
        raise ValueError(kind)
    output.write_text(projected)


def write_ascal_burst_tb(reference: Path, candidate: Path, output: Path):
    before, after = reference.read_text(), candidate.read_text()
    restored = after.replace(
        "\tSIGNAL o_hbcpt : natural RANGE 0 TO 31;\n"
        "\tSIGNAL o_hburst_last : integer RANGE -1 TO 30;",
        "\tSIGNAL o_hburst,o_hbcpt : natural RANGE 0 TO 31;")
    restored = restored.replace(
        "\t\t\t-- Encode the terminal count at the original configuration stage.\n"
        "\t\t\t-- -1 preserves the zero-burst comparison, including initialization.\n"
        "\t\t\to_hburst_last <= o_ihsize_temp2 / N_BURST - 1;",
        "\t\t\to_hburst <= o_ihsize_temp2 / N_BURST;")
    restored = restored.replace("o_hburst_last", "o_hburst-1")
    if restored != before:
        raise ValueError("Burst correction changed unrelated scaler/fraction/pixel logic")
    declarations, bodies = [], []
    for text, prefix, name, kind in (
            (before, "ref_", "o_hburst", "natural RANGE 0 TO 31"),
            (after, "dut_", "o_hburst_last", "integer RANGE -1 TO 30")):
        declaration = f"SIGNAL {prefix}{name} : {kind};"
        config = re.search(r"\b" + name + r"\s*<=\s*o_ihsize_temp2[^;]+;", text).group()
        last = re.search(r"last_v:=to_std_logic\(o_hbcpt=[^;]+;", text).group()
        body = re.search(r"WHEN sWAITREAD =>(.*?)END CASE;", text, re.S).group(1)
        body = re.sub(r"\b(o_hbcpt|o_fload|o_state)\s*<=",
                      lambda m: prefix + "next_" + m.group()[:-2].strip() + "<=", body)
        def rename(value):
            names = {name: prefix + name, "o_hbcpt": "count_in",
                     "o_fload": "load_in", "o_readack": "ack_in",
                     "last_v": prefix + "last_out"}
            return re.sub(r"\b(?:o_hburst_last|o_hburst|o_hbcpt|o_fload|o_readack|last_v)\b",
                          lambda m: names[m.group()], value)
        last = rename(last).replace(":=", "<=").replace("to_std_logic", "bool_bit")
        declarations.append(declaration + f"""
signal {prefix}next_o_hbcpt : natural range 0 to 32;
signal {prefix}next_o_fload : natural range 0 to 3;
signal {prefix}next_o_state : state_t;
signal {prefix}last_out : std_logic;
""")
        bodies.append(f"""
process(clk) begin
 if rising_edge(clk) then
  {rename(config)}
  {prefix}next_o_hbcpt <= count_in;
  {prefix}next_o_fload <= load_in;
  {prefix}next_o_state <= sWAITREAD;
  {last}
  {rename(body)}
 end if;
end process;
""")
    output.write_text("""
library ieee;
use ieee.std_logic_1164.all;
use std.env.all;
entity ascal_burst_tb is end;
architecture test of ascal_burst_tb is
type state_t is (sREAD,sDISP,sWAITREAD);
constant N_BURST : natural := 128;
signal clk : std_logic := '0';
signal o_ihsize_temp2 : natural range 0 to 4095 := 0;
signal count_in : natural range 0 to 31 := 0;
signal load_in : natural range 0 to 3 := 0;
signal ack_in : std_logic := '0';
function bool_bit(v:boolean) return std_logic is
begin if v then return '1'; else return '0'; end if; end;
""" + "".join(declarations) + "\nbegin\nclk <= not clk after 1 ns;\n" +
        "".join(bodies) + """
process begin
 for burst in 0 to 31 loop
  for count in 0 to 31 loop
   for load in 0 to 3 loop
    for ack in 0 to 1 loop
     o_ihsize_temp2 <= burst*N_BURST+count;
     count_in <= count; load_in <= load; ack_in <= bool_bit(ack=1);
     wait until rising_edge(clk); wait for 0 ns; wait for 0 ns;
     assert ref_o_hburst=dut_o_hburst_last+1 severity failure;
     assert ref_last_out=dut_last_out severity failure;
     assert ref_next_o_hbcpt=dut_next_o_hbcpt severity failure;
     assert ref_next_o_fload=dut_next_o_fload severity failure;
     assert ref_next_o_state=dut_next_o_state severity failure;
    end loop;
   end loop;
  end loop;
 end loop;
 report "PASS burst terminal: 8192 cycles, zero/31 edges, configuration capture, readack/fload/state exact";
 stop; wait;
end process;
end;
""")


def ascal_fraction_unchanged(text):
    start = text.index("div_v:=o_div(2);")
    end = text.index("o_hfrac(1)<=dir_v;", start)
    text = text[:start] + text[end:]
    for declaration in (
            "\t\tVARIABLE mag_v : unsigned(19 DOWNTO 0);\n",
            "\t\tVARIABLE ge2_v,ge4_v,ge6_v : std_logic;\n"):
        text = text.replace(declaration, "")
    return text


def write_ascal_fraction_tb(reference: Path, candidate: Path, output: Path):
    """Compare extracted final arithmetic and complete HSCAL/OSWEEP processes."""
    texts = [reference.read_text(), candidate.read_text()]
    if ascal_fraction_unchanged(texts[0]) != ascal_fraction_unchanged(texts[1]):
        raise ValueError("Unrelated scaler logic changed")
    horizontal = [re.search(r"HSCAL:PROCESS\(o_clk\).*?END PROCESS HSCAL;",
                            text, re.S).group() for text in texts]
    if texts[0].replace(horizontal[0], "") != texts[1].replace(horizontal[1], ""):
        raise ValueError("Fraction change modified logic outside HSCAL")
    sweeps = [re.search(r"OSWEEP:PROCESS\(o_clk\).*?END PROCESS OSWEEP;",
                       text, re.S).group() for text in texts]
    generic = re.search(r"\bGENERIC\s*\(.*?\n\s*\);", texts[0], re.S).group()
    declarative = texts[0].split("ARCHITECTURE rtl OF ascal IS", 1)[1].split("\nBEGIN", 1)[0]
    declarative = re.sub(r"^\s*ATTRIBUTE\b[^;]+;", "", declarative, flags=re.M | re.I)
    signal_pattern = r"^\s*SIGNAL\b[^;]+;"
    signals = re.findall(signal_pattern, declarative, re.M | re.I)
    shared = re.sub(signal_pattern, "", declarative, flags=re.M | re.I)
    names = set(re.findall(r"\bo_\w+\b", horizontal[0] + sweeps[0]))
    targets = set(re.findall(r"\b(o_\w+)\s*(?:\([^;\n]*?\))?\s*<=",
                             horizontal[0] + sweeps[0]))
    controls = names - targets - {"o_clk", "o_ce"}
    kinds, declarations, bodies, functions = {}, [], [], []

    def rename(text, prefix):
        return re.sub(r"\bo_\w+\b", lambda m: m.group() if m.group() in
                      {"o_clk", "o_ce"} else prefix + m.group(), text)

    for text, hscal, sweep, prefix in zip(texts, horizontal, sweeps, ("ref_", "dut_")):
        for declaration in signals:
            left, kind = declaration.split(":", 1)
            if names.intersection(re.findall(r"\bo_\w+\b", left)):
                declarations.append(rename(declaration, prefix))
                for name in re.findall(r"\bo_\w+\b", left):
                    kinds[name] = kind.rstrip(";").strip().lower()
        bodies.append(rename(hscal, prefix).replace("HSCAL", prefix + "hscal"))
        bodies.append(rename(sweep, prefix).replace("OSWEEP", prefix + "sweep"))
        variables = hscal.split(" IS", 1)[1].split("BEGIN", 1)[0]
        final = hscal[hscal.index("div_v:=o_div(2);"):hscal.index("o_hfrac(1)<=dir_v;")]
        final = final.replace("o_div(2)", "d").replace("o_dir(2)", "q")
        functions.append(f"""
function {prefix}fraction(d : unsigned(20 downto 0); q : unsigned(11 downto 0);
                         o_hsize : uint12) return unsigned is
{variables}
begin
{final}
return dir_v;
end;
""")
    drives = []
    for i, name in enumerate(sorted(controls)):
        kind = kinds[name]
        if kind == "uint12":
            value = f"(to_integer(rng(11 downto 0))+{i * 37}) mod 4096"
        elif kind.startswith("natural range"):
            value = "to_integer(rng(13 downto 0)) mod (4*OHRESH)"
        elif kind == "std_logic":
            value = f"rng({i % 32})"
        elif kind == "boolean":
            value = f"rng({i % 32})='1'"
        elif kind.startswith("unsigned("):
            value = f"resize(rng,ref_{name}'length)"
        elif kind == "type_pix":
            value = f"pix(step+{i * 71})"
        elif kind == "poly_phase_interp_t":
            value = f"poly_cvt(poly_nn(to_unsigned(step mod (2**FRAC),FRAC)))"
        else:
            raise ValueError(f"Unsupported HSCAL input {name}: {kind}")
        drives.append(f"ref_{name}<={value}; dut_{name}<={value};")
    assertions = []
    for name in sorted(targets):
        suffix = "(1 to 9)" if name == "o_hfrac" else ""
        assertions.append(f'assert ref_{name}{suffix}=dut_{name}{suffix} report '
                          f'"{name} phase/value mismatch at " & integer\'image(step) severity failure;')
    output.write_text("""
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity ascal_fraction_tb is
""" + generic + """
end;
architecture test of ascal_fraction_tb is
signal o_clk : std_logic := '0';
signal o_ce : std_logic := '0';
""" + shared + "\n".join(declarations + functions) + """
function pix(n : natural) return type_pix is
begin
  return (to_unsigned(n mod 256,8),to_unsigned((n+71) mod 256,8),
          to_unsigned((n+157) mod 256,8));
end;
begin
""" + "\n".join(bodies) + """
stimulus: process
  variable rng : unsigned(31 downto 0) := x"5E3AB701";
  variable cases,frames : natural := 0;
  variable d : integer;
  procedure next_random is
  begin
    rng:=rng xor shift_left(rng,13);
    rng:=rng xor shift_right(rng,17);
    rng:=rng xor shift_left(rng,5);
  end;
  procedure sample(x : integer; size : natural) is
    variable bits : unsigned(20 downto 0);
    variable q : unsigned(11 downto 0);
  begin
    bits:=unsigned(to_signed(x,21));
    q:=rng(11 downto 0);
    assert ref_fraction(bits,q,size)=dut_fraction(bits,q,size)
      report "fraction mismatch x=" & integer'image(x) &
             " size=" & integer'image(size) severity failure;
    cases:=cases+1;
  end;
begin
  -- Every divisor, both signs, each decision boundary and adjacent value.
  -- Include the complete signed input extremes, not only reachable remainders.
  for size in 0 to 4095 loop
    for multiple in -3 to 3 loop
      for offset in -1 to 1 loop
        next_random;
        sample(multiple*2*size+offset,size);
      end loop;
    end loop;
    sample(-1048576,size); sample(-1048575,size);
    sample(1048574,size); sample(1048575,size);
  end loop;
  for n in 0 to 65535 loop
    next_random;
    sample(to_integer(signed(rng(20 downto 0))),to_integer(rng(31 downto 20)));
  end loop;
  report "PASS fraction arithmetic: " & integer'image(cases) & " exact pairs";
  -- Actual full HSCAL processes: all quotient pipeline registers, every
  -- interpolator, luma, write address/data/enables. OSWEEP runs alongside
  -- with its original CE, sync/blanking/VRR state. No added pipeline stage.
  for step in 0 to 32767 loop
    next_random;
    o_clk<='0';
    o_ce<=rng(0);
""" + "\n".join(drives) + """
    ref_o_copyv(0)<=rng(8); dut_o_copyv(0)<=rng(8);
    if step mod 8<3 then
      case step mod 8 is
        when 0 => ref_o_hsize<=0; dut_o_hsize<=0;
        when 1 => ref_o_hsize<=1; dut_o_hsize<=1;
        when others => ref_o_hsize<=4095; dut_o_hsize<=4095;
      end case;
    end if;
    -- Clear the real write-coordinate pipeline before testing increment/wrap.
    if step<32 then
      ref_o_dcpt_clr<='1'; dut_o_dcpt_clr<='1';
    elsif step<8192 then
      ref_o_dcpt_clr<='0'; dut_o_dcpt_clr<='0';
      ref_o_dcpt_inc<='1'; dut_o_dcpt_inc<='1';
    end if;
    if step<8192 then
      o_ce<='1';
      if step mod 5=0 then o_ce<='0'; end if;
      ref_o_htotal<=32; dut_o_htotal<=32;
      ref_o_vtotal<=16; dut_o_vtotal<=16;
      ref_o_hdisp<=24; dut_o_hdisp<=24;
      ref_o_vdisp<=12; dut_o_vdisp<=12;
      ref_o_hsstart<=26; dut_o_hsstart<=26;
      ref_o_hsend<=30; dut_o_hsend<=30;
      ref_o_vsstart<=13; dut_o_vsstart<=13;
      ref_o_vsend<=15; dut_o_vsend<=15;
      ref_o_isync2<='0'; dut_o_isync2<='0';
      ref_o_vrr<='0'; dut_o_vrr<='0';
      ref_o_run<='1'; dut_o_run<='1';
    end if;
    wait for 1 ns;
    if step mod 7=0 then
      -- Match the original register sampling delta when geometry changes
      -- at the active edge rather than one full cycle before it.
      ref_o_hsize<=to_integer(rng(23 downto 12));
      dut_o_hsize<=to_integer(rng(23 downto 12));
    end if;
    o_clk<='1'; wait for 1 ns;
    if step>=32 then
""" + "\n".join(assertions) + """
    end if;
    if step<8192 and o_ce='1' and ref_o_hcpt=0 and ref_o_vcpt_pre3=0 then
      frames:=frames+1;
    end if;
  end loop;
  assert frames=12 report "Unexpected reference frame count" severity failure;
  report "PASS HSCAL/OSWEEP phase: 32768 cycles, 12 frames, FRAC=" &
         integer'image(FRAC) & " OHRES=" & integer'image(OHRES);
  stop;
  wait;
end process;
end;
""")


def no_comments(text, vhdl=False):
    if vhdl:
        return re.sub(r"--[^\n]*", "", text)
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def module_text(text, name):
    match = re.search(r"\bmodule\s+" + re.escape(name) + r"\b.*?\bendmodule\b",
                      text, re.S)
    if not match:
        raise RuntimeError(f"Missing installed vendor declaration: {name}")
    return match.group()


def interface_only(text, name):
    module = no_comments(module_text(text, name))
    header, body = module.split(";", 1)
    if re.search(r"\binput\b", header):
        return header + ";\nendmodule\n"
    body = re.sub(r"\bfunction\b.*?\bendfunction\b|\btask\b.*?\bendtask\b",
                  "", body, flags=re.S)
    declarations = re.findall(
        r"(?m)^\s*((?:parameter|input|output|inout)\b[^;]*;)", body
    )
    return header + ";\n" + "\n".join(declarations) + "\nendmodule\n"


def vhdl_value(value, boolean=False):
    value = value.strip()
    if boolean:
        if value.lower() not in ("true", "false"):
            raise RuntimeError(f"Unsupported boolean default: {value}")
        return '"' + value.lower() + '"'
    if re.fullmatch(r'\d+|".*"|\'[01]\'', value):
        return value if not value.startswith("'") else "1'b" + value[1]
    if re.fullmatch(r'[xX]"[0-9a-fA-F_]+"', value):
        digits = value[2:-1].replace("_", "")
        return f"{4 * len(digits)}'h{digits}"
    if re.fullmatch(r"\(\s*OTHERS\s*=>\s*'0'\s*\)", value, re.I):
        return "'0"
    raise RuntimeError(f"Unsupported VHDL constant: {value}")


def generics(text):
    match = re.search(r"\bGENERIC\s*\((.*?)\)\s*;\s*PORT", text, re.I | re.S)
    if not match:
        raise RuntimeError("Expected VHDL generic/port declaration")
    result = {}
    for entry in match.group(1).split(";"):
        name, definition = entry.strip().split(":", 1)
        kind, _, default = definition.partition(":=")
        result[name.strip()] = (kind.strip(), default.strip())
    return result


def vendor_component(text, name):
    match = re.search(r"\bcomponent\s+" + name + r"\b(.*?)end\s+component\s*;",
                      no_comments(text, vhdl=True), re.I | re.S)
    if not match:
        raise RuntimeError(f"Missing installed vendor component: {name}")
    body = match.group(1)
    params = []
    for key, (kind, default) in generics(body).items():
        if kind.lower() not in ("natural", "string"):
            raise RuntimeError(f"Unsupported vendor generic {name}.{key}: {kind}")
        params.append(f"parameter {key} = {vhdl_value(default)}")
    port_text = re.search(r"\bport\s*\((.*)\)\s*;", body, re.I | re.S).group(1)
    ports = []
    for entry in port_text.split(";"):
        match = re.fullmatch(
            r"\s*(\w+)\s*:\s*(in|out|inout)\s+std_logic"
            r"(_vector\s*\((\d+)\s+downto\s+(\d+)\))?"
            r"(?:\s*:=.*?)?\s*", entry, re.I | re.S,
        )
        if not match:
            raise RuntimeError(f"Unsupported vendor port {name}: {entry}")
        key, direction, vector, high, low = match.groups()
        direction = {"in": "input", "out": "output", "inout": "inout"}[direction.lower()]
        width = f"[{high}:{low}] " if vector else ""
        ports.append(f"{direction} wire {width}{key}")
    return (f"module {name} #(\n" + ",\n".join(params) + "\n)(\n"
            + ",\n".join(ports) + "\n);\nendmodule\n")


def write_vendor_interfaces(directory: Path, output: Path, sysmem: Path):
    texts = {name: (directory / name).read_text(encoding="latin-1") for name in VENDOR_FILES}
    pieces, atoms = [], []
    for name, source in (
        ("cyclonev_clkselect", "cyclonev_atoms.v"),
        ("cyclonev_lcell_comb", "cyclonev_atoms.v"),
        ("stratixv_lcell_comb", "stratixv_atoms.v"),
        ("arriav_lcell_comb", "arriav_atoms.v"),
        ("arriavgz_lcell_comb", "arriavgz_atoms.v"),
        ("altsyncram", "altera_mf.v"),
        ("altddio_out", "altera_mf.v"),
        ("altera_pll", "altera_lnsim.sv"),
    ):
        pieces.append(interface_only(texts[source], name))
        atoms.append(name)
    for suffix in HPS_ATOMS:
        name = "cyclonev_hps_interface_" + suffix
        pieces.append(vendor_component(texts["cyclonev_wysiwyg_components.vhd"], name))
        atoms.append(name)
    pieces.append(module_text(texts["altera_mf.v"], "altera_std_synchronizer"))
    # This legacy hard atom is omitted from Quartus 17's public simulation
    # declarations. Its generated, constant-input-only instance is the boundary.
    debug = directory / "cyclonev_hps_interface_dbg_apb.v"
    if debug.exists():
        name = "cyclonev_hps_interface_dbg_apb"
        pieces.append(interface_only(debug.read_text(), name))
        atoms.append(name)
    else:
        instance = re.search(
            r"\bcyclonev_hps_interface_dbg_apb\s+debug_apb\s*\(.*?\);",
            no_comments(sysmem.read_text()), re.S,
        )
        expected = ("cyclonev_hps_interface_dbg_apb debug_apb("
                    ".DBG_APB_DISABLE({1'b0}),.P_CLK_EN({1'b0}));")
        if not instance or re.sub(r"\s+", "", instance.group()) != re.sub(r"\s+", "", expected):
            raise RuntimeError("Legacy debug hard-atom connections changed; review its interface")
        pieces.append("module cyclonev_hps_interface_dbg_apb("
                      "input wire DBG_APB_DISABLE, input wire P_CLK_EN); endmodule\n")
        atoms.append("cyclonev_hps_interface_dbg_apb")
    output.write_text("\n".join(pieces))
    return atoms


def write_ascal_adapter(vhdl: Path, converted: Path, output: Path):
    source = no_comments(vhdl.read_text(), vhdl=True)
    params = generics(source)
    if set(params) != set(ASCAL_SPECIALIZATION):
        raise RuntimeError("ascal generic set changed; review the exact specialization")
    declarations, assertions = [], []
    for name, (kind, default) in params.items():
        boolean = kind.lower() == "boolean"
        default = vhdl_value(default, boolean) if default else "'x"
        declarations.append(f"parameter {name} = {default}")
        expected = vhdl_value(ASCAL_SPECIALIZATION[name], boolean)
        assertions.append(f"({name} !== {expected})")
    generated = converted.read_text()
    header = re.match(r"module ascal\s*\((.*?)\);", generated, re.S)
    if not header:
        raise RuntimeError("GHDL ascal output has an unexpected module interface")
    ports = header.group(1)
    entity_ports = re.search(r"\bPORT\s*\((.*?)\);\s*(?:BEGIN\s*)?END",
                             source, re.I | re.S).group(1)
    defaults = {}
    for entry in entity_ports.split(";"):
        match = re.match(r"\s*(\w+)\s*:\s*IN\b.*?:=\s*(.*?)\s*$",
                         entry, re.I | re.S)
        if match:
            value = match.group(2)
            defaults[match.group(1).lower()] = (
                f"{len(value) - 2}'b{value[1:-1]}" if re.fullmatch(r'"[01]+"', value)
                else vhdl_value(value)
            )
    names = []
    port_declarations = []
    for declaration in ports.split(","):
        name = declaration.split()[-1]
        names.append(name)
        if name in defaults:
            declaration += " = " + defaults[name]
        port_declarations.append(declaration)
    # The generated body is retained byte-for-byte apart from its module name.
    converted.write_text(generated.replace("module ascal\n", "module ascal_ghdl\n", 1))
    output.write_text(
        "module ascal #(\n" + ",\n".join(declarations) + "\n)(\n"
        + ",".join(port_declarations) + "\n);\n"
        + "generate if (" + " ||\n".join(assertions) + ") begin : g_bad_specialization\n"
        + '  $error("ascal generics do not match the real GHDL specialization");\n'
        + "end endgenerate\n"
        + "ascal_ghdl implementation (\n"
        + ",\n".join(f".{name}({name})" for name in names) + "\n);\nendmodule\n"
    )
