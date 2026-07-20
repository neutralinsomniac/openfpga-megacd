-- Testbench for the MegaCD ASIC word-RAM subsystem with EXTERNAL word RAM.
-- Reproduces the Pocket port's memory model: a single-server word-RAM
-- backend with the arbiter's semantics (per-direction holds, address/data
-- latched at grant, LATENCY cycles per access) and gen.sv-like EXT bus
-- cycles with a small turnaround gap.
--
-- Scenarios:
--   1. 2M mode: main (EXT) writes a pattern, reads it back back-to-back
--   2. handoff churn: DMNA/RET flips interleaved with EXT traffic
--   3. 1M mode switch sanity (no hang)
--
-- Run with LATENCY=1 (BRAM-like) and LATENCY=12 (SDRAM-like) and compare.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_asic is
	generic (
		LATENCY : natural := 12;
		GAP     : natural := 2;
		ARMED   : boolean := false   -- model the exp_dtack_armed MBUS fix
	);
end entity;

architecture sim of tb_asic is
	signal CLK   : std_logic := '0';
	signal RST_N : std_logic := '0';
	signal stop  : boolean := false;

	signal S68K_A       : std_logic_vector(23 downto 1) := (others => '0');
	signal S68K_DI      : std_logic_vector(15 downto 0) := (others => '0');
	signal S68K_DO      : std_logic_vector(15 downto 0);
	signal S68K_AS_N    : std_logic := '1';
	signal S68K_RNW     : std_logic := '1';
	signal S68K_UDS_N   : std_logic := '1';
	signal S68K_LDS_N   : std_logic := '1';
	signal S68K_DTACK_N : std_logic;
	signal S68K_CE_F, S68K_CE_R : std_logic;

	signal EXT_VA      : std_logic_vector(17 downto 1) := (others => '0');
	signal EXT_VDI     : std_logic_vector(15 downto 0) := (others => '0');
	signal EXT_VDO     : std_logic_vector(15 downto 0);
	signal EXT_AS_N    : std_logic := '1';
	signal EXT_RNW     : std_logic := '1';
	signal EXT_UDS_N   : std_logic := '1';
	signal EXT_LDS_N   : std_logic := '1';
	signal EXT_DTACK_N : std_logic;
	signal EXT_ASEL_N  : std_logic := '1';
	signal EXT_VCLK_CE : std_logic := '0';
	signal EXT_RAS2_N  : std_logic := '1';
	signal EXT_ROM_N   : std_logic := '1';
	signal EXT_FDC_N   : std_logic := '1';

	signal WR0_A, WR1_A   : std_logic_vector(15 downto 0);
	signal WR0_DI, WR1_DI : std_logic_vector(15 downto 0) := (others => '0');
	signal WR0_DO, WR1_DO : std_logic_vector(15 downto 0);
	signal WR0_RD, WR0_WR, WR1_RD, WR1_WR : std_logic;
	signal WR0_RDY, WR1_RDY : std_logic := '1';

	signal ERES_N : std_logic;

	signal err_cnt : natural := 0;
	signal sub_go   : boolean := false;
	signal sub_done : boolean := false;
	-- command channel: stim -> s68k bus owner
	signal sc_req  : boolean := false;
	signal sc_ack  : boolean := false;
	signal sc_addr : natural := 0;
	signal sc_wr   : boolean := false;
	signal sc_data : std_logic_vector(15 downto 0) := (others => '0');
	signal sc_rdata : std_logic_vector(15 downto 0) := (others => '0');

	type mem_t is array (0 to 65535) of std_logic_vector(15 downto 0);

	function pat(i : natural) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned((i * 7 + 16#1234#) mod 65536, 16));
	end function;

begin
	CLK <= not CLK after 9.3 ns when not stop else '0';

	vclk: process
		variable c : natural := 0;
	begin
		loop
			wait until rising_edge(CLK);
			exit when stop;
			c := (c + 1) mod 7;
			if c = 0 then EXT_VCLK_CE <= '1'; else EXT_VCLK_CE <= '0'; end if;
		end loop;
		wait;
	end process;

	dut: entity work.ASIC
		port map (
			CLK => CLK, RST_N => RST_N, ENABLE => '1',
			S68K_A => S68K_A, S68K_DI => S68K_DI, S68K_DO => S68K_DO,
			S68K_AS_N => S68K_AS_N, S68K_RNW => S68K_RNW,
			S68K_UDS_N => S68K_UDS_N, S68K_LDS_N => S68K_LDS_N,
			S68K_DTACK_N => S68K_DTACK_N,
			S68K_IPL_N => open, S68K_VPA_N => open,
			S68K_FC => "01", S68K_HALT_N => open, S68K_RESET_N => open,
			S68K_CE_F => S68K_CE_F, S68K_CE_R => S68K_CE_R,
			EXT_VA => EXT_VA, EXT_VDI => EXT_VDI, EXT_VDO => EXT_VDO,
			EXT_AS_N => EXT_AS_N, EXT_RNW => EXT_RNW,
			EXT_UDS_N => EXT_UDS_N, EXT_LDS_N => EXT_LDS_N,
			EXT_DTACK_N => EXT_DTACK_N, EXT_ASEL_N => EXT_ASEL_N,
			EXT_VCLK_CE => EXT_VCLK_CE, EXT_RAS2_N => EXT_RAS2_N,
			EXT_ROM_N => EXT_ROM_N, EXT_FDC_N => EXT_FDC_N,
			PRG_A => open, PRG_DI => (others => '0'), PRG_DO => open,
			PRG_WRL_N => open, PRG_WRH_N => open, PRG_OE_N => open,
			PRG_RFS => open, PRG_RDY => '1',
			PCM_A => open, PCM_DI => open, PCM_WE_N => open, PCM_N => open,
			ROM_DI => (others => '0'), ROM_CE_N => open, ROM_RDY => '1',
			PRAM_N => open, BRAM_N => open, BROM_N => open,
			CDC_N => open, COE_N => open, CLWE_N => open, CUWE_N => open,
			CDC_INT_N => '1', ERES_N => ERES_N,
			CDC_HDI => (others => '0'), CDC_HRD_N => open,
			CDC_DTEN_N => '1', CDC_WAIT_N => '1',
			CD_DI => (others => '0'), CD_SC_WR => '0',
			CDD_STAT => (others => '0'), CDD_COMM => open,
			CDD_SEND => open, CDD_REC => '0', CDD_DM => '0',
			WORDRAM0_A => WR0_A, WORDRAM0_DI => WR0_DI, WORDRAM0_DO => WR0_DO,
			WORDRAM0_RD => WR0_RD, WORDRAM0_WR => WR0_WR, WORDRAM0_RDY => WR0_RDY,
			WORDRAM1_A => WR1_A, WORDRAM1_DI => WR1_DI, WORDRAM1_DO => WR1_DO,
			WORDRAM1_RD => WR1_RD, WORDRAM1_WR => WR1_WR, WORDRAM1_RDY => WR1_RDY,
			FD_DAT => open, FD_WR => open,
			LED_RED => open, LED_GREEN => open
		);

	-- word RAM backend: single server, arbiter semantics
	wram: process
		variable m0, m1 : mem_t := (others => (others => '0'));
		variable rd0h, wr0h, rd1h, wr1h : boolean := false;
		variable a  : natural;
		variable d  : std_logic_vector(15 downto 0);
		variable wr_op : boolean;
		variable bank : natural;
		variable grant : boolean;
	begin
		loop
			wait until rising_edge(CLK);
			exit when stop;
			if WR0_RD = '0' then rd0h := false; end if;
			if WR0_WR = '0' then wr0h := false; end if;
			if WR1_RD = '0' then rd1h := false; end if;
			if WR1_WR = '0' then wr1h := false; end if;

			grant := false;
			if (WR0_RD = '1' and not rd0h) or (WR0_WR = '1' and not wr0h) then
				bank := 0;
				a := to_integer(unsigned(WR0_A));   -- latched at grant, like the arbiter
				d := WR0_DO;
				wr_op := (WR0_RD = '0');
				WR0_RDY <= '0';
				grant := true;
			elsif (WR1_RD = '1' and not rd1h) or (WR1_WR = '1' and not wr1h) then
				bank := 1;
				a := to_integer(unsigned(WR1_A));
				d := WR1_DO;
				wr_op := (WR1_RD = '0');
				WR1_RDY <= '0';
				grant := true;
			end if;

			if grant then
				for i in 1 to LATENCY loop
					wait until rising_edge(CLK);
				end loop;
				if bank = 0 then
					if wr_op then m0(a) := d; wr0h := true;
					else WR0_DI <= m0(a); rd0h := true; d := m0(a); end if;
					WR0_RDY <= '1';
				else
					if wr_op then m1(a) := d; wr1h := true;
					else WR1_DI <= m1(a); rd1h := true; d := m1(a); end if;
					WR1_RDY <= '1';
				end if;
				if wr_op then
					report "ACC b" & natural'image(bank) & " W a=" & natural'image(a)
						& " d=" & integer'image(to_integer(unsigned(d)));
				else
					report "ACC b" & natural'image(bank) & " R a=" & natural'image(a)
						& " d=" & integer'image(to_integer(unsigned(d)));
				end if;
			end if;
		end loop;
		wait;
	end process;

	-- internal state probe
	probe: process
		alias p_ret0 is << signal .tb_asic.dut.RET0 : std_logic >>;
		alias p_ret1 is << signal .tb_asic.dut.RET1 : std_logic >>;
		alias p_mode is << signal .tb_asic.dut.MODE : std_logic >>;
		alias p_dmna0 is << signal .tb_asic.dut.DMNA0 : std_logic >>;
		alias p_wr0a is << signal .tb_asic.dut.WR0A : work.ASIC_PKG.WordRamAccess_t >>;
		alias p_wr1a is << signal .tb_asic.dut.WR1A : work.ASIC_PKG.WordRamAccess_t >>;
		alias p_wr0s is << signal .tb_asic.dut.WR0S : work.ASIC_PKG.WordRamState_t >>;
		alias p_wr1s is << signal .tb_asic.dut.WR1S : work.ASIC_PKG.WordRamState_t >>;
	begin
		wait on p_ret0, p_ret1, p_mode, p_dmna0, p_wr0a, p_wr1a;
		report "PROBE ret0=" & std_logic'image(p_ret0)
			& " ret1=" & std_logic'image(p_ret1)
			& " mode=" & std_logic'image(p_mode)
			& " dmna0=" & std_logic'image(p_dmna0)
			& " wr0a=" & work.ASIC_PKG.WordRamAccess_t'image(p_wr0a)
			& " wr1a=" & work.ASIC_PKG.WordRamAccess_t'image(p_wr1a)
			& " wr0s=" & work.ASIC_PKG.WordRamState_t'image(p_wr0s)
			& " wr1s=" & work.ASIC_PKG.WordRamState_t'image(p_wr1s);
	end process;

	-- one-shot deep dump during the scenario-4 hang window
	dump: process
		alias d_sel is << signal .tb_asic.dut.S68K_WORD_RAM_SEL : std_logic >>;
		alias d_dtack is << signal .tb_asic.dut.S68K_WORDRAM_DTACK_N : std_logic >>;
		alias d_mdtack is << signal .tb_asic.dut.M68K_WORDRAM_DTACK_N : std_logic >>;
		alias d_regdtack is << signal .tb_asic.dut.S68K_REG_DTACK_N : std_logic >>;
	begin
		wait for 320000 ns;
		report "DUMP sel=" & std_logic'image(d_sel)
			& " s_wr_dtack=" & std_logic'image(d_dtack)
			& " m_wr_dtack=" & std_logic'image(d_mdtack)
			& " s_reg_dtack=" & std_logic'image(d_regdtack)
			& " s68k_a=" & integer'image(to_integer(unsigned(S68K_A)))
			& " as_n=" & std_logic'image(S68K_AS_N);
		wait;
	end process;

	-- single owner of the S68K bus: serves one-shot commands from stim and
	-- the concurrent 1M write burst when sub_go rises
	sub_drv: process
		procedure bus_cycle(addr : natural; wr_op : boolean;
		                    wdata : std_logic_vector(15 downto 0)) is
			variable t : natural := 0;
		begin
			S68K_A <= std_logic_vector(to_unsigned(addr, 23));
			if wr_op then S68K_RNW <= '0'; S68K_DI <= wdata;
			else S68K_RNW <= '1'; end if;
			S68K_AS_N <= '0';
			S68K_UDS_N <= '0'; S68K_LDS_N <= '0';
			while S68K_DTACK_N /= '0' loop
				wait until rising_edge(CLK); t := t + 1;
				assert t < 5000
					report "S68K DTACK timeout at addr " & natural'image(addr)
					severity failure;
			end loop;
			sc_rdata <= S68K_DO;
			wait until rising_edge(CLK);
			S68K_AS_N <= '1'; S68K_UDS_N <= '1'; S68K_LDS_N <= '1'; S68K_RNW <= '1';
			wait until rising_edge(CLK);
			wait until rising_edge(CLK);
		end procedure;
	begin
		loop
			wait until rising_edge(CLK);
			if sc_req and not sc_ack then
				bus_cycle(sc_addr, sc_wr, sc_data);
				sc_ack <= true;
			elsif not sc_req and sc_ack then
				sc_ack <= false;
			elsif sub_go and not sub_done then
				for i in 0 to 63 loop
					bus_cycle(16#C0000# + i, true, pat(2000 + i));
				end loop;
				sub_done <= true;
			end if;
		end loop;
	end process;

	stim: process
		variable rdata : std_logic_vector(15 downto 0);
		variable dummy : std_logic_vector(15 downto 0);

		procedure tick(n : natural := 1) is
		begin
			for i in 1 to n loop wait until rising_edge(CLK); end loop;
		end procedure;

		procedure ext_release is
		begin
			EXT_AS_N <= '1'; EXT_ASEL_N <= '1'; EXT_RAS2_N <= '1';
			EXT_FDC_N <= '1';
			EXT_UDS_N <= '1'; EXT_LDS_N <= '1'; EXT_RNW <= '1';
			tick(GAP);
		end procedure;

		procedure ext_cycle(
			addr    : in natural;
			wr_op   : in boolean;
			wdata   : in std_logic_vector(15 downto 0);
			ras2    : in boolean;
			rdata   : out std_logic_vector(15 downto 0)) is
			variable t : natural := 0;
		begin
			EXT_VA <= std_logic_vector(to_unsigned(addr, 17));
			if wr_op then EXT_RNW <= '0'; EXT_VDI <= wdata;
			else EXT_RNW <= '1'; end if;
			if ras2 then EXT_RAS2_N <= '0'; else EXT_FDC_N <= '0'; end if;
			EXT_ASEL_N <= '0';
			EXT_AS_N <= '0';
			EXT_UDS_N <= '0'; EXT_LDS_N <= '0';
			if ARMED then
				-- patched MBUS: DTACK must be seen released after cycle start
				while EXT_DTACK_N /= '1' loop
					tick; t := t + 1;
					assert t < 5000 report "EXT DTACK arm timeout" severity failure;
				end loop;
			end if;
			while EXT_DTACK_N /= '0' loop
				tick; t := t + 1;
				assert t < 5000 report "EXT DTACK timeout" severity failure;
			end loop;
			rdata := EXT_VDO;
			tick;
			ext_release;
		end procedure;

		procedure s68k_cycle(
			addr  : in natural;
			wr_op : in boolean;
			wdata : in std_logic_vector(15 downto 0)) is
		begin
			sc_addr <= addr;
			sc_wr   <= wr_op;
			sc_data <= wdata;
			sc_req  <= true;
			wait until sc_ack;
			sc_req <= false;
			wait until not sc_ack;
			tick;
		end procedure;

		procedure check(idx : natural; got, exp : std_logic_vector(15 downto 0)) is
		begin
			if got /= exp then
				err_cnt <= err_cnt + 1;
				report "MISMATCH idx=" & natural'image(idx)
					& " exp=" & integer'image(to_integer(unsigned(exp)))
					& " got=" & integer'image(to_integer(unsigned(got)))
					severity error;
			end if;
		end procedure;

		constant N : natural := 128;
	begin
		tick(10);
		RST_N <= '1';
		tick(20);

		---------------------------------------------------------------
		report "scenario 1: 2M write/readback via EXT (back-to-back)";
		for i in 0 to N-1 loop
			ext_cycle(i, true, pat(i), true, dummy);
		end loop;
		for i in 0 to N-1 loop
			ext_cycle(i, false, x"0000", true, rdata);
			check(i, rdata, pat(i));
		end loop;

		---------------------------------------------------------------
		report "scenario 2: handoff churn during EXT traffic";
		for k in 0 to 15 loop
			ext_cycle(1, true, x"0002", false, dummy);        -- DMNA=1: give to sub
			s68k_cycle(16#FF8002# / 2, true, x"0001");        -- sub: RET=1, back to main
			for i in 0 to 15 loop
				ext_cycle(k*16 + i, true, pat(300 + k*16 + i), true, dummy);
			end loop;
		end loop;
		for i in 0 to 255 loop
			ext_cycle(i, false, x"0000", true, rdata);
			check(i + 10000, rdata, pat(300 + i));
		end loop;

		---------------------------------------------------------------
		report "scenario 3: 1M mode, concurrent main traffic + sub writes";
		s68k_cycle(16#FF8002# / 2, true, x"0004");            -- MODE=1M, RET=0
		tick(10);
		-- main writes its bank while the sub concurrently writes the other
		sub_go <= true;
		for i in 0 to 63 loop
			ext_cycle(i, true, pat(3000 + i), true, dummy);
		end loop;
		while not sub_done loop tick; end loop;
		-- verify main's bank through the main window
		for i in 0 to 63 loop
			ext_cycle(i, false, x"0000", true, rdata);
			check(20000 + i, rdata, pat(3000 + i));
		end loop;
		-- swap banks (sub writes RET=1 with MODE still 1M) and verify
		-- the sub-written bank through the main window
		s68k_cycle(16#FF8002# / 2, true, x"0005");            -- MODE=1M, RET=1
		tick(10);
		for i in 0 to 63 loop
			ext_cycle(i, false, x"0000", true, rdata);
			check(21000 + i, rdata, pat(2000 + i));
		end loop;

		---------------------------------------------------------------
		report "scenario 4: GFX stamp engine (differential dump)";
		-- GFX is granted only in 2M mode with word RAM handed to the sub
		s68k_cycle(16#FF8002# / 2, true, x"0000");            -- MODE=2M
		ext_cycle(1, true, x"0002", false, dummy);            -- DMNA=1: RET0=0, sub owns
		tick(10);
		for i in 0 to 255 loop
			s68k_cycle(16#40000# + i, true, pat(4000 + i));
		end loop;
		-- program the stamp engine and start it
		s68k_cycle(16#FF8058# / 2, true, x"0001");            -- size: RPT=1
		s68k_cycle(16#FF805A# / 2, true, x"0000");            -- stamp map base
		s68k_cycle(16#FF805C# / 2, true, x"0000");            -- V cell size
		s68k_cycle(16#FF805E# / 2, true, x"0200");            -- image buffer start
		s68k_cycle(16#FF8060# / 2, true, x"0000");            -- image offset
		s68k_cycle(16#FF8062# / 2, true, x"0010");            -- H dot = 16
		s68k_cycle(16#FF8064# / 2, true, x"0010");            -- V dot = 16
		s68k_cycle(16#FF8066# / 2, true, x"0000");            -- trace base; GRON=1
		-- poll GRON (bit 15 of $FF8058)
		for p in 0 to 20000 loop
			s68k_cycle(16#FF8058# / 2, false, x"0000");
			exit when sc_rdata(15) = '0';
			assert p < 20000 report "GFX GRON never cleared" severity failure;
		end loop;
		report "GFX done, dumping image region";
		for i in 0 to 255 loop
			s68k_cycle(16#40000# + 16#400# + i, false, x"0000");
			report "IMG " & natural'image(i) & " = "
				& integer'image(to_integer(unsigned(sc_rdata)));
		end loop;

		---------------------------------------------------------------
		if err_cnt = 0 then
			report "ALL SCENARIOS PASS (LATENCY=" & natural'image(LATENCY) & ")" severity note;
		else
			report "FAILED with " & natural'image(err_cnt) & " mismatches" severity error;
		end if;
		stop <= true;
		wait;
	end process;

end architecture;
