
//////////////////////////////////////////
//Author - Rejoy Mathews
//VHDL Code copyrights - Copyright (c) 2014 Matthew Hagerty 
//SDRAM Memory Controller
//Initial Implementation - 25 Feb 2019
//Final Modifications - 16 Mar 2019
//System Verilog Implementation
//Burst Mode disabled
//////////////////////////////////////////

module SDRAM_controller_verilog(

// CPU side
input logic clk_200MHz_i,   // Master Clock on DE-10Lite FPGA board
input logic reset_i,		 // Reset, active high
input logic refresh_i,	 // Initiate a refresh cycle, active high
input logic rw_i,			 // Initiate a read or write operation, active high
input logic we_i,			 // Write enable, active low
input logic [24:0] addr_i, // Address from host to SDRAM
input logic [15:0] data_i, // Data from host to SDRAM
input logic ub_i,			 // Data upper byte enable, active low
input logic lb_i,			 // Data lower byte enable, active low
output logic ready_o,		 // Set to '1' when the memory is ready
output logic done_o,		 // Read, write, or refresh, operation is done
output logic [15:0] data_o,		 // Data from SDRAM to host

// SDRAM side
output logic sdCke_o,		 // Clock-enable to SDRAM
output logic sdCe_bo, 	 // Chip-select to SDRAM, Active Low
output logic sdRas_bo,	 // SDRAM row address strobe, Active Low
output logic sdCas_bo,	 // SDRAM column address strobe, Active Low
output logic sdWe_bo,		 // SDRAM write enable, Active Low
output logic [1:0] sdBs_o, // SDRAM bank address
output logic [12:0] sdAddr_o, // SDRAM row/column address
inout logic [15:0] sdData_io, // Data to/from SDRAM
output logic sdDqmu_o,		 // Enable upper-byte of SDRAM databus if true
output logic sdDqml_o		 // Enable lower-byte of SDRAM databus if true
);


//Defining SDRAM controller states
typedef enum {ST_INIT_WAIT, ST_INIT_PRECHARGE, ST_INIT_REFRESH1, ST_INIT_MODE, ST_INIT_REFRESH2, ST_IDLE, ST_REFRESH, ST_ACTIVATE, ST_RCD, ST_RW, ST_RAS1, ST_RAS2, ST_PRECHARGE,ST_STALL} fsm_state_type;

fsm_state_type state_r = ST_INIT_WAIT;
fsm_state_type state_x = ST_INIT_WAIT;

//SDRAM mode register data sent on the address bus.
// A12-A10 |       A9   	  |           A8  A7 	    	| A6 A5 A4 |               A3					| A2 A1 A0 |
// reserved| wr burst mode    |Reserved - Standard Operation| CAS Ltncy| Burst type - sequential/interleaved| burst len|
// 	000	   |1 - Single Accs   |              00				|	010	   |				0					|	000	   |

parameter [12:0] MODE_REG = 13'b000001000100000;

//SDRAM commands combining inputs cs, ras,cas, we.
typedef logic [3:0] cmd_type;
parameter cmd_type CMD_ACTIVATE  = 4'b0011;   // Row activating before starting a read or write  
parameter cmd_type CMD_PRECHARGE = 4'b0010;	  // Precharge all banks (Also, need to control A10 for the same)
parameter cmd_type CMD_WRITE     = 4'b0100;	  // Begin Write
parameter cmd_type CMD_READ      = 4'b0101;	  // Begin Read
parameter cmd_type CMD_MODE      = 4'b0000;	  // Mode register set
parameter cmd_type CMD_NOP       = 4'b0111;	  // Nop or Power Down
parameter cmd_type CMD_REFRESH   = 4'b0001;   // Auto refresh or self-refresh 

cmd_type cmd_r, cmd_x;

logic [1:0] bank_s;
logic [12:0] row_s;
logic [9:0] col_s;
logic [12:0] addr_r;
logic [12:0] addr_x;
logic [15:0] sd_dout_r;
logic [15:0] sd_dout_x;
logic sd_busdir_r;
logic sd_busdir_x;

