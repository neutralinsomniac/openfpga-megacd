-- Behavioral RAM primitives for the M2 co-simulation, replacing the
-- altera_mf altsyncram-backed bram.vhd. Registered read (new-data on write
-- through port A, old-data semantics are not relied on by the MCD design).
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity spram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " ";
		mem_name      : string := "MEM"
	);
	port (
		clock   : in  std_logic;
		address : in  std_logic_vector(addr_width-1 downto 0);
		data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable  : in  std_logic := '1';
		wren    : in  std_logic := '0';
		q       : out std_logic_vector(data_width-1 downto 0);
		cs      : in  std_logic := '1'
	);
end spram;

architecture sim of spram is
	type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
	signal mem : mem_t := (others => (others => '0'));
	signal qr  : std_logic_vector(data_width-1 downto 0) := (others => '0');
begin
	process(clock) begin
		if rising_edge(clock) then
			if enable = '1' then
				if wren = '1' then mem(to_integer(unsigned(address))) <= data; end if;
				qr <= mem(to_integer(unsigned(address)));
			end if;
		end if;
	end process;
	q <= qr when cs = '1' else (others => '1');
end sim;

--------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity dpram is
	generic (
		addr_width    : integer := 8;
		data_width    : integer := 8;
		mem_init_file : string := " "
	);
	port (
		clock     : in  std_logic;
		address_a : in  std_logic_vector(addr_width-1 downto 0);
		data_a    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width-1 downto 0);
		cs_a      : in  std_logic := '1';
		address_b : in  std_logic_vector(addr_width-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end dpram;

architecture sim of dpram is
	type mem_t is array(0 to 2**addr_width-1) of std_logic_vector(data_width-1 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
	signal qa, qb : std_logic_vector(data_width-1 downto 0) := (others => '0');
begin
	process(clock) begin
		if rising_edge(clock) then
			if enable_a = '1' then
				if wren_a = '1' then mem(to_integer(unsigned(address_a))) := data_a; end if;
				qa <= mem(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;
	process(clock) begin
		if rising_edge(clock) then
			if enable_b = '1' then
				if wren_b = '1' then mem(to_integer(unsigned(address_b))) := data_b; end if;
				qb <= mem(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;
	q_a <= qa when cs_a = '1' else (others => '1');
	q_b <= qb when cs_b = '1' else (others => '1');
end sim;

--------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

-- Mixed-width dual port. Port A width data_width_a, port B width data_width_b.
-- The MCD uses these with a byte port and a word port; model both as a byte
-- array sized to the wider capacity and pack/unpack accordingly.
entity dpram_dif is
	generic (
		addr_width_a  : integer := 8;
		data_width_a  : integer := 8;
		addr_width_b  : integer := 8;
		data_width_b  : integer := 8;
		mem_init_file : string := " "
	);
	port (
		clock     : in  std_logic;
		address_a : in  std_logic_vector(addr_width_a-1 downto 0);
		data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		q_a       : out std_logic_vector(data_width_a-1 downto 0);
		cs_a      : in  std_logic := '1';
		address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
		data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
		enable_b  : in  std_logic := '1';
		wren_b    : in  std_logic := '0';
		q_b       : out std_logic_vector(data_width_b-1 downto 0);
		cs_b      : in  std_logic := '1'
	);
end dpram_dif;

architecture sim of dpram_dif is
	-- total bits identical from both views; model as a bit-addressable byte store
	constant TOTAL_BITS : integer := (2**addr_width_a) * data_width_a;
	constant RATIO      : integer := data_width_b / data_width_a; -- assume b is wider
	type mem_t is array(0 to 2**addr_width_a-1) of std_logic_vector(data_width_a-1 downto 0);
	shared variable mem : mem_t := (others => (others => '0'));
	signal qa : std_logic_vector(data_width_a-1 downto 0) := (others => '0');
	signal qb : std_logic_vector(data_width_b-1 downto 0) := (others => '0');
begin
	-- port A: narrow
	process(clock) begin
		if rising_edge(clock) then
			if enable_a = '1' then
				if wren_a = '1' then mem(to_integer(unsigned(address_a))) := data_a; end if;
				qa <= mem(to_integer(unsigned(address_a)));
			end if;
		end if;
	end process;
	-- port B: wide (RATIO consecutive narrow words, big-endian within the word)
	process(clock)
		variable base : integer;
		variable rd   : std_logic_vector(data_width_b-1 downto 0);
	begin
		if rising_edge(clock) then
			if enable_b = '1' then
				base := to_integer(unsigned(address_b)) * RATIO;
				if wren_b = '1' then
					for i in 0 to RATIO-1 loop
						mem(base + i) := data_b((RATIO-1-i)*data_width_a + data_width_a-1 downto (RATIO-1-i)*data_width_a);
					end loop;
				end if;
				for i in 0 to RATIO-1 loop
					rd((RATIO-1-i)*data_width_a + data_width_a-1 downto (RATIO-1-i)*data_width_a) := mem(base + i);
				end loop;
				qb <= rd;
			end if;
		end if;
	end process;
	q_a <= qa when cs_a = '1' else (others => '1');
	q_b <= qb when cs_b = '1' else (others => '1');
end sim;
