/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Module: Particle_Pair_Gen_HalfShell.v
//
//	Function: 
//				Generating particle pairs based on the Half-Shell Method
//				Each home cell has 13 neighbor cells
//				This module interact with cell memeory modules and Force Evaluation unit in the follow way:
//					1, Read data from Cell Memory
//					2, Travserse all the particle in the home cell
//					3, Assemble particle pairs along with the particle ID and send to force evaluation unit
//					4, When all the reference particles in the home cell is done processing, issue a done signal
//				Cell coordinates start from (1,1,1) instead of (0,0,0)
//
// Mapping Scheme:
//				Half-shell method: each home cell interact with 13 nearest neighbors
//				For 8 Filters configurations, the mapping is follows:
//					Filter 0: 222 (home)
//					Filter 1: 223 (face) 
//					Filter 2: 231 (edge) 232 (face) 
//					Filter 3: 233 (edge) 311 (corner) 
//					Filter 4: 312 (edge) 313 (corner) 
//					Filter 5: 321 (edge) 322 (face) 
//					Filter 6: 323 (edge) 331 (corner) 
//					Filter 7: 332 (edge) 333 (corner) 
//
// Signal Explaination:
//				1. input [(NUM_NEIGHBOR_CELLS+1)*3*DATA_WIDTH-1:0] Cell_to_FSM_readout_particle_position:
//						Order: MSB->LSB {333,332,331,323,322,321,313,312,311,233,232,231,223,222} Homecell is on LSB side
//				2. done: (Will keep high until next start signal arrive)
//						When refernece particles in a home cell have all done processing, this signal will set high, until the next start signal arrives
//
// Format:
//				particle_id [PARTICLE_ID_WIDTH-1:0]:  {cell_z, cell_y, cell_x, particle_in_cell_rd_addr}
//
// Used by:
//				RL_LJ_Top.v
//
// Dependency:
//				None
//
// Latency: 
//				Memory Read: 2 cycles latency between the assignment of read address and the realted data appear on the output port
//					* Possible reason: the read address is assigned as register
//
// Todo:
//				This is a work in progress module that will be used in the final system
//				0, Process the backpressure signal
//				1, Implement a general numbering mechanism for all the cell in the simulation space, currently using fixed cells id for each input to filters
//				2, parameterize # of force evaluation units in it
//
// Created by: Chen Yang 11/01/18
//
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module Particle_Pair_Gen_HalfShell
#(
	parameter DATA_WIDTH 					= 32,
	// High level parameters
	parameter NUM_EVAL_UNIT					= 1,											// # of evaluation units in the design
	// Dataset defined parameters
	parameter NUM_NEIGHBOR_CELLS			= 13,											// # of neighbor cells per home cell, for Half-shell method, is 13
	parameter CELL_ID_WIDTH					= 4,											// log(NUM_NEIGHBOR_CELLS)
	parameter MAX_CELL_PARTICLE_NUM		= 220,										// The maximum # of particles can be in a cell
	parameter CELL_ADDR_WIDTH				= 8,											// log(MAX_CELL_PARTICLE_NUM)
	parameter PARTICLE_ID_WIDTH			= CELL_ID_WIDTH*3+CELL_ADDR_WIDTH,	// # of bit used to represent particle ID, 9*9*7 cells, each 4-bit, each cell have max of 220 particles, 8-bit
	// Filter parameters
	parameter NUM_FILTER						= 8,		//4
	parameter ARBITER_MSB 					= 128,	//8								// 2^(NUM_FILTER-1)
	parameter FILTER_BUFFER_DEPTH 		= 32,
	parameter FILTER_BUFFER_ADDR_WIDTH	= 5
)
(
	input  clk,
	input  rst,
	input  start,
	// Ports connect to Cell Memory Module
	// Order: MSB->LSB {333,332,331,323,322,321,313,312,311,233,232,231,223,222} Homecell is on LSB side
	input  [(NUM_NEIGHBOR_CELLS+1)*3*DATA_WIDTH-1:0] Cell_to_FSM_readout_particle_position,
	output [(NUM_NEIGHBOR_CELLS+1)*CELL_ADDR_WIDTH-1:0] FSM_to_Cell_read_addr,
	output FSM_to_Cell_rden,
	// Ports connect to Force Evaluation Unit
	input  [NUM_FILTER-1:0] ForceEval_to_FSM_backpressure,				// Backpressure signal from Force Evaluation Unit
	output reg [NUM_FILTER*3*DATA_WIDTH-1:0] FSM_to_ForceEval_ref_particle_position,
	output reg [NUM_FILTER*3*DATA_WIDTH-1:0] FSM_to_ForceEval_neighbor_particle_position,
	output reg [NUM_FILTER*PARTICLE_ID_WIDTH-1:0] FSM_to_ForceEval_ref_particle_id,					// {cell_z, cell_y, cell_x, ref_particle_rd_addr}
	output reg [NUM_FILTER*PARTICLE_ID_WIDTH-1:0] FSM_to_ForceEval_neighbor_particle_id,			// {cell_z, cell_y, cell_x, neighbor_particle_rd_addr}
	output reg [NUM_FILTER-1:0] FSM_to_ForceEval_input_pair_valid,		// Signify the valid of input particle data, this signal should have 1 cycle delay of the rden signal, thus wait for the data read out from BRAM
	// Ports to top level modules
	// done signal, when entire home cell is done processing, this will keep high until the next time 'start' signal turn high
	output done
);
	
	genvar i;
	
	///////////////////////////////////////////////////////////////////////////////////////////////
	// FSM controller variables
	///////////////////////////////////////////////////////////////////////////////////////////////
	// State variables
	parameter WAIT_FOR_START			= 3'b000;
	parameter READ_CELL_INFO			= 3'b001;
	parameter READ_REF_PARTICLE		= 3'b010;
	parameter RECORD_REF_PARTICLE		= 3'b011;
	parameter EVALUATION 	  			= 3'b100;
	parameter WAIT_FOR_FINISH 			= 3'b101;
	parameter CHECK_HOME_CELL_DONE	= 3'b110;
	parameter DONE 			  			= 3'b111;
	// Control Signals
	reg FSM_to_Output_homecell_done;
	assign done = FSM_to_Output_homecell_done;
	reg rden;
	assign FSM_to_Cell_rden = rden;
	reg [2:0] state;
	// Counter that wait for the last pair to finish evaluation (17+14=31 cycles)
	reg [4:0] wait_finish_counter;
	// Register recording how many particles in each cell
	// Order: MSB->LSB {333,332,331,323,322,321,313,312,311,233,232,231,223,222} Homecell is on LSB side
	reg [(NUM_NEIGHBOR_CELLS+1)*CELL_ADDR_WIDTH-1:0] FSM_Cell_Particle_Num;
	// Register recording which cell is being read by each filter
	// Filter 0 & 1 has only a single cell to read from, while 2~7 has 2 cells, after finished reading one cell, need to flip the bit to read from the next one
	reg [NUM_FILTER-1:0] FSM_Filter_Sel_Cell;
	reg [NUM_FILTER-1:0] FSM_Filter_Sel_Cell_reg1;
	reg [NUM_FILTER-1:0] delay_FSM_Filter_Sel_Cell;
	// Register for travering all the particles in each cell independently 
	// Used as read address for cells (1 cycle delay between address and readout particle info)
	// Also used to assemble the FSM_to_ForceEval_ref_particle_id
	// Order: MSB->LSB {Filter7, Filter6, ..., Filter 0}
	reg [NUM_FILTER*CELL_ADDR_WIDTH-1:0] FSM_Filter_Read_Addr;
	reg [NUM_FILTER*CELL_ADDR_WIDTH-1:0] FSM_Filter_Read_Addr_reg1;
	reg [NUM_FILTER*CELL_ADDR_WIDTH-1:0] delay_FSM_Filter_Read_Addr;
	// Flags signify if the workload on each Filter is finished
	reg [NUM_FILTER-1:0] FSM_Filter_Done_Processing;
	wire [NUM_FILTER-1:0] FSM_Filter_Done_Processing_all_1_flag;
	assign FSM_Filter_Done_Processing_all_1_flag = -1;
	reg [NUM_FILTER-1:0] FSM_Filter_Done_Processing_reg1;
	reg [NUM_FILTER-1:0] delay_FSM_Filter_Done_Processing;
	// Registers for pointing to the current reference particle
	reg [CELL_ADDR_WIDTH-1:0] FSM_Ref_Particle_Addr;
	// Registers for current reference particle position
	reg [3*DATA_WIDTH-1:0] FSM_Ref_Particle_Position;
	// Wire for composing the reference particle global id
	// !!!!! Need to implement a general ID mechianism for all the cells
	// !!!!! For here, only set the home cell as 222
	wire [NUM_EVAL_UNIT*PARTICLE_ID_WIDTH-1:0] FSM_Ref_Particle_ID;
	assign FSM_Ref_Particle_ID = {4'd2,4'd2,4'd2,FSM_Ref_Particle_Addr};
	// **** Wires for assembling the Neighbor_Particle_ID
	wire [NUM_FILTER*PARTICLE_ID_WIDTH-1:0] FSM_Neighbor_Particle_ID;
	assign FSM_Neighbor_Particle_ID[1*PARTICLE_ID_WIDTH-1:0*PARTICLE_ID_WIDTH] = {4'd2,4'd2,4'd2,delay_FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH]};
	assign FSM_Neighbor_Particle_ID[2*PARTICLE_ID_WIDTH-1:1*PARTICLE_ID_WIDTH] = {4'd3,4'd2,4'd2,delay_FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH]};
	assign FSM_Neighbor_Particle_ID[3*PARTICLE_ID_WIDTH-1:2*PARTICLE_ID_WIDTH] = (delay_FSM_Filter_Sel_Cell[2]) ? {4'd2,4'd3,4'd2,delay_FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH]} : {4'd1,4'd3,4'd2,delay_FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH]};
	assign FSM_Neighbor_Particle_ID[4*PARTICLE_ID_WIDTH-1:3*PARTICLE_ID_WIDTH] = (delay_FSM_Filter_Sel_Cell[3]) ? {4'd1,4'd1,4'd3,delay_FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH]} : {4'd3,4'd3,4'd2,delay_FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH]};
	assign FSM_Neighbor_Particle_ID[5*PARTICLE_ID_WIDTH-1:4*PARTICLE_ID_WIDTH] = (delay_FSM_Filter_Sel_Cell[4]) ? {4'd3,4'd1,4'd3,delay_FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH]} : {4'd2,4'd1,4'd3,delay_FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH]};
	assign FSM_Neighbor_Particle_ID[6*PARTICLE_ID_WIDTH-1:5*PARTICLE_ID_WIDTH] = (delay_FSM_Filter_Sel_Cell[5]) ? {4'd2,4'd2,4'd3,delay_FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH]} : {4'd1,4'd2,4'd3,delay_FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH]};
	assign FSM_Neighbor_Particle_ID[7*PARTICLE_ID_WIDTH-1:6*PARTICLE_ID_WIDTH] = (delay_FSM_Filter_Sel_Cell[6]) ? {4'd1,4'd3,4'd3,delay_FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH]} : {4'd3,4'd2,4'd3,delay_FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH]};
	assign FSM_Neighbor_Particle_ID[8*PARTICLE_ID_WIDTH-1:7*PARTICLE_ID_WIDTH] = (delay_FSM_Filter_Sel_Cell[7]) ? {4'd3,4'd3,4'd3,delay_FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH]} : {4'd2,4'd3,4'd3,delay_FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH]};
	
	
	///////////////////////////////////////////////////////////////////////////////////////////////
	// Signals between Cell Module and FSM
	///////////////////////////////////////////////////////////////////////////////////////////////
	//// Signals connect from cell module to FSM
	// Position Data
	// Order: MSB->LSB {333,332,331,323,322,321,313,312,311,233,232,231,223,222} Homecell is on LSB side
	// wire [(NUM_NEIGHBOR_CELLS+1)*3*DATA_WIDTH-1:0] Cell_to_FSM_readout_particle_position;
	// **** Wires for assembling the Neighbor_Particle_Position
	wire [NUM_FILTER*3*DATA_WIDTH-1:0] FSM_Neighbor_Particle_Position;
	// Filter 0, cell 222
	assign FSM_Neighbor_Particle_Position[1*3*DATA_WIDTH-1:0*3*DATA_WIDTH] = Cell_to_FSM_readout_particle_position[1*3*DATA_WIDTH-1:0*3*DATA_WIDTH];
	// Filter 1, cell 223
	assign FSM_Neighbor_Particle_Position[2*3*DATA_WIDTH-1:1*3*DATA_WIDTH] = Cell_to_FSM_readout_particle_position[2*3*DATA_WIDTH-1:1*3*DATA_WIDTH];
	// Filter 2, cell 231 or cell 232
	assign FSM_Neighbor_Particle_Position[3*3*DATA_WIDTH-1:2*3*DATA_WIDTH] = (delay_FSM_Filter_Sel_Cell[2]) ? Cell_to_FSM_readout_particle_position[4*3*DATA_WIDTH-1:3*3*DATA_WIDTH] : Cell_to_FSM_readout_particle_position[3*3*DATA_WIDTH-1:2*3*DATA_WIDTH];
	// Filter 3, cell 233 or cell 311
	assign FSM_Neighbor_Particle_Position[4*3*DATA_WIDTH-1:3*3*DATA_WIDTH] = (delay_FSM_Filter_Sel_Cell[3]) ? Cell_to_FSM_readout_particle_position[6*3*DATA_WIDTH-1:5*3*DATA_WIDTH] : Cell_to_FSM_readout_particle_position[5*3*DATA_WIDTH-1:4*3*DATA_WIDTH];
	// Filter 4, cell 312 or cell 313
	assign FSM_Neighbor_Particle_Position[5*3*DATA_WIDTH-1:4*3*DATA_WIDTH] = (delay_FSM_Filter_Sel_Cell[4]) ? Cell_to_FSM_readout_particle_position[8*3*DATA_WIDTH-1:7*3*DATA_WIDTH] : Cell_to_FSM_readout_particle_position[7*3*DATA_WIDTH-1:6*3*DATA_WIDTH];
	// Filter 5, cell 321 or cell 322
	assign FSM_Neighbor_Particle_Position[6*3*DATA_WIDTH-1:5*3*DATA_WIDTH] = (delay_FSM_Filter_Sel_Cell[5]) ? Cell_to_FSM_readout_particle_position[10*3*DATA_WIDTH-1:9*3*DATA_WIDTH] : Cell_to_FSM_readout_particle_position[9*3*DATA_WIDTH-1:8*3*DATA_WIDTH];
	// Filter 6, cell 323 or cell 331
	assign FSM_Neighbor_Particle_Position[7*3*DATA_WIDTH-1:6*3*DATA_WIDTH] = (delay_FSM_Filter_Sel_Cell[6]) ? Cell_to_FSM_readout_particle_position[12*3*DATA_WIDTH-1:11*3*DATA_WIDTH] : Cell_to_FSM_readout_particle_position[11*3*DATA_WIDTH-1:10*3*DATA_WIDTH];
	// Filter 7, cell 332 or cell 333
	assign FSM_Neighbor_Particle_Position[8*3*DATA_WIDTH-1:7*3*DATA_WIDTH] = (delay_FSM_Filter_Sel_Cell[7]) ? Cell_to_FSM_readout_particle_position[14*3*DATA_WIDTH-1:13*3*DATA_WIDTH] : Cell_to_FSM_readout_particle_position[13*3*DATA_WIDTH-1:12*3*DATA_WIDTH];
	
	//// Signals connect from FSM to cell modules
	// Read Address to cells
	// wire [(NUM_NEIGHBOR_CELLS+1)*CELL_ADDR_WIDTH-1:0] FSM_to_Cell_read_addr;
	// ******** This is closely related with the mapping scheme
	// ******** Should the mapping scheme changes, or # of filters changes, redo this part
	assign FSM_to_Cell_read_addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] = FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH];				// Cell 0, Filter 0
	assign FSM_to_Cell_read_addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] = FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH];				// Cell 1, Filter 1
	generate
		for(i = 2; i < NUM_FILTER; i = i + 1)		// For each filter
			begin: assign_read_addr_FSM_to_Cell
			assign FSM_to_Cell_read_addr[(2*i-1)*CELL_ADDR_WIDTH-1:(2*i-2)*CELL_ADDR_WIDTH] = (FSM_Filter_Sel_Cell[i]) ? 0 : FSM_Filter_Read_Addr[(i+1)*CELL_ADDR_WIDTH-1:i*CELL_ADDR_WIDTH];
			assign FSM_to_Cell_read_addr[(2*i)*CELL_ADDR_WIDTH-1:(2*i-1)*CELL_ADDR_WIDTH] = (FSM_Filter_Sel_Cell[i]) ? FSM_Filter_Read_Addr[(i+1)*CELL_ADDR_WIDTH-1:i*CELL_ADDR_WIDTH] : 0 ;
			end
	endgenerate
	
	///////////////////////////////////////////////////////////////////////////////////////////////
	// FSM for pariticle pairs generation
	///////////////////////////////////////////////////////////////////////////////////////////////
	always@(posedge clk)
		begin
		//////////////////////////////////////////////////////////
		// Assign a bunch of prev registers for processing use
		//////////////////////////////////////////////////////////
		// Used in assigning the FSM_to_ForceEval_input_pair_valid, to make up the 2 cycles delay when read address is assigned but actual data comes later
		FSM_Filter_Done_Processing_reg1 <= FSM_Filter_Done_Processing;
		delay_FSM_Filter_Done_Processing <= FSM_Filter_Done_Processing_reg1;
		// Used in generating reference particle ID, to make up the 2 cycles delay between read address and readout data
		FSM_Filter_Read_Addr_reg1 <= FSM_Filter_Read_Addr;
		delay_FSM_Filter_Read_Addr <= FSM_Filter_Read_Addr_reg1;
		// Used in generating neighbor particle ID, to select from one of the cell IDs assigned to filter
		FSM_Filter_Sel_Cell_reg1 <= FSM_Filter_Sel_Cell;
		delay_FSM_Filter_Sel_Cell <= FSM_Filter_Sel_Cell_reg1;
		
		if(rst)
			begin
			rden <= 1'b0;
			wait_finish_counter <= 0;
			// FSM control registers
			FSM_Cell_Particle_Num <= 0;
			FSM_Filter_Sel_Cell <= 0;
			FSM_Filter_Read_Addr <= 0;
			FSM_Filter_Done_Processing <= 0;
			FSM_Ref_Particle_Addr <= 0;
			FSM_Ref_Particle_Position <= 0;
			// FSM to Force Evaluation
			FSM_to_ForceEval_ref_particle_position <= 0;
			FSM_to_ForceEval_neighbor_particle_position <= 0;
			FSM_to_ForceEval_ref_particle_id <= 0;
			FSM_to_ForceEval_neighbor_particle_id <= 0;
			FSM_to_ForceEval_input_pair_valid <= 0;
			// FSM to Output
			FSM_to_Output_homecell_done <= 1'b0;
			
			// FSM state control
			state <= WAIT_FOR_START;
			end			
		else
			begin
			rden <= 1'b1;
			case(state)
				// Wait for the start signal to arrive
				WAIT_FOR_START:
					begin
					wait_finish_counter <= 0;
					// FSM to Output
					// Maintain the previous done signal while waiting for the next start signal, thus to keep the done signal high
					FSM_to_Output_homecell_done <= FSM_to_Output_homecell_done;
					// FSM control registers
					FSM_Cell_Particle_Num <= 0;
					FSM_Filter_Sel_Cell <= 0;
					FSM_Filter_Read_Addr <= 0;			// always read address 0 to get the # of particles
					FSM_Filter_Done_Processing <= 0;
					FSM_Ref_Particle_Addr <= 1;		// Starting from the 1st particle in the home cell
					FSM_Ref_Particle_Position <= 0;
					// FSM to Force Evaluation
					FSM_to_ForceEval_ref_particle_position <= 0;
					FSM_to_ForceEval_neighbor_particle_position <= 0;
					FSM_to_ForceEval_ref_particle_id <= 0;
					FSM_to_ForceEval_neighbor_particle_id <= 0;
					FSM_to_ForceEval_input_pair_valid <= 0;
					// State control
					if(start)
						begin
//						// Pre-fetch the first particle in the home cell as the first reference particle
//						FSM_Filter_Read_Addr[CELL_ADDR_WIDTH-1:0] <= 1;
//						FSM_Filter_Read_Addr[NUM_FILTER*CELL_ADDR_WIDTH-1:CELL_ADDR_WIDTH] <= 0;
						state <= READ_CELL_INFO;
						end
					else
						begin
//						FSM_Filter_Read_Addr <= 0;
						state <= WAIT_FOR_START;
						end
					end
				
				// Read out the particle number from each cell
				// This state kept for 1 cycles: since the rden is always high, and the read address is initialized as 0, then the output port on each cell memory should already have the particle number ready
				READ_CELL_INFO:
					begin
					wait_finish_counter <= 0;
					// FSM to Output
					FSM_to_Output_homecell_done <= 1'b0;
					// FSM control registers
					FSM_Filter_Sel_Cell <= 0;
					FSM_Filter_Read_Addr <= 0;			// always read out the first particle in the home cell as reference particle
					FSM_Filter_Done_Processing <= 0;
					FSM_Ref_Particle_Addr <= 1;		// Starting from the 1st particle in the home cell
					FSM_Ref_Particle_Position <= 0;
					// FSM to Force Evaluation
					FSM_to_ForceEval_ref_particle_position <= 0;
					FSM_to_ForceEval_neighbor_particle_position <= 0;
					FSM_to_ForceEval_ref_particle_id <= 0;
					FSM_to_ForceEval_neighbor_particle_id <= 0;
					FSM_to_ForceEval_input_pair_valid <= 0;
					// State control
					state <= READ_REF_PARTICLE;
					
					// Write the cell particle num register
					FSM_Cell_Particle_Num[ 1*CELL_ADDR_WIDTH-1: 0*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 0*3*DATA_WIDTH-1: 0*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 2*CELL_ADDR_WIDTH-1: 1*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 1*3*DATA_WIDTH-1: 1*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 3*CELL_ADDR_WIDTH-1: 2*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 2*3*DATA_WIDTH-1: 2*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 4*CELL_ADDR_WIDTH-1: 3*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 3*3*DATA_WIDTH-1: 3*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 5*CELL_ADDR_WIDTH-1: 4*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 4*3*DATA_WIDTH-1: 4*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 6*CELL_ADDR_WIDTH-1: 5*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 5*3*DATA_WIDTH-1: 5*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 7*CELL_ADDR_WIDTH-1: 6*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 6*3*DATA_WIDTH-1: 6*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 8*CELL_ADDR_WIDTH-1: 7*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 7*3*DATA_WIDTH-1: 7*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[ 9*CELL_ADDR_WIDTH-1: 8*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 8*3*DATA_WIDTH-1: 8*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[10*CELL_ADDR_WIDTH-1: 9*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+ 9*3*DATA_WIDTH-1: 9*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[11*CELL_ADDR_WIDTH-1:10*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+10*3*DATA_WIDTH-1:10*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[12*CELL_ADDR_WIDTH-1:11*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+11*3*DATA_WIDTH-1:11*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[13*CELL_ADDR_WIDTH-1:12*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+12*3*DATA_WIDTH-1:12*3*DATA_WIDTH];
					FSM_Cell_Particle_Num[14*CELL_ADDR_WIDTH-1:13*CELL_ADDR_WIDTH] <= Cell_to_FSM_readout_particle_position[CELL_ADDR_WIDTH+13*3*DATA_WIDTH-1:13*3*DATA_WIDTH];
					end
				
				// Readout the reference particle
				// There are 2 cycles latency between address assigned and data on the output port, need to wait at this state for 3 cycles
				// 1st cycle: assign the read address, 2nd cycle: read address appear on RAM, 3rd cycle: data read out at the end of this cycle
				READ_REF_PARTICLE:
					begin
					wait_finish_counter <= wait_finish_counter + 1'b1;
					// FSM to Output
					FSM_to_Output_homecell_done <= 1'b0;
					// FSM control registers
					FSM_Cell_Particle_Num <= FSM_Cell_Particle_Num;					// Keep the Cell_Particle_Num during the entire process
					FSM_Filter_Sel_Cell <= 0;
					FSM_Filter_Done_Processing <= 0;
					FSM_Ref_Particle_Addr <= FSM_Ref_Particle_Addr;					// Keep the current Ref_Particle_Addr
					FSM_Ref_Particle_Position <= FSM_Ref_Particle_Position;		// Keep the prev Ref_Particle_Position
					// FSM to Force Evaluation
					FSM_to_ForceEval_ref_particle_position <= 0;
					FSM_to_ForceEval_neighbor_particle_position <= 0;
					FSM_to_ForceEval_ref_particle_id <= 0;
					FSM_to_ForceEval_neighbor_particle_id <= 0;
					FSM_to_ForceEval_input_pair_valid <= 0;
					
					// Assign the state
					if(wait_finish_counter == 2)
						state <= RECORD_REF_PARTICLE;
					else
						state <= READ_REF_PARTICLE;
					
					// Assign the read address for the home cell to fetch reference particles
					// Latency for this is 2 cycles for a single reference particle case
					// *** A prefetch of course can be done in the READ_CELL_INFO or the WAIT_FOR_START stage, but for consistant when there are multiple filters workin on different reference particle, we implement this independent state to process the reference particles
					if(wait_finish_counter == 0)
						//	The first cycle read the reference particle
						begin
						FSM_Filter_Read_Addr[CELL_ADDR_WIDTH-1:0] <= FSM_Ref_Particle_Addr;
						FSM_Filter_Read_Addr[NUM_FILTER*CELL_ADDR_WIDTH-1:CELL_ADDR_WIDTH] <= 0;
						end
					else if(wait_finish_counter == 1)
						//	The second cycle prefetch the neighbor particles
						begin
						FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] = 1;
						FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] = 1;
						FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] = 1;
						FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] = 1;
						FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] = 1;
						FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] = 1;
						FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] = 1;
						FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] = 1;
						end
					else
						//	The thrid cycle prefetch the 2nd neighbor particles
						begin
						FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] = 2;
						FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] = 2;
						FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] = 2;
						FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] = 2;
						FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] = 2;
						FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] = 2;
						FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] = 2;
						FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] = 2;
						end
					end
				
				// Recording the current reference particle
				RECORD_REF_PARTICLE:
					begin
					wait_finish_counter <= 0;
					// FSM to Output
					FSM_to_Output_homecell_done <= 1'b0;
					// FSM control registers
					FSM_Cell_Particle_Num <= FSM_Cell_Particle_Num;					// Keep the Cell_Particle_Num during the entire process
					FSM_Filter_Sel_Cell <= FSM_Filter_Sel_Cell;			
					FSM_Filter_Done_Processing <= 0;			// Keep the selection bit
					FSM_Ref_Particle_Addr <= FSM_Ref_Particle_Addr;					// Keep the current Ref_Particle_Addr
					// FSM to Force Evaluation
					FSM_to_ForceEval_ref_particle_position <= 0;
					FSM_to_ForceEval_neighbor_particle_position <= 0;
					FSM_to_ForceEval_ref_particle_id <= 0;
					FSM_to_ForceEval_neighbor_particle_id <= 0;
					FSM_to_ForceEval_input_pair_valid <= 0;
					// Assign state
					state <= EVALUATION;
					
					// Assign the new ref particle position
					// The readout data from Home cell
					FSM_Ref_Particle_Position <= Cell_to_FSM_readout_particle_position[3*DATA_WIDTH-1:0];
					
					// Pre assign the read address for the 2nd neighbor particle
					// *** Suppose there are more than 3 particles in each cell
					FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] = 3;
					FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] = 3;
					FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] = 3;
					FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] = 3;
					FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] = 3;
					FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] = 3;
					FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] = 3;
					FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] = 3;
					end
				
				// Start generating particle pairs
				EVALUATION:
					begin
					wait_finish_counter <= 0;
					// FSM to Output
					FSM_to_Output_homecell_done <= 1'b0;
					// FSM control registers
					FSM_Cell_Particle_Num <= FSM_Cell_Particle_Num;					// Keep the Cell_Particle_Num during the entire process
					FSM_Ref_Particle_Addr <= FSM_Ref_Particle_Addr;					// Keep the current Ref_Particle_Addr
					FSM_Ref_Particle_Position <= FSM_Ref_Particle_Position;		// Keep the current Ref_Particle_Position

					//////////////////////////////////////////////////////////////////////////////////////////////
					// Process Filter Read Address
					//////////////////////////////////////////////////////////////////////////////////////////////
					// Filter 0
					// Handle home cell (222)
					if(FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH])
						begin
						FSM_Filter_Sel_Cell[0] <= 1'b0;
						FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] + 1'b1;
						FSM_Filter_Done_Processing[0] <= 1'b0;
						end
					else
						begin
						FSM_Filter_Sel_Cell[0] <= 1'b0;
						FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[1*CELL_ADDR_WIDTH-1:0*CELL_ADDR_WIDTH];
						FSM_Filter_Done_Processing[0] <= 1'b1;
						end

					// Filter 1
					// Handle 1 cell (223)
					if(FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH])
						begin
						FSM_Filter_Sel_Cell[1] <= 1'b0;
						FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] + 1'b1;
						FSM_Filter_Done_Processing[1] <= 1'b0;
						end
					else
						begin
						FSM_Filter_Sel_Cell[1] <= 1'b0;
						FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[2*CELL_ADDR_WIDTH-1:1*CELL_ADDR_WIDTH];
						FSM_Filter_Done_Processing[1] <= 1'b1;
						end

					// Filter 2
					// Handles 2 cells (231, 232)
					if(FSM_Filter_Sel_Cell[2] == 1'b0)			// Processing the 1st neighbor cell
						begin
						FSM_Filter_Done_Processing[2] <= 1'b0;		// Processing not finished
						if(FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Sel_Cell[2] <= 1'b0;
							FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] + 1'b1;
							end
						else
							begin
							FSM_Filter_Sel_Cell[2] <= 1'b1;
							FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] <= 1;			// Start from address 1 for the next cell
							end
						end
					else					// Processing the 2nd neighbor cell
						begin
						FSM_Filter_Sel_Cell[2] <= FSM_Filter_Sel_Cell[2];					// Sel bit remains
						if(FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] + 1'b1;
							FSM_Filter_Done_Processing[2] <= 1'b0;
							end
						else
							begin
							FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[3*CELL_ADDR_WIDTH-1:2*CELL_ADDR_WIDTH];
							FSM_Filter_Done_Processing[2] <= 1'b1;								// Processing done
							end
						end
						
					// Filter 3
					// Handles 2 cells (233, 311)
					if(FSM_Filter_Sel_Cell[3] == 1'b0)			// Processing the 1st neighbor cell
						begin
						FSM_Filter_Done_Processing[3] <= 1'b0;		// Processing not finished
						if(FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Sel_Cell[3] <= 1'b0;
							FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] + 1'b1;
							end
						else
							begin
							FSM_Filter_Sel_Cell[3] <= 1'b1;
							FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] <= 1;			// Start from address 1 for the next cell
							end
						end
					else					// Processing the 2nd neighbor cell
						begin
						FSM_Filter_Sel_Cell[3] <= FSM_Filter_Sel_Cell[3];					// Sel bit remains
						if(FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] + 1'b1;
							FSM_Filter_Done_Processing[3] <= 1'b0;
							end
						else
							begin
							FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[4*CELL_ADDR_WIDTH-1:3*CELL_ADDR_WIDTH];
							FSM_Filter_Done_Processing[3] <= 1'b1;								// Processing done
							end
						end
						
					// Filter 4
					// Handles 2 cells (312, 313)
					if(FSM_Filter_Sel_Cell[4] == 1'b0)			// Processing the 1st neighbor cell
						begin
						FSM_Filter_Done_Processing[4] <= 1'b0;		// Processing not finished
						if(FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Sel_Cell[4] <= 1'b0;
							FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] + 1'b1;
							end
						else
							begin
							FSM_Filter_Sel_Cell[4] <= 1'b1;
							FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] <= 1;			// Start from address 1 for the next cell
							end
						end
					else					// Processing the 2nd neighbor cell
						begin
						FSM_Filter_Sel_Cell[4] <= FSM_Filter_Sel_Cell[4];					// Sel bit remains
						if(FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] + 1'b1;
							FSM_Filter_Done_Processing[4] <= 1'b0;
							end
						else
							begin
							FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[5*CELL_ADDR_WIDTH-1:4*CELL_ADDR_WIDTH];
							FSM_Filter_Done_Processing[4] <= 1'b1;								// Processing done
							end
						end	
					
					// Filter 5
					// Handles 2 cells (321, 322)
					if(FSM_Filter_Sel_Cell[5] == 1'b0)			// Processing the 1st neighbor cell
						begin
						FSM_Filter_Done_Processing[5] <= 1'b0;		// Processing not finished
						if(FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[9*CELL_ADDR_WIDTH-1:8*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Sel_Cell[5] <= 1'b0;
							FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] + 1'b1;
							end
						else
							begin
							FSM_Filter_Sel_Cell[5] <= 1'b1;
							FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] <= 1;			// Start from address 1 for the next cell
							end
						end
					else					// Processing the 2nd neighbor cell
						begin
						FSM_Filter_Sel_Cell[5] <= FSM_Filter_Sel_Cell[5];					// Sel bit remains
						if(FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[10*CELL_ADDR_WIDTH-1:9*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] + 1'b1;
							FSM_Filter_Done_Processing[5] <= 1'b0;
							end
						else
							begin
							FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[6*CELL_ADDR_WIDTH-1:5*CELL_ADDR_WIDTH];
							FSM_Filter_Done_Processing[5] <= 1'b1;								// Processing done
							end
						end	
			
					// Filter 6
					// Handles 2 cells (323, 331)
					if(FSM_Filter_Sel_Cell[6] == 1'b0)			// Processing the 1st neighbor cell
						begin
						FSM_Filter_Done_Processing[6] <= 1'b0;		// Processing not finished
						if(FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[11*CELL_ADDR_WIDTH-1:10*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Sel_Cell[6] <= 1'b0;
							FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] + 1'b1;
							end
						else
							begin
							FSM_Filter_Sel_Cell[6] <= 1'b1;
							FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] <= 1;			// Start from address 1 for the next cell
							end
						end
					else					// Processing the 2nd neighbor cell
						begin
						FSM_Filter_Sel_Cell[6] <= FSM_Filter_Sel_Cell[6];					// Sel bit remains
						if(FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[12*CELL_ADDR_WIDTH-1:11*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] + 1'b1;
							FSM_Filter_Done_Processing[6] <= 1'b0;
							end
						else
							begin
							FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[7*CELL_ADDR_WIDTH-1:6*CELL_ADDR_WIDTH];
							FSM_Filter_Done_Processing[6] <= 1'b1;								// Processing done
							end
						end	
			
					// Filter 7
					// Handles 2 cells (332, 333)
					if(FSM_Filter_Sel_Cell[7] == 1'b0)			// Processing the 1st neighbor cell
						begin
						FSM_Filter_Done_Processing[7] <= 1'b0;		// Processing not finished
						if(FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[13*CELL_ADDR_WIDTH-1:12*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Sel_Cell[7] <= 1'b0;
							FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] + 1'b1;
							end
						else
							begin
							FSM_Filter_Sel_Cell[7] <= 1'b1;
							FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] <= 1;			// Start from address 1 for the next cell
							end
						end
					else					// Processing the 2nd neighbor cell
						begin
						FSM_Filter_Sel_Cell[7] <= FSM_Filter_Sel_Cell[7];					// Sel bit remains
						if(FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] < FSM_Cell_Particle_Num[14*CELL_ADDR_WIDTH-1:13*CELL_ADDR_WIDTH])
							begin
							FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] + 1'b1;
							FSM_Filter_Done_Processing[7] <= 1'b0;
							end
						else
							begin
							FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH] <= FSM_Filter_Read_Addr[8*CELL_ADDR_WIDTH-1:7*CELL_ADDR_WIDTH];
							FSM_Filter_Done_Processing[7] <= 1'b1;								// Processing done
							end
						end	
					
					
					//////////////////////////////////////////////////////////////////////////////////////////////
					// Process Input Data to Force Evaluation Unit
					//////////////////////////////////////////////////////////////////////////////////////////////
					// All share the same reference particles
					FSM_to_ForceEval_ref_particle_position <= {FSM_Ref_Particle_Position,FSM_Ref_Particle_Position,FSM_Ref_Particle_Position,FSM_Ref_Particle_Position,FSM_Ref_Particle_Position,FSM_Ref_Particle_Position,FSM_Ref_Particle_Position,FSM_Ref_Particle_Position};
					// Reference particle ID is the same
					FSM_to_ForceEval_ref_particle_id <= {FSM_Ref_Particle_ID,FSM_Ref_Particle_ID,FSM_Ref_Particle_ID,FSM_Ref_Particle_ID,FSM_Ref_Particle_ID,FSM_Ref_Particle_ID,FSM_Ref_Particle_ID,FSM_Ref_Particle_ID};
					FSM_to_ForceEval_neighbor_particle_position <= FSM_Neighbor_Particle_Position;
					FSM_to_ForceEval_neighbor_particle_id <= FSM_Neighbor_Particle_ID;
					// If the filter is not done processing, then the input should be valid
					// ?????? There suppose to be a one cycle delay here, suppose at a cycle, the flag just turn 1, but the last readout data should still be valid
					// Perhaps can be done by assigning a delay_FSM_Filter_Done_Processing register?
					FSM_to_ForceEval_input_pair_valid <= ~delay_FSM_Filter_Done_Processing;	
					
					//////////////////////////////////////////////////////////////////////////////////////////////
					// Assign Next State
					//////////////////////////////////////////////////////////////////////////////////////////////
					// If all the filters are done processing, then move to next state
//					if(~FSM_Filter_Done_Processing == 0)
//					if(FSM_Filter_Done_Processing == 8'b11111111)
					if(FSM_Filter_Done_Processing == FSM_Filter_Done_Processing_all_1_flag)
						state <= CHECK_HOME_CELL_DONE;
					else
						state <= EVALUATION;					
					end
					
				// After the current reference particle is done evaluating, check if all the particles in home cell has done evaluation
				// If not, assign the next reference particle, jump back to EVALUATION
				// If so, jump to WAIT_FOR_FINISH, wait for the last particle pair traverse the entire pipeline
				CHECK_HOME_CELL_DONE:
					begin
					wait_finish_counter <= 0;
					// FSM to Output
					FSM_to_Output_homecell_done <= 1'b0;
					// FSM control registers					
					FSM_Cell_Particle_Num <= FSM_Cell_Particle_Num;					// Keep the Cell_Particle_Num during the entire process
					FSM_Filter_Sel_Cell <= FSM_Filter_Sel_Cell;						// Keep the selection bit
					FSM_Filter_Read_Addr <= 0;												// Reset filter read address to 0
					FSM_Filter_Done_Processing <= 0;
					FSM_Ref_Particle_Position <= FSM_Ref_Particle_Position;		// Keep the current Ref_Particle_Position
					// FSM to Force Evaluation
					FSM_to_ForceEval_ref_particle_position <= 0;
					FSM_to_ForceEval_neighbor_particle_position <= 0;
					FSM_to_ForceEval_ref_particle_id <= 0;
					FSM_to_ForceEval_neighbor_particle_id <= 0;
					FSM_to_ForceEval_input_pair_valid <= 0;
					
					// if there are still reference particles not traversed, increment the read address (the fetch will be done in READ_REF_PARTICLE stage)
					if(FSM_Ref_Particle_Addr < FSM_Cell_Particle_Num[CELL_ADDR_WIDTH-1:0])
						begin
						FSM_Ref_Particle_Addr <= FSM_Ref_Particle_Addr + 1'b1;
						state <= READ_REF_PARTICLE;
						end
					// If all reference particles has been traversed, then move on to the wait stage
					else
						begin
						FSM_Ref_Particle_Addr <= FSM_Ref_Particle_Addr;
						state <= WAIT_FOR_FINISH;
						end
						
					end
				
				// After the last refernece particle is done, wait for the last pair of paricles traverse the entire pipeline
				WAIT_FOR_FINISH:
					begin
					wait_finish_counter <= wait_finish_counter + 1'b1;
					// FSM to Output
					FSM_to_Output_homecell_done <= 1'b0;
					// FSM control registers					
					FSM_Cell_Particle_Num <= FSM_Cell_Particle_Num;					// Keep the Cell_Particle_Num during the entire process
					FSM_Filter_Sel_Cell <= 0;												// Reset the selection bit
					FSM_Filter_Read_Addr <= 0;												// Reset filter read address to 0
					FSM_Filter_Done_Processing <= 0;
					FSM_Ref_Particle_Addr <= FSM_Ref_Particle_Addr;
					FSM_Ref_Particle_Position <= FSM_Ref_Particle_Position;		// Keep the current Ref_Particle_Position
					// FSM to Force Evaluation
					FSM_to_ForceEval_ref_particle_position <= 0;
					FSM_to_ForceEval_neighbor_particle_position <= 0;
					FSM_to_ForceEval_ref_particle_id <= 0;
					FSM_to_ForceEval_neighbor_particle_id <= 0;
					FSM_to_ForceEval_input_pair_valid <= 0;
					
					// Assgin the next state
					// !!!!! The wait cycle 40 is given arbitraily, may need for some adjustments
					if(wait_finish_counter < 40)
						state <= WAIT_FOR_FINISH;
					else
						state <= DONE;
					
					end
				// Send out a flag signify the current home cell is done evaluation, the motion update can proceed
				DONE:
					begin
					wait_finish_counter <= 0;
					// FSM to Output
					FSM_to_Output_homecell_done <= 1'b1;
					// FSM control registers					
					FSM_Cell_Particle_Num <= FSM_Cell_Particle_Num;					// Keep the Cell_Particle_Num during the entire process
					FSM_Filter_Sel_Cell <= 0;												// Reset the selection bit
					FSM_Filter_Read_Addr <= 0;												// Reset filter read address to 0
					FSM_Filter_Done_Processing <= 0;
					FSM_Ref_Particle_Addr <= 0;
					FSM_Ref_Particle_Position <= 0;										// Reset the current Ref_Particle_Position
					// FSM to Force Evaluation
					FSM_to_ForceEval_ref_particle_position <= 0;
					FSM_to_ForceEval_neighbor_particle_position <= 0;
					FSM_to_ForceEval_ref_particle_id <= 0;
					FSM_to_ForceEval_neighbor_particle_id <= 0;
					FSM_to_ForceEval_input_pair_valid <= 0;
					// Assgin the next state
					state <= WAIT_FOR_START;
					end
					
			endcase
			end
		end

endmodule