logic [11:0] timer_r = 0, timer_x = 0;
logic [3:0] refcnt_r = 0, refcnt_x = 0;

logic [1:0] bank_r, bank_x;
logic cke_r, cke_x;
logic sd_dqmu_r, sd_dqmu_x;
logic sd_dqml_r, sd_dqml_x;
logic ready_r, ready_x;

//Data buffer from SDRAM to host
logic [15:0] buf_dout_r, buf_dout_x;

// Assigning to Chip Select, RAS, CAS and Write Enable depending on the Command that needs to be implemented
assign {sdCe_bo, sdRas_bo, sdCas_bo, sdWe_bo} = cmd_r;
assign sdCke_o = cke_r;      // SDRAM clock enable
assign sdBs_o = bank_r;     // SDRAM bank address
assign sdAddr_o = addr_r;     // SDRAM address
assign sdData_io = sd_busdir_r ? sd_dout_r : 16'bZZZZZZZZZZZZZZZZ; // SDRAM data bus.
assign sdDqmu_o = sd_dqmu_r;  // SDRAM high data byte enable, active low
assign sdDqml_o = sd_dqml_r;  // SDRAM low date byte enable, active low

//Signals back to the host CPU
assign ready_o = ready_r;
assign data_o = buf_dout_r;

// 24  23  |22 21 20 19 18 17 16 15 14 13 12 11 10 | 09 08 07 06 05 04 03 02 01 00 |
// BS0 BS1 |        ROW (A12-A0)  8192 rows        |    COL (A9-A0)  1024 cols     |
assign bank_s = addr_i[24:23];
assign row_s = addr_i[22:10];
assign col_s = addr_i[9:0];

always @(state_r, timer_r, refcnt_r, cke_r, addr_r, sd_dout_r, sd_busdir_r, sd_dqmu_r, sd_dqml_r, ready_r,
   bank_s, row_s, col_s,
   rw_i, refresh_i, addr_i, data_i, we_i, ub_i, lb_i,
   buf_dout_r, sdData_io) begin
	  state_x     <= state_r;       // Stay in the same state unless changed.
      timer_x     <= timer_r;       // Hold the cycle timer by default.
      refcnt_x    <= refcnt_r;      // Hold the refresh timer by default.
      cke_x       <= cke_r;         // Stay in the same clock mode unless changed.
      cmd_x       <= CMD_NOP;       // Default to NOP unless changed.
      bank_x      <= bank_r;        // Register the SDRAM bank.
      addr_x      <= addr_r;        // Register the SDRAM address.
      sd_dout_x   <= sd_dout_r;     // Register the SDRAM write data.
      sd_busdir_x <= sd_busdir_r;   // Register the SDRAM bus tristate control.
      sd_dqmu_x   <= sd_dqmu_r;
      sd_dqml_x   <= sd_dqml_r;
      buf_dout_x  <= buf_dout_r;    // SDRAM to host data buffer.
 
      ready_x     <= ready_r;       // Always ready unless performing initialization.
      done_o      <= 1'b0;           // Done tick, single cycle.


      if(timer_r != 0) begin
      	timer_x <= timer_r - 1;
      end
      else begin
      	cke_x       <= 1'b1;
        bank_x      <= bank_s;
        addr_x      <= {3'b000,col_s};   // A10 low for rd/wr commands to suppress auto-precharge. (col_s is 8 bits wide)
        sd_dqmu_x   <= 1'b0;
        sd_dqml_x   <= 1'b0;

        case (state_r)
        	ST_INIT_WAIT:
        		begin
	            	// 1. Wait 200us with DQM signals high, cmd NOP.
	            	// 2. Precharge all banks.
	            	// 3. Eight refresh cycles.
	            	// 4. Set mode register.
	            	// 5. Eight refresh cycles.

	            	state_x <= ST_INIT_PRECHARGE;
//	        	    timer_x <= 40000;          // Wait 200us (40,000 cycles for a clock of 200MHz).
			        timer_x <= 2;              // for simulation
	           		sd_dqmu_x <= 1'b1;
	            	sd_dqml_x <= 1'b1;   			
        		end
            
            ST_INIT_PRECHARGE:
 			begin
	            state_x <= ST_INIT_REFRESH1;
	//            refcnt_x <= 8;             // Do 8 refresh cycles in the next state.
	            refcnt_x <= 2;             // for simulation
	            cmd_x <= CMD_PRECHARGE;
	            timer_x <= 3;              // Wait 3 cycles for Trp as per datasheet.
	            bank_x <= 2'b00;
	            addr_x[10] <= 1'b1;         // Precharge all banks.
	        end

	        ST_INIT_REFRESH1:
	 		begin
	            if (refcnt_r == 0) begin
	               state_x <= ST_INIT_MODE;
	            end
	            else begin
	               refcnt_x <= refcnt_r - 1;
	               cmd_x <= CMD_REFRESH;
	               timer_x <= 11;           // Wait 11 cycles plus state overhead for 55ns refresh. (As per datasheet)
	            end
	        end

        	ST_INIT_MODE:
        	begin
	            state_x <= ST_INIT_REFRESH2;
//	            refcnt_x <= 8;             // Do 8 refresh cycles in the next state.
	          refcnt_x <= 2;             // for simulation
	            bank_x <= 0;
	            addr_x <= MODE_REG;
	            cmd_x <= CMD_MODE;
	            timer_x <= 2;              // Tmrd == 2 cycles after issuing MODE command. (Mode register program time as per datasheet)
            end

	        ST_INIT_REFRESH2:
	 		begin
	            if (refcnt_r == 0) begin
	               state_x <= ST_IDLE;
	               ready_x <= 1'b1;
	            end
	            else begin
	               refcnt_x <= refcnt_r - 1;
	               cmd_x <= CMD_REFRESH;
	               timer_x <= 11;           // Wait 11 cycles plus state overhead for 55ns refresh. (As per datasheet)
	            end
	        end


    // Normal Operation
 
         // Trc  - 55ns - Attive to active command.
         // Trcd - 15ns - Active to read/write command.
         // Tras - min 38ns max 100K- Active to precharge command.
         // Trp  - 15ns - Precharge to active command.
         // TCas - 2clk - Read/write to data out.

         // A10 during rd/wr : 0 = disable auto-precharge, 1 = enable auto-precharge.
         // A10 during precharge: 0 = single bank, 1 = all banks.


         //         |<-------------             Trc            ---------------------->|
         //         |<-------------         Tras         ---------->|
         //         |<-    Trcd   --->|<- TCas  ->|                 |<-     Trp     ->|
         //  T0__  T1__  T2__  T3__  T4__  T5__  T6__  T7__  T8__  T9__ T10__ T11__ T12__
         // __|  |__|  |__|  |__|  |__|  |__|  |__|  |__|  |__|  |__|  |__|  |__|  |__|  
         // IDLE  ACTVT  NOP   NOP   RD/WR  NOP   NOP   NOP  NOP   PRECG  NOP  IDLE  ACTVT
         //     --<Row>-------------<Col>-------------<Bank>-------------------------<Row>--
         //    ---------------------<A10>-------------<A10>-------------------
         // ------------------------<Din>-------------<Dout>--------
         //    ---------------------<DQM>---------------
         //     --<Refsh>-------------

	        ST_IDLE:
	        begin
	            // 50ns since activate when coming from PRECHARGE state.
	            // 10ns since PRECHARGE.  Trp == 15ns min.
	            if (rw_i == 1) begin
	               state_x <= ST_ACTIVATE;
	               cmd_x <= CMD_ACTIVATE;
	               addr_x <= row_s;        // Set bank select and row on activate command.
	            end
	            else if (refresh_i == 1) begin
	               state_x <= ST_REFRESH;
	               cmd_x <= CMD_REFRESH;
	               timer_x <= 11;          // Wait 11 cycles plus state overhead for 55ns refresh. (As per datasheet)
	            end
	        end

            ST_REFRESH:
 			begin
            	state_x <= ST_IDLE;
            	done_o <= 1;
            end

            ST_ACTIVATE:
            begin
	            // Trc (Active to Active Command Period) is 55ns min.  
	            // 55ns since activate when coming from PRECHARGE -> IDLE states.
	            // 15ns since PRECHARGE.
	            // ACTIVATE command is presented to the SDRAM.  The command out of this
	            // state will be NOP for two cycles.
	            state_x <= ST_STALL;
	            sd_dout_x <= data_i;       // Register any write data, even if not used.
            end

            ST_STALL:       //State added only to meet timing requirements between Activate and R/W. Adding an additional state will stall the state machine for 5 for ns.
            begin
	            state_x <= ST_RCD;
            end
            
            ST_RCD:
            begin
                state_x <= ST_RW;
	            // 10ns since activate.
	            // Trcd == 15ns .  The clock is 5ns, so the requirement is satisfied by this state.
	            // READ or WRITE command will be active in the next cycle.
	            if (we_i == 0) begin
	               cmd_x <= CMD_WRITE;
	               sd_busdir_x <= 1;     // The SDRAM latches the input data with the command.
	               sd_dqmu_x <= ub_i;
	               sd_dqml_x <= lb_i;
	            end
	            else begin
	               cmd_x <= CMD_READ;
	            end
            end

         	ST_RW:
         	begin
            // 15ns since activate.
            // READ or WRITE command presented to SDRAM.
            	state_x <= ST_RAS1;
            	sd_busdir_x <= 0;
           	end

	 		ST_RAS1:
	 		begin
            // 20ns since activate.
 	           state_x <= ST_RAS2;
            // Tras (Active to precharge Command Period) is 40ns min.
            // So we will remain in this state for 2 more clocks by activating the timer so that we can acheive the required timing.
            timer_x <= 2;
            end

            ST_RAS2:
            begin
            // 35ns since activate.
            // PRECHARGE command will be active in the next cycle after timer has been exhausted.
	            state_x <= ST_PRECHARGE;
	            cmd_x <= CMD_PRECHARGE;
	            addr_x[10] <= 1;         // Precharge all banks.
	            buf_dout_x <= sdData_io;
	        end

        	ST_PRECHARGE:
        	begin
            // 50ns since activate.
            // PRECHARGE presented to SDRAM.
            	state_x <= ST_IDLE;
            	done_o <= 1;             // Read data is ready and should be latched by the host.
            	timer_x <= 1;              // Buffer to make sure host takes down memory request before going IDLE.
 			end
        endcase
    end
end

always @(posedge clk_200MHz_i) begin 
    if(reset_i == 1) begin
        state_r  <= ST_INIT_WAIT;
        timer_r  <= 0;
        cmd_r    <= CMD_NOP;
        cke_r    <= 0;
        ready_r  <= 0;
    end
    else begin
        state_r     <= state_x;
        timer_r     <= timer_x;
        refcnt_r    <= refcnt_x;
        cke_r       <= cke_x;         // CKE to SDRAM.
        cmd_r       <= cmd_x;         // Command to SDRAM.
        bank_r      <= bank_x;        // Bank to SDRAM.
        addr_r      <= addr_x;        // Address to SDRAM.
        sd_dout_r   <= sd_dout_x;     // Data to SDRAM.
        sd_busdir_r <= sd_busdir_x;   // SDRAM bus direction.
        sd_dqmu_r   <= sd_dqmu_x;     // Upper byte enable to SDRAM.
        sd_dqml_r   <= sd_dqml_x;     // Lower byte enable to SDRAM.
        ready_r     <= ready_x;
        buf_dout_r  <= buf_dout_x;   
    end
end
endmodule