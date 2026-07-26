library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
library STD;
use IEEE.NUMERIC_STD.ALL;

entity CDC is
	port(
		CLK			: in std_logic;
		RESET_N		: in std_logic;
		ENABLE		: in std_logic;
		CLKEN_P 		: in std_logic;
		CLKEN_N 		: in std_logic;
		
		DI				: in std_logic_vector(7 downto 0);
		DO				: out std_logic_vector(7 downto 0);
		CS_N			: in std_logic;
		RS				: in std_logic;
		RD_N			: in std_logic;
		WR_N			: in std_logic;
		INT_N			: out std_logic;
		
		HDO			: out std_logic_vector(7 downto 0);
		HRD_N			: in std_logic;
		DTEN_N		: out std_logic;
		WAIT_N		: out std_logic;
		
		CD_DI			: in std_logic_vector(15 downto 0);
		CD_WR			: in std_logic;
		-- null decoder tick (GPGX cdc_decoder_update(0) with no data):
		-- raise DECI/!VALST, zero the HEAD registers, and advance WA/PT
		-- by one sector when WRRQ, without any data arriving. Defaulted
		-- so legacy instantiations compile unchanged.
		DEC_TICK		: in std_logic := '0';
		
		RAM_A_WR   	: out std_logic_vector(15 downto 1);
		RAM_A_RD   	: out std_logic_vector(15 downto 0);
		RAM_DI		: in std_logic_vector(7 downto 0);
		RAM_DO		: out std_logic_vector(15 downto 0);
		RAM_WE		: out std_logic;
		-- decode-path instrumentation for the hardware overlay:
		--   [31:28] {DECEN, WRRQ, DECI, DTEI}  (DECI/DTEI active low)
		--   [27:24] {DOUTEN, DTEN, DTBSY, 0} -- host-transfer enable/state
		--   [23:8]  HEAD0,HEAD1 = mm:ss BCD of the sector last latched
		--   [7:4]   DTTRG writes, wraps -- the sub ASKING for a transfer
		--   [3:0]   decoded-sector counter, wraps (spins at 75Hz)
		DBG_DEC		: out std_logic_vector(31 downto 0)
	);
end CDC;

architecture rtl of CDC is
	
	--IFSTAT bits
	constant STEN : integer := 0;
	constant DTEN : integer := 1;
	constant STBSY : integer := 2;
	constant DTBSY : integer := 3;
	constant DECI : integer := 5;
	constant DTEI : integer := 6;
	constant CMDI : integer := 7;
	
	--IFCTRL bits
	constant SOUTEN : integer := 0;
	constant DOUTEN : integer := 1;
	constant STWAI : integer := 2;
	constant DTWAI : integer := 3;
	constant CMDBK : integer := 4;
	constant DECIEN : integer := 5;
	constant DTEIEN : integer := 6;
	constant CMDIEN : integer := 7;
	
	--CTRL0 bits
	constant PRQ : integer := 0;
	constant QRQ : integer := 1;
	constant WRRQ : integer := 2;
	constant ERAMRQ : integer := 3;
	constant AUTORQ : integer := 4;
	constant EO1RQ : integer := 5;
	constant EDCRQ : integer := 6;
	constant DECEN : integer := 7;
	
	--CTRL1 bits
	constant SHDREN : integer := 0;
	constant MBCKRQ : integer := 1;
	constant FORMRQ : integer := 2;
	constant MODRQ : integer := 3;
	constant COWREN : integer := 4;
	constant OSCREN : integer := 5;
	constant SYDEN : integer := 6;
	constant SYIEN : integer := 7;
	
	--STAT0 bits
	constant UCEBLK : integer := 0;
	constant ERABLK : integer := 1;
	constant SBLK : integer := 2;
	constant WSHORT : integer := 3;
	constant LBLK : integer := 4;
	constant NOSYNC : integer := 5;
	constant ILSYNC : integer := 6;
	constant CRCOK : integer := 7;
	
	--STAT2 bits
	constant RFORM0 : integer := 0;
	constant RFORM1 : integer := 1;
	constant NOCOR : integer := 2;
	constant MODE : integer := 3;
	constant RMOD0 : integer := 4;
	constant RMOD1 : integer := 5;
	constant RMOD2 : integer := 6;
	constant RMOD3 : integer := 7;
	
	--STAT3 bits
	constant CBLK : integer := 5;
	constant WLONG : integer := 6;
	constant VALST : integer := 7;
	
	signal EN : std_logic;
	
	signal AR : std_logic_vector(3 downto 0);
	signal IFCTRL : std_logic_vector(7 downto 0);
	signal IFSTAT : std_logic_vector(7 downto 0) := x"FF";
	signal DBC : std_logic_vector(15 downto 0);
	signal DAC : std_logic_vector(15 downto 0);
	signal HEAD0 : std_logic_vector(7 downto 0);
	signal HEAD1 : std_logic_vector(7 downto 0);
	signal HEAD2 : std_logic_vector(7 downto 0);
	signal HEAD3 : std_logic_vector(7 downto 0);
	signal PT : std_logic_vector(15 downto 0);
	signal WA : std_logic_vector(15 downto 0);
	signal CTRL0 : std_logic_vector(7 downto 0);
	signal DBG_DEC_CNT : std_logic_vector(3 downto 0);   -- see DBGDEC below
	signal DBG_TRG_CNT : std_logic_vector(3 downto 0);   -- DTTRG writes
	signal CTRL1 : std_logic_vector(7 downto 0);
	signal STAT0 : std_logic_vector(7 downto 0) := x"00";
	constant STAT1 : std_logic_vector(7 downto 0) := x"00";
	signal STAT2 : std_logic_vector(7 downto 0) := x"00";
	signal STAT3 : std_logic_vector(7 downto 0) := x"80";
	
	signal OLD_WR_N : std_logic;
	signal OLD_RD_N : std_logic;
