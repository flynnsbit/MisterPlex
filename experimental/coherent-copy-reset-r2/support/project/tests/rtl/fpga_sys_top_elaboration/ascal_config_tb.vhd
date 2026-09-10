library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity ascal_config_tb is
  generic (SYS_MHZ : positive := 85; PHASE : positive := 37);
end;
architecture test of ascal_config_tb is
  signal iclk, oclk, aclk, pclk : std_logic := '0';
  signal input_ce,input_vs : std_logic := '0';
  signal clock_run : boolean := true;
  signal reset_n : std_logic := '0';
  signal cfg : unsigned(269 downto 0) := (others=>'0');
  signal req, ack : std_logic := '0';
  signal red, green, blue : unsigned(7 downto 0);
  signal hs, vs, de, vbl, brd : std_logic;
  signal avl_address : std_logic_vector(27 downto 0);
  signal avl_read,avl_write,avl_wait,avl_valid : std_logic := '0';
  signal avl_data,avl_wdata : std_logic_vector(127 downto 0) := (others=>'0');
  signal avl_burst : std_logic_vector(7 downto 0);
  signal avl_be : std_logic_vector(15 downto 0);
  signal hold_returns : boolean := false;
  signal debt, requests, responses, frames, checked : natural := 0;
  signal check_pixels : boolean := false;
  signal active_cfg : unsigned(269 downto 0) := (others=>'0');
  signal pal_ready,pal_valid,pal_bank,pal_wr,cfg_active : std_logic := '0';
  signal pal_a : unsigned(6 downto 0) := (others=>'0');
  signal pal_dw : unsigned(47 downto 0) := (others=>'0');
  type nums is array (positive range <>) of natural;
  -- The inherited 24bpp path requires word alignment; the other formats
  -- exercise their supported nonzero pixel offsets within an Avalon word.
  constant bases : nums(1 to 5) := (16#01000002#,16#02000010#,16#03000001#,16#0400000c#,16#05000009#);
  constant formats : nums(1 to 5) := (4,5,3,6,3);
  constant strides : nums(1 to 5) := (48,64,32,80,48);
  constant updates : nums(1 to 4) := (2,3,5,4);
  function pixel(x,y,k : natural) return unsigned is
    variable r,g,b : natural;
  begin
    if k=1 then
      r:=(x+3*y+3) mod 32; g:=(2*x+3*y+7) mod 64; b:=(31-x+y) mod 32;
      r:=r*8+r/4; g:=g*4+g/16; b:=b*8+b/4;
    elsif k=3 then
      r:=85; g:=102; b:=119;
    elsif k=5 then
      r:=170; g:=51; b:=102;
    else
      r:=(13*x+7*y+23*k) mod 256;
      g:=(3*x+19*y+17*k) mod 256;
      b:=(11*x+5*y+31*k) mod 256;
    end if;
    return to_unsigned(r,8)&to_unsigned(g,8)&to_unsigned(b,8);
  end;
  function byte_at(address : natural) return unsigned is
    variable k,off,x,y,bytes,p16 : natural;
    variable p : unsigned(23 downto 0);
  begin
    k:=address/16#01000000#;
    if k<1 or k>5 or address<bases(k) then return x"ad"; end if;
    off:=address-bases(k); y:=off/strides(k); off:=off mod strides(k);
    if k=1 then bytes:=2; elsif k=2 then bytes:=3; elsif formats(k)=3 then bytes:=1; else bytes:=4; end if;
    x:=off/bytes;
    if x>=16 then return x"e5"; end if;
    p:=pixel(x,y,k);
    if k=1 then
      p16:=((31-x+y) mod 32)*2048+((2*x+3*y+7) mod 64)*32+((x+3*y+3) mod 32);
      if off mod 2=0 then return to_unsigned(p16 mod 256,8); end if;
      return to_unsigned(p16/256,8);
    elsif formats(k)=3 then return x"12";
    elsif off mod bytes=0 then return p(23 downto 16);
    elsif off mod bytes=1 then return p(15 downto 8);
    elsif off mod bytes=2 then return p(7 downto 0);
    else return x"cc"; end if;
  end;
  function palette(index,k : natural) return unsigned is
  begin
    if index=18 then return pixel(0,0,k); end if;
    return to_unsigned((7*index+1) mod 256,8)&
      to_unsigned((11*index+3) mod 256,8)&to_unsigned((13*index+5) mod 256,8);
  end;
  function descriptor(k : positive) return unsigned is
    variable d : unsigned(269 downto 0) := (others=>'0');
    variable xmin,ymin : natural;
  begin
    if k=5 then xmin:=48; ymin:=40;
    elsif k mod 2=1 then xmin:=0; ymin:=8; else xmin:=112; ymin:=24; end if;
    d(269 downto 258):=to_unsigned(160,12);
    d(257 downto 246):=to_unsigned(136,12);
    d(245 downto 234):=to_unsigned(144,12);
    d(233 downto 222):=to_unsigned(128,12);
    d(221 downto 210):=to_unsigned(xmin,12);
    d(209 downto 198):=to_unsigned(xmin+15,12);
    d(197 downto 186):=to_unsigned(80,12);
    d(185 downto 174):=to_unsigned(68,12);
    d(173 downto 162):=to_unsigned(70,12);
    d(161 downto 150):=to_unsigned(64,12);
    d(149 downto 138):=to_unsigned(ymin,12);
    d(137 downto 126):=to_unsigned(ymin+6,12);
    d(120 downto 119):=to_unsigned(k mod 4,2);
    d(125 downto 121):=to_unsigned(k mod 3,5);
    d(118):='1'; d(104):='1';
    d(116 downto 105):=to_unsigned(80,12);
    d(103 downto 92):=to_unsigned(16,12);
    d(91 downto 80):=to_unsigned(7,12);
    d(79 downto 74):=to_unsigned(formats(k),6);
    d(73 downto 42):=to_unsigned(bases(k),32);
    d(41 downto 28):=to_unsigned(strides(k),14);
    return d;
  end;
begin
  process
    variable fraction : natural := 0;
    variable ticks : positive;
  begin
    loop
      ticks:=(1000000000+fraction)/(2*SYS_MHZ);
      fraction:=(1000000000+fraction) mod (2*SYS_MHZ);
      wait for ticks*1 fs;
      iclk<=not iclk;
    end loop;
  end process;
  process
    variable fraction : natural := 0;
    variable ticks : positive;
  begin
    wait for PHASE*1 ps;
    loop
      ticks:=(1000000000+fraction)/297;
      fraction:=(1000000000+fraction) mod 297;
      wait for ticks*1 fs;
      if clock_run then oclk<=not oclk; else oclk<='0'; end if;
    end loop;
  end process;
  aclk<=not aclk after 5 ns;
  process(iclk)
    variable fraction,pixel : natural := 0;
    variable enabled : boolean;
  begin
    if falling_edge(iclk) then
      input_ce<='0';
      if reset_n='0' then
        fraction:=0; pixel:=0; input_vs<='0';
      else
        fraction:=fraction+4;
        enabled:=SYS_MHZ=20 or fraction>=17;
        if enabled then
          fraction:=fraction mod 17; input_ce<='1';
          if pixel<4 then input_vs<='1'; else input_vs<='0'; end if;
          pixel:=(pixel+1) mod 2048;
        end if;
      end if;
    end if;
  end process;
  process
    variable fraction : natural := 0;
    variable ticks : positive;
  begin
    loop
      ticks:=(244140625+fraction)/12;
      fraction:=(244140625+fraction) mod 12;
      wait for ticks*1 fs;
      pclk<=not pclk;
    end loop;
  end process;
  dut:entity work.ascal
    generic map (RAMBASE=>x"20000000", CONFIG_HANDSHAKE=>true,
      OHRES=>2304, IHRES=>2048, N_DW=>128, N_AW=>28,
      FRAC=>8, PALETTE2=>false, ADAPTIVE=>true)
    port map (
      i_r=>x"00",i_g=>x"00",i_b=>x"00",i_hs=>'0',i_vs=>input_vs,
      i_fl=>'0',i_de=>'0',i_ce=>input_ce,i_clk=>iclk,
      o_r=>red,o_g=>green,o_b=>blue,o_hs=>hs,o_vs=>vs,o_de=>de,o_vbl=>vbl,o_brd=>brd,
      o_clk=>oclk,o_ce=>'1',cfg_data=>cfg,cfg_req=>req,cfg_ack=>ack,
      cfg_pal_ready=>pal_ready,cfg_pal_valid=>pal_valid,cfg_pal_bank=>pal_bank,cfg_active=>cfg_active,
      mode=>"00000",htotal=>0,hsstart=>0,hsend=>0,hdisp=>0,hmin=>0,hmax=>0,
      vtotal=>0,vsstart=>0,vsend=>0,vdisp=>0,vmin=>0,vmax=>0,
      i_hdmax=>open,i_vdmax=>open,o_lltune=>open,
      poly_clk=>iclk,poly_a=>(others=>'0'),poly_dw=>(others=>'0'),poly_wr=>'0',
      pal1_clk=>pclk,pal1_a=>pal_a,pal1_dw=>pal_dw,pal1_wr=>pal_wr,pal1_bank=>pal_bank,
      avl_clk=>aclk,avl_address=>avl_address,avl_read=>avl_read,avl_write=>avl_write,
      avl_waitrequest=>avl_wait,avl_readdata=>avl_data,avl_readdatavalid=>avl_valid,
      avl_burstcount=>avl_burst,avl_writedata=>avl_wdata,avl_byteenable=>avl_be,
      reset_na=>reset_n);

  palette_provider:process(pclk)
    variable r1,r2,tag : std_logic := '0';
    variable state : natural range 0 to 2 := 0;
    variable index,k : natural := 0;
  begin
    if rising_edge(pclk) then
      pal_wr<='0';
      if reset_n='0' then
        r1:='0'; r2:='0'; state:=0; pal_ready<='0'; pal_valid<='0';
      else
        if state=0 and r2/=pal_ready then
          tag:=r2;
          if cfg(104)='1' and cfg(76 downto 74)="011" then
            k:=to_integer(cfg(73 downto 42))/16#01000000#;
            pal_bank<=not pal_bank; index:=0; state:=1;
          else pal_ready<=tag; pal_valid<='1'; end if;
        elsif state=1 then
          pal_wr<='1'; pal_a<=to_unsigned(index,7);
          pal_dw<=palette(2*index+1,k)&palette(2*index,k);
          if index=127 then state:=2; else index:=index+1; end if;
        elsif state=2 then
          -- This edge writes the final registered palette pair.
          pal_ready<=tag; pal_valid<='1'; state:=0;
        end if;
        r2:=r1; r1:=req;
      end if;
    end if;
  end process;

  memory:process(aclk)
    type queue_t is array(0 to 3) of natural;
    variable queue : queue_t := (others=>0);
    variable head,tail,used,word,cycle : natural := 0;
    variable a : natural;
  begin
    if rising_edge(aclk) then
      avl_valid<='0'; cycle:=cycle+1;
      if cycle mod 17>=7 and cycle mod 17<=9 then avl_wait<='1'; else avl_wait<='0'; end if;
      if reset_n='0' then
        head:=0; tail:=0; used:=0; word:=0;
        debt<=0;
      else
        if avl_read='1' and avl_wait='0' then
          assert used<2 report "More than two owned scaler bursts" severity failure;
          assert unsigned(avl_burst)=16 report "Burst changed" severity failure;
          queue(tail):=to_integer(unsigned(avl_address))*16;
          tail:=(tail+1) mod 4; used:=used+1; requests<=requests+1;
        end if;
        if used>0 and not hold_returns and cycle mod 11/=3 then
          a:=queue(head)+16*word;
          for lane in 0 to 15 loop
            avl_data(8*lane+7 downto 8*lane)<=std_logic_vector(byte_at(a+lane));
          end loop;
          avl_valid<='1'; responses<=responses+1;
          if word=15 then word:=0; head:=(head+1) mod 4; used:=used-1;
          else word:=word+1; end if;
        end if;
        debt<=used;
      end if;
    end if;
  end process;

  monitor:process(oclk)
    variable old_ack,old_de,old_vbl,old_vs : std_logic := '0';
    variable x,y,k,xmin,ymin : integer := 0;
    variable p : unsigned(23 downto 0);
    variable frame_clocks : natural := 0;
  begin
    if rising_edge(oclk) then
      if ack/=old_ack then
        assert debt=0 and avl_valid='0' report "Configuration ACK with old memory debt" severity failure;
        assert de='0' report "Configuration committed during active display" severity failure;
        active_cfg<=cfg;
      end if;
      if vbl='1' then y:=-1; end if;
      if old_vbl='1' and vbl='0' then frames<=frames+1; end if;
      if de='1' then
        if old_de/='1' then x:=0; y:=y+1; else x:=x+1; end if;
        if check_pixels then
          k:=to_integer(active_cfg(73 downto 42))/16#01000000#;
          xmin:=to_integer(active_cfg(221 downto 210));
          ymin:=to_integer(active_cfg(149 downto 138));
          p:=(others=>'0');
          if x>=xmin and x<xmin+16 and y>=ymin and y<ymin+7 then
            p:=pixel(x-xmin,y-ymin,k);
          end if;
          assert (red & green & blue)=p
            report "pixel k=" & integer'image(k) & " x=" & integer'image(x) &
              " y=" & integer'image(y) & " got=" & to_hstring(red&green&blue) &
              " expected=" & to_hstring(p) severity failure;
          checked<=checked+1;
        end if;
      end if;
      if vs='0' and old_vs='1' then
        if check_pixels then
          assert frame_clocks=160*80 report "Raster frame clock count changed" severity failure;
        end if;
        frame_clocks:=0;
      end if;
      frame_clocks:=frame_clocks+1;
      old_ack:=ack; old_de:=de; old_vbl:=vbl; old_vs:=vs;
    end if;
  end process;

  stimulus:process
    variable target : std_logic;
    variable old_requests : natural;
    procedure ticks(n : positive) is begin
      for i in 1 to n loop wait until falling_edge(iclk); end loop;
    end;
    procedure send(k : positive) is begin
      ticks(1); cfg<=descriptor(k); req<=not req; target:=not req; ticks(1);
    end;
    procedure accepted is begin
      for i in 1 to 50000 loop
        exit when ack=target;
        ticks(1);
      end loop;
      assert ack=target report "Descriptor acknowledgement deadline" severity failure;
      ticks(5);
    end;
    procedure full_frames(n : positive) is begin
      for i in 1 to n loop wait until falling_edge(vs); end loop;
    end;
  begin
    ticks(4); reset_n<='1'; ticks(4);
    send(1); accepted;
    full_frames(3); check_pixels<=true; full_frames(2); check_pixels<=false;
    for n in updates'range loop
      -- Let an old accepted burst cross VS while a new tuple is pending.
      wait until falling_edge(vs);
      hold_returns<=true; old_requests:=requests;
      for i in 1 to 50000 loop exit when requests>old_requests; ticks(1); end loop;
      assert debt>0 report "Pending-read case did not own a burst" severity failure;
      send(updates(n));
      full_frames(1);
      assert ack/=target report "Old fetch/FIFO was not drained" severity failure;
      hold_returns<=false;
      accepted;
      full_frames(2); check_pixels<=true; full_frames(2); check_pixels<=false;
    end loop;
    -- A stopped output clock must not acknowledge or tear a source tuple.
    wait until falling_edge(oclk); clock_run<=false; ticks(4);
    send(1); ticks(200); assert ack/=target report "Stopped-clock ACK" severity failure;
    clock_run<=true; accepted;
    full_frames(2); check_pixels<=true; full_frames(2); check_pixels<=false;
    assert requests>70 and checked>50000 report "Missing pixel/burst workload" severity failure;
    report "PASS actual ascal configuration: pixels=" & integer'image(checked) &
      " requests=" & integer'image(requests) & " responses=" & integer'image(responses);
    stop;
    wait;
  end process;
  process begin wait for 5 ms; assert false report "Global ascal test deadline" severity failure; end process;
end;
