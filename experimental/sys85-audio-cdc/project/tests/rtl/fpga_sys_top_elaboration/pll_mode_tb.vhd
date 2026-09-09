library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity pll_mode_tb is
  generic (SYS_MHZ : positive := 85; PHASE : positive := 37);
end;
architecture test of pll_mode_tb is
  signal source_clk,clk,mode : std_logic := '0';
  signal reset_n : std_logic := '0';
  signal running : boolean := true;
  signal write_en : std_logic := '0';
  signal addr : unsigned(5 downto 0) := (others=>'0');
  signal data : unsigned(31 downto 0) := (others=>'0');
  signal tune : unsigned(15 downto 0) := (others=>'0');
  signal source_count : natural range 0 to 191 := 0;
begin
  process
    variable fraction : natural := 0;
    variable ticks : positive;
  begin
    loop
      ticks:=(1000000000+fraction)/(2*SYS_MHZ);
      fraction:=(1000000000+fraction) mod (2*SYS_MHZ);
      wait for ticks*1 fs; source_clk<=not source_clk;
    end loop;
  end process;
  process begin
    wait for PHASE*1 ps;
    loop
      wait for 10 ns;
      if running then clk<=not clk; else clk<='0'; end if;
    end loop;
  end process;
  tune(6)<=source_clk;
  tune(5)<='1';
  tune(0)<='1' when source_count<4 else '0';
  tune(1)<='1' when source_count mod 32<16 else '0';
  process(source_clk) begin
    if rising_edge(source_clk) then source_count<=(source_count+1) mod 192; end if;
  end process;
  process begin
    wait for 503 ns;
    loop tune(4)<='1'; wait for 100 ns; tune(4)<='0'; wait for 900 ns; end loop;
  end process;
  dut:entity work.pll_hdmi_adj port map (
    clk=>clk,reset_na=>reset_n,llena=>mode,lltune=>tune,locked=>open,
    i_waitrequest=>open,i_write=>write_en,i_address=>addr,i_writedata=>data,
    o_waitrequest=>'0',o_write=>open,o_address=>open,o_writedata=>open);
  process
    procedure source_ticks(n : positive) is begin
      for i in 1 to n loop wait until falling_edge(source_clk); end loop;
    end;
  begin
    wait for 67 ns; reset_n<='1';
    wait until falling_edge(clk); addr<="000100"; data<=x"00000505"; write_en<='1';
    wait until falling_edge(clk); addr<="000111"; data<=x"80000000";
    wait until falling_edge(clk); write_en<='0';
    for i in 1 to 24 loop
      source_ticks(7+i); mode<=not mode;
    end loop;
    mode<='1'; wait for 73 ns; reset_n<='0';
    wait for 23 ns; reset_n<='1';
    source_ticks(8);
    wait until falling_edge(clk); running<=false;
    source_ticks(3); mode<='0'; source_ticks(3); mode<='1';
    reset_n<='0'; wait for 23 ns; reset_n<='1';
    source_ticks(4); running<=true;
    wait for 180 ns;
    report "PASS actual PLL mode stimulus";
    stop; wait;
  end process;
end;