--	signal OLD_HRD_N : std_logic;
	signal WR_F : std_logic;
	signal RD_F : std_logic;
--	signal HRD_R : std_logic;
--	signal HRD_F : std_logic;
	signal REG_WR : std_logic;
	signal REG_RD : std_logic;
	
	type TransferState_t is (
		TS_IDLE,
		TS_WAIT,
		TS_RAM_READ,
		TS_FIFO,
		TS_SEND_WAIT,
		TS_SEND
	);
	signal TS : TransferState_t;
	signal TRANS_RUN : std_logic;
	signal FIFO_DATA0 : std_logic_vector(8 downto 0);
--	signal FIFO_DATA1 : std_logic_vector(8 downto 0);
--	signal FIFO_RD_POS : std_logic;
--	signal FIFO_WR_POS : std_logic;
	signal DT_EN : std_logic;
	
	signal CD_WR_OLD : std_logic;
	signal WORD_CNT : unsigned(10 downto 0);
	signal RAM_POS : unsigned(11 downto 0);
	signal DEC_POS : unsigned(11 downto 0);
	signal DEC_ADDR : std_logic_vector(15 downto 0);
	signal DEC_DAT : std_logic_vector(15 downto 0);
	signal DEC_WR : std_logic;
	signal DEC_WR_EN : std_logic;
	signal DEC_HEAD01 : std_logic_vector(15 downto 0);
	signal DEC_HEAD23 : std_logic_vector(15 downto 0);
	
--	signal DECI_WAIT_CNT : unsigned(15 downto 0);
--	signal DECI_SET : std_logic;
	signal OLD_WRRQ : std_logic;
	signal DEC_TICK_OLD : std_logic;
	signal SYNC_M : unsigned(2 downto 0);   -- sync-pattern match progress
	signal SYNC_DONE : std_logic;           -- framed since DECEN went high
	
