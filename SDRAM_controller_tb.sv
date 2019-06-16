`timescale 1ns / 1ps

//////////////////////////////////////////
// SDRAM Memory Controller_testbench
//Author - Rejoy Mathews
//VHDL Code copyrights - Copyright (c) 2014 Matthew Hagerty The MIT License (MIT)
//Initial Implementation - 05 Mar 2019
//Final Implementation - 19 Mar 2019
//System Verilog Implementation
//////////////////////////////////////////

module SDRAM_controller_tb(

    );
    
    // Inputs for SDRAM controller
    logic clk_200MHz_i = 0;
    logic reset_i = 0;
    logic refresh_i = 0;
    logic rw_i = 0;
    logic we_i = 0;
    logic [24:0] addr_i = 0;
    logic [15:0] data_i = 0;
    logic ub_i = 0;
    logic lb_i = 0;
  
     // Bi-Directional I/O's of the SDRAM controller
    wire [15:0] sdData_io;
  
     // Outputs of the SDRAM controller
    logic ready_o;
    logic done_o;
    logic [15:0] data_o;
    logic sdCke_o;
    logic sdCe_bo;
    logic sdRas_bo;
    logic sdCas_bo;
    logic sdWe_bo;
    logic [1:0] sdBs_o;
    logic [12:0] sdAddr_o;
    logic sdDqmu_o;
    logic sdDqml_o;
    
    ////////////////////////////////////////////
    //Sequence of operation
    //Wait until ready_o is received from the SDRAM controller. This indicates that the SDRAM has completed its initial precharge and laoding the mode register
    //This initial condition is supposed to happen on SDRAM powerup
    //When ready_o is received by the testbench it sets the SDRAM controller I/O's to enable read from the SDRAM
    //When the SDRAM read condition is tested, the SDRAM write condition is tested
    //Upon completion of SDRAM Write, the SDRAM refresh condition is tested
    //Upon completion of SDRAM refresh, the SDRAM_controller testbench send the SDRAM in an Idle state
    typedef enum {ST_WAIT, ST_IDLE, ST_READ, ST_WRITE, ST_REFRESH} fsm_state_type;
    fsm_state_type state_r = ST_WAIT;
    fsm_state_type state_x = ST_WAIT;
    
    SDRAM_controller_verilog SDRAM1(.*);
    
    initial begin
        forever #10 clk_200MHz_i = ~clk_200MHz_i;
    end
    
    always @(posedge clk_200MHz_i) begin
        state_r <= state_x;
    end
    
    always @(state_r, ready_o, done_o) begin
    //Initial definition of signals
         state_x <= state_r;
         rw_i <= 0;
         we_i <= 1;
         ub_i <= 0;
         lb_i <= 0;
         
         case(state_r)
            //Stay in the wait state till we receive the ready_o which indicates that the SDRAM startup sequence is complete
            ST_WAIT:
                begin
                    if (ready_o == 1)
                        state_x <= ST_READ;
                end
            
            //This will happen when our testbench has tested all the other SDRAM operations
            ST_IDLE:
                begin
                    state_x <= ST_IDLE;
                end
            ST_READ:
            //done_o becomes 1 when the read operation is complete, when this happens we go to the SDRAM write operation
            //Otherwise we initiate the SDRAM read sequence
                begin
                    if(done_o == 0) begin
                        rw_i <= 1;
                        addr_i <= 25'b0000000000000011000000001;
                    end
                    else
                        state_x <= ST_WRITE;                  
                end
            
            //This is similar to the test case for SDRAM read
            ST_WRITE:
                begin
                    if(done_o == 0) begin
                        rw_i <= 1;
                        we_i <= 0;
                        addr_i <= 25'b0000000000000011000000001;
                        data_i <= 16'hADCD;
                        ub_i <= 1;
                        lb_i <= 0;
                     end
                    else
                        state_x <= ST_REFRESH;             
                end
              
              //This is the final testcase we are trying to verify the functional behavior for refresh
              ST_REFRESH:
                begin
                    if (done_o == 0)
                        refresh_i <= 1;
                    else
                        state_x <= ST_IDLE;               
                end

         endcase
    end
endmodule
