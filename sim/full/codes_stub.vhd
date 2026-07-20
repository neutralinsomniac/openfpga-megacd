-- Passthrough stub for the CODES (Game Genie) cheat engine: no cheats,
-- data flows through unmodified. Sufficient for the M2 CDD/CDC co-sim.
library IEEE;
use IEEE.STD_LOGIC_1164.all;

entity CODES is
	generic (
		ADDR_WIDTH : integer := 16;
		DATA_WIDTH : integer := 8;
		BIG_ENDIAN : integer := 0
	);
	port (
		clk       : in  std_logic;
		reset     : in  std_logic;
		enable    : in  std_logic;
		available : out std_logic;
		code      : in  std_logic_vector(128 downto 0);
		addr_in   : in  std_logic_vector(23 downto 0);
		data_in   : in  std_logic_vector(15 downto 0);
		data_out  : out std_logic_vector(15 downto 0)
	);
end CODES;

architecture sim of CODES is
begin
	available <= '0';
	data_out  <= data_in;
end sim;