begin

	EN <= ENABLE and (CLKEN_N or CLKEN_P);
	
	process( RESET_N, CLK )
	begin
		if RESET_N = '0' then
			OLD_WR_N <= '1';
			OLD_RD_N <= '1';
		elsif rising_edge(CLK) then
			if EN = '1' then
				OLD_WR_N <= WR_N;
				OLD_RD_N <= RD_N;
			end if;
		end if;
	end process;
	
	WR_F <= not WR_N and OLD_WR_N;
	RD_F <= not RD_N and OLD_RD_N;
	
	REG_WR <= not CS_N and WR_F and RS;
	REG_RD <= not CS_N and RD_F and RS;
	
	process( RESET_N, CLK )
	begin
		if RESET_N = '0' then
			AR <= (others => '0');
			IFCTRL <= (others => '0');
			CTRL0 <= (others => '0');
			CTRL1 <= (others => '0');
			STAT0(CRCOK) <= '0';
			STAT2(MODE) <= '0';
			STAT2(NOCOR) <= '0';
			DO <= (others => '0');
		elsif rising_edge(CLK) then
			if EN = '1' then
				if CS_N = '0' and WR_F = '1' then
					if RS = '0' then
						AR <= DI(3 downto 0);
					else
						case AR is
							when x"0" =>			--R0
							when x"1" =>			--R1 IFCTRL
								IFCTRL <= DI;	
							when x"A" =>			--R10 CTRL0
								CTRL0 <= DI;
								STAT0(CRCOK) <= DI(DECEN);
								if DI(AUTORQ) = '1' then
									STAT2(MODE) <= CTRL1(MODRQ);
								else
									STAT2(MODE) <= CTRL1(MODRQ);
									STAT2(NOCOR) <= CTRL1(FORMRQ);
								end if;
							when x"B" =>			--R11 CTRL1
								CTRL1 <= DI;
								if CTRL0(AUTORQ) = '1' then
									STAT2(MODE) <= DI(MODRQ);
								else
									STAT2(MODE) <= DI(MODRQ);
									STAT2(NOCOR) <= DI(FORMRQ);
								end if;
							when x"F" =>			--R15 RESET
								IFCTRL <= (others => '0');
								CTRL0 <= (others => '0');
								CTRL1 <= (others => '0');
							when others => null;
						end case;
						if AR /= x"0" then
							AR <= std_logic_vector( unsigned(AR) + 1 );
						end if;
					end if;
				elsif CS_N = '0' and RD_F = '1' then
					if RS = '0' then
						DO <= x"0" & AR;
					else
						case AR is
							when x"0" =>			--R0
								
							when x"1" =>			--R1 IFSTAT
								DO <= IFSTAT;	
							when x"2" =>			--R2 DBCL
								DO <= DBC(7 downto 0);
							when x"3" =>			--R3 DBCH
								DO <= DBC(15 downto 8);
							when x"4" =>			--R4 HEAD0
								DO <= HEAD0;
							when x"5" =>			--R5 HEAD1
								DO <= HEAD1;
							when x"6" =>			--R6 HEAD2
								DO <= HEAD2;
							when x"7" =>			--R6 HEAD3
								DO <= HEAD3;
							when x"8" =>			--R8 PTL
								DO <= PT(7 downto 0);
							when x"9" =>			--R9 PTH
								DO <= PT(15 downto 8);
							when x"A" =>			--R10 WAL
								DO <= WA(7 downto 0);
							when x"B" =>			--R11 WAH
								DO <= WA(15 downto 8);
							when x"C" =>			--R12 STAT0
								DO <= STAT0;
							when x"D" =>			--R13 STAT1
								DO <= STAT1;
							when x"E" =>			--R14 STAT2
								DO <= STAT2;
							when x"F" =>			--R15 STAT3
								DO <= STAT3;
							when others => null;
						end case;
					end if;
					if AR /= x"0" then
						AR <= std_logic_vector( unsigned(AR) + 1 );
					end if;
				end if;
			end if;
		end if;
	end process;
	
	
	process( RESET_N, CLK )
	variable CD_BYTE : std_logic_vector(7 downto 0);
	begin
		if RESET_N = '0' then
			PT <= (others => '0');
			WA <= (others => '0');
			IFSTAT(DECI) <= '1';
			STAT3(VALST) <= '1';
			HEAD0 <= (others => '0');
			HEAD1 <= (others => '0');
			HEAD2 <= (others => '0');
			HEAD3 <= x"01";
			
			CD_WR_OLD <= '0';
			WORD_CNT <= (others => '0');
			RAM_POS <= (others => '0');
			DEC_POS <= (others => '0');
			SYNC_M <= (others => '0');
			DEC_TICK_OLD <= '0';
			SYNC_DONE <= '0';
			DEC_DAT <= (others => '0');
			DEC_WR <= '0';
			DEC_WR_EN <= '0';
			DEC_HEAD01 <= (others => '0');
			DEC_HEAD23 <= (others => '0');
			
--			DECI_SET <= '0';
--			DECI_WAIT_CNT <= (others => '0');
		elsif rising_edge(CLK) then
			DEC_WR <= '0';
			if EN = '1' then
				if REG_WR = '1' then
					case AR is
						when x"8" =>			--R8 WAL
							WA(7 downto 0) <= DI;
						when x"9" =>			--R9 WAH
							WA(15 downto 8) <= DI;
						when x"C" =>			--R12 PTL
							PT(7 downto 0) <= DI;
						when x"D" =>			--R13 PTH
							PT(15 downto 8) <= DI;
						when x"F" =>			--R15 RESET
							IFSTAT(DECI) <= '1';
							STAT3(VALST) <= '1';
						when others => null;
					end case;
				elsif REG_RD = '1' then
					case AR is
						when x"F" =>			--R15 STAT3
							IFSTAT(DECI) <= '1';
							STAT3(VALST) <= '1';
						when others => null;
					end case;
				end if;
				
				DEC_WR_EN <= CTRL0(WRRQ);
			
				if CTRL0(DECEN) = '1' then
					CD_WR_OLD <= CD_WR;
					if CD_WR = '1' and CD_WR_OLD = '0' then
						DEC_DAT <= CD_DI;
						DEC_POS <= RAM_POS;
					
						WORD_CNT <= WORD_CNT + 1;
						if WORD_CNT = 0 then
--							DEC_WR_EN <= CTRL0(WRRQ);
						elsif WORD_CNT = 12/2 then
							DEC_HEAD01 <= CD_DI;
							if CTRL0(WRRQ) = '0' then
								HEAD0 <= CD_DI(7 downto 0);
								HEAD1 <= CD_DI(15 downto 8);
							end if;
							DEC_WR <= '1';
							RAM_POS <= RAM_POS + 2;
						elsif WORD_CNT = 14/2 then
							DEC_HEAD23 <= CD_DI;
							if CTRL0(WRRQ) = '0' then
								HEAD2 <= CD_DI(7 downto 0);
								HEAD3 <= CD_DI(15 downto 8);
							end if;
							DEC_WR <= '1';
							RAM_POS <= RAM_POS + 2;
						elsif WORD_CNT >= 16/2 and WORD_CNT <= (16+2048)/2-1 then
							DEC_WR <= '1';
							RAM_POS <= RAM_POS + 2;
						elsif WORD_CNT = 2352/2-1 then
--							DECI_SET <= '1';
							IFSTAT(DECI) <= '0';
							STAT3(VALST) <= '0';
						end if;
						
						if WORD_CNT = 2352/2-1 then
							WORD_CNT <= (others => '0');
							RAM_POS <= (others => '0');
--							DEC_WR_EN <= CTRL0(WRRQ);
						end if;

						-- SECTOR FRAMING BY SYNC PATTERN.
						--
						-- WORD_CNT alone does not frame sectors: it is zeroed
						-- whenever DECEN is deasserted (the else branch far
						-- below), and zero is only the RIGHT phase if the next
						-- word to arrive is word 0 of a sector. That holds only
						-- when the disc is not streaming. A decoder armed while
						-- sectors are flowing lands mid-sector and every count
						-- after it is off by the same amount: HEAD0..3 latch
						-- from whatever bytes sit at word 6/7, payload lands at
						-- the wrong buffer offset, and DECI fires off boundary.
						-- Measured on hardware as HEAD reading 84:84 / 81:81:81
						-- while the drive was provably delivering well-formed
						-- sectors (sync verified at the source, zero bad),
						-- leaving a host that searches the stream for a target
						-- sector header unable to ever match.
						--
						-- Which also explains how a desynced host RECOVERS, and
						-- why it always looked like the pause was involved: its
						-- retry path is give-up -> PAUSE -> reconfigure the CDC
						-- -> resume, and that works only because the drive is
						-- stopped, so the re-arm lands on a real boundary. The
						-- multi-second freeze IS the recovery, not the fault.
						--
						-- The real LC8951 frames on the 12-byte sync
						-- 00 FF*10 00 -- what CTRL1's SYDEN enables, and why
						-- that pattern is reserved and cannot occur in
						-- sector data. Matching it restarts the word counter,
						-- which is self-correcting: framing recovers on the
						-- next sector however the decoder was started.
						-- Unconditional rather than gated on SYDEN, because
						-- never resyncing is the bug and the pattern is
						-- unambiguous. CD_WR carries only data sectors
						-- (MCD.vhd:363; CDDA has its own strobe), so audio
						-- cannot trigger it.
						-- Re-frame only ONCE per arming (SYNC_DONE), which is all the
						-- fault needs: the counter wraps at exactly one sector, so once
						-- the first sync lands it stays right. Accepting a match at any
						-- position forever would be unsafe here -- the reserved sync
						-- cannot occur in ENCODED cd data, but this drive pushes raw
						-- file bytes straight through, so a payload containing
						-- 00 FF*10 00 would re-frame mid-sector and break framing that
						-- was correct. One shot per arming cannot do that.
						if CD_DI = x"FF00" then
							SYNC_M <= "001";
						elsif SYNC_M >= "001" and SYNC_M <= "100" and CD_DI = x"FFFF" then
							SYNC_M <= SYNC_M + 1;
						elsif SYNC_M = "101" and CD_DI = x"00FF" then
							SYNC_M <= "000";
							if SYNC_DONE = '0' then
								SYNC_DONE <= '1';
								WORD_CNT <= to_unsigned(12/2, WORD_CNT'length);
								RAM_POS <= (others => '0');
							end if;
						else
							SYNC_M <= "000";
						end if;
--						if CTRL0(WRRQ) = '0' then
--							DEC_WR_EN <= '0';
--						end if;

						if DEC_WR_EN = '1' then
----							WA <= std_logic_vector( unsigned(WA) + 2 );
							if WORD_CNT = 2352/2-1 then
								WA <= std_logic_vector( unsigned(WA) + 2352 );
								PT <= std_logic_vector( unsigned(PT) + 2352 );
								HEAD0 <= DEC_HEAD01(7 downto 0);
								HEAD1 <= DEC_HEAD01(15 downto 8);
								HEAD2 <= DEC_HEAD23(7 downto 0);
								HEAD3 <= DEC_HEAD23(15 downto 8);
							end if;
						end if;
					end if;
				else
					WORD_CNT <= (others => '0');
					RAM_POS <= (others => '0');
					SYNC_DONE <= '0';   -- re-arm: next sync re-frames
				end if;
				
				-- null decoder tick: GPGX cdc_decoder_update(header=0) with no
				-- data. HEAD registers take the (zero) header, !VALST and DECI
				-- assert, and with WRRQ latched the block pointer and write
				-- address advance one sector with nothing written -- exactly
				-- upstream's WRRQ branch when cdd_read_data has no data to give
				-- (audio track, negative lba). The drive pulses this on every
				-- 75Hz tick where it does not stream a sector down CD_DI.
				DEC_TICK_OLD <= DEC_TICK;
				if DEC_TICK = '1' and DEC_TICK_OLD = '0' and CTRL0(DECEN) = '1' then
					HEAD0 <= x"00";
					HEAD1 <= x"00";
					HEAD2 <= x"00";
					HEAD3 <= x"00";
					STAT3(VALST) <= '0';
					IFSTAT(DECI) <= '0';
					if DEC_WR_EN = '1' then
						WA <= std_logic_vector( unsigned(WA) + 2352 );
						PT <= std_logic_vector( unsigned(PT) + 2352 );
					end if;
				end if;
			end if;
		end if;
	end process;
	
	DEC_ADDR <= std_logic_vector( unsigned(PT) + 2352 + DEC_POS );
	RAM_A_WR <= DEC_ADDR(15 downto 1);
	RAM_DO <= DEC_DAT;
	RAM_WE <= DEC_WR and DEC_WR_EN and CTRL0(DECEN);

	process( RESET_N, CLK )
	begin
		if RESET_N = '0' then
--			OLD_HRD_N <= '1';
			DT_EN <= '0';
		elsif rising_edge(CLK) then
			if EN = '1' then
				DT_EN <= not DT_EN;
				if DT_EN = '1' then
--					OLD_HRD_N <= HRD_N;
				end if;
			end if;
		end if;
	end process;
	
--	HRD_R <= HRD_N and not OLD_HRD_N;
--	HRD_F <= not HRD_N and OLD_HRD_N;
	
	process( RESET_N, CLK )
	begin
		if RESET_N = '0' then
			DBC <= (others => '0');
			DAC <= (others => '0');
			TS <= TS_IDLE;
			IFSTAT(DTEN) <= '1';
			IFSTAT(DTEI) <= '1';
			IFSTAT(DTBSY) <= '1';
			DTEN_N <= '1';
			WAIT_N <= '0';
			FIFO_DATA0 <= (others => '0');
--			FIFO_DATA1 <= (others => '0');
--			FIFO_WR_POS <= '0';
--			FIFO_RD_POS <= '0';
			
		elsif rising_edge(CLK) then
			if EN = '1' then
				if REG_WR = '1' then
					case AR is
						when x"2" =>			--R2 DBCL
							DBC(7 downto 0) <= DI;
						when x"3" =>			--R3 DBCH
							DBC(15 downto 8) <= DI;
						when x"4" =>			--R4 DACL
							DAC(7 downto 0) <= DI;
						when x"5" =>			--R5 DACH
							DAC(15 downto 8) <= DI;
						when x"6" =>			--R6 DTTRG
--							IFSTAT(DTBSY) <= '0';
--							IFSTAT(DTEI) <= '1';
--							DBC(15 downto 12) <= "0000";
						when x"7" =>			--R6 DTACK
							IFSTAT(DTEI) <= '1';
							DBC(15 downto 12) <= "0000";
						when x"F" =>			--R15 RESET
--							IFSTAT(DTEN) <= '1';
--							IFSTAT(DTEI) <= '1';
--							IFSTAT(DTBSY) <= '1';
						when others => null;
					end case;
				end if;
				
				
				if (REG_WR = '1' and AR = x"F") or (REG_WR = '1' and AR = x"1" and DI(DOUTEN) = '0') then
					IFSTAT(DTBSY) <= '1';
					IFSTAT(DTEN) <= '1';
					IFSTAT(DTEI) <= '1';
					DTEN_N <= '1';
					
--					FIFO_RD_POS <= '0';
					FIFO_DATA0(8) <= '0';
--					FIFO_DATA1(8) <= '0';
					TS <= TS_IDLE;
				elsif REG_WR = '1' and AR = x"6" then
					if IFCTRL(DOUTEN) = '1' then
						IFSTAT(DTBSY) <= '0';
--						IFSTAT(DTEN) <= '0';
						DBC(15 downto 12) <= "0000";
						
--						FIFO_RD_POS <= '0';
						FIFO_DATA0(8) <= '0';
--						FIFO_DATA1(8) <= '0';
					end if;
--				elsif REG_WR = '1' and AR = x"7" then
--					IFSTAT(DTEI) <= '1';
--					DBC(15 downto 12) <= "0000";
				elsif IFCTRL(DOUTEN) = '1' and DT_EN = '1' then--
					case TS is
						when TS_IDLE =>
							if IFSTAT(DTBSY) = '0' then
								WAIT_N <= '1';
								TS <= TS_WAIT;
							end if;
							
						when TS_WAIT =>
--							if FIFO_DATA0(8) = '0' then
--								FIFO_WR_POS <= '0';
								TS <= TS_FIFO;--TS_RAM_READ;
--							elsif FIFO_DATA1(8) = '0' then
--								FIFO_WR_POS <= '1';
--								TS <= TS_RAM_READ;
--							elsif DBC(11 downto 0) = x"000" then--IFSTAT(DTEN) = '1'
--								TS <= TS_IDLE;
--							end if;
							
						when TS_RAM_READ =>
							TS <= TS_FIFO;
						
						when TS_FIFO =>
--							if FIFO_WR_POS = '0' then
								FIFO_DATA0 <= "1" & RAM_DI;
								if IFSTAT(DTEN) = '1' then
									IFSTAT(DTEN) <= '0';
									DTEN_N <= '0';
								end if;
--							else
--								FIFO_DATA1 <= "1" & RAM_DI;
--							end if;
							DAC <= std_logic_vector( unsigned(DAC) + 1 );
							TS <= TS_SEND_WAIT;
							
						when TS_SEND_WAIT =>
							if HRD_N = '0' then
								WAIT_N <= '0';
								TS <= TS_SEND;
							end if;
						
						when TS_SEND =>
							if HRD_N = '1' then
								WAIT_N <= '1';
								
								DBC(11 downto 0) <= std_logic_vector( unsigned(DBC(11 downto 0)) - 1 );
--								FIFO_RD_POS <= not FIFO_RD_POS;
--								if FIFO_RD_POS = '0' then
--									FIFO_DATA0(8) <= '0';
--								else
--									FIFO_DATA1(8) <= '0';
--								end if;
						
								if DBC(11 downto 0) = x"000" then
									IFSTAT(DTEN) <= '1';
									IFSTAT(DTBSY) <= '1';
									IFSTAT(DTEI) <= '0';
									DTEN_N <= '1';
									DBC(15 downto 12) <= "1111";
									TS <= TS_IDLE;
								else
									TS <= TS_WAIT;
								end if;
							end if;
							
						when others => null;
					end case;
				
--					if HRD_F = '1' then
--						WAIT_N <= '0';
--					elsif HRD_R = '1' then
--						DBC(11 downto 0) <= std_logic_vector( unsigned(DBC(11 downto 0)) - 1 );
--						FIFO_RD_POS <= not FIFO_RD_POS;
--						if FIFO_RD_POS = '0' then
--							FIFO_DATA0(8) <= '0';
--						else
--							FIFO_DATA1(8) <= '0';
--						end if;
--						if DBC(11 downto 0) = x"000" then
--							IFSTAT(DTEN) <= '1';
--							IFSTAT(DTBSY) <= '1';
--							IFSTAT(DTEI) <= '0';
--							DTEN_N <= '1';
----							FIFO_RD_POS <= '0';
----							FIFO_DATA0(8) <= '0';
----							FIFO_DATA1(8) <= '0';
--							DBC(15 downto 12) <= "1111";
--							TS <= TS_IDLE;
--						end if;
--						WAIT_N <= '1';
--					end if;
				end if;
			end if;
		end if;
	end process;
	
	HDO <= FIFO_DATA0(7 downto 0);-- when FIFO_RD_POS = '0' else FIFO_DATA1(7 downto 0);
	
	RAM_A_RD <= DAC;
	
	
	INT_N <= (IFSTAT(DTEI) or not IFCTRL(DTEIEN)) and (IFSTAT(DECI) or not IFCTRL(DECIEN));

	-------------------------------------------------------------------
	-- decode-path instrumentation (overlay row 5)
	-------------------------------------------------------------------
	-- Sits between the drive (which we know delivers correctly) and the sub
	-- (which we know keeps executing). Answers two things a stalled sub
	-- cannot: is the decoder even ENABLED and retiring sectors, and does the
	-- sector it latched agree with where the drive says its head is.
	-- HEAD0..2 are the raw mm:ss:ff BCD from the sector stream, so they can
	-- be compared straight against head+150 from row 8.
	DBGDEC : process( RESET_N, CLK )
	begin
		if RESET_N = '0' then
			DBG_DEC_CNT <= (others => '0');
			DBG_TRG_CNT <= (others => '0');
		elsif rising_edge(CLK) then
			if EN = '1' and CTRL0(DECEN) = '1' and CD_WR = '1' and CD_WR_OLD = '0'
			   and WORD_CNT = 2352/2-1 then
				DBG_DEC_CNT <= std_logic_vector(unsigned(DBG_DEC_CNT) + 1);
			end if;
			-- every write to R6 (DTTRG) = the sub ASKING for a host transfer
			if EN = '1' and REG_WR = '1' and AR = x"6" then
				DBG_TRG_CNT <= std_logic_vector(unsigned(DBG_TRG_CNT) + 1);
			end if;
		end if;
	end process;

	DBG_DEC <= CTRL0(DECEN) & CTRL0(WRRQ) & IFSTAT(DECI) & IFSTAT(DTEI) &
	           IFCTRL(DOUTEN) & IFSTAT(DTEN) & IFSTAT(DTBSY) & '0' &
	           HEAD0 & HEAD1 & DBG_TRG_CNT & DBG_DEC_CNT;

end rtl;
	