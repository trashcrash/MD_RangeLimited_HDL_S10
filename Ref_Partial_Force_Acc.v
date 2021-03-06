/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// !!!!!!!!!!!!!!!!!!!! Work in progress!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
//	Module: Ref_Partial_Force_Acc.v
//
//	Function: Accumulate the particle force for a single reference particle
//				Take the partial force from force evaluation module every cycle and perform accumulation
//				When the input particle id changed, which means the accumulation for the current particle has done, then output the accumulated force, and set as valid
//				When particle id change, reset the accumulated value and restart accumulation
//				The accumulator is always in enable mode, if the incoming data is invalid, set the input value as 0
//				Since consequective incoming data all targeting the same particle, the accumulation dosen't need to maintain the incoming order.
//				The FP_ADD module has 3 cycles latency, the data flow is always add the newly incoming data to the output of FP_ADD (if input is invalid, set as 0).
//				In this case, there will be 3 intermediate ACC values cycling in the FP_ADD module. In the end, add the 3 intermediate value together will give the final value.
//
// Prerequisites:
//				Input partial forces targeting the same reference particle should come in a consequtive manner.
//				Such patterns like: P1, P1, P2, P1, P1 is not supported.
//				Supported patterns: P1, P1, Invalid, Invalid, P1, Invalid, P1, ...., P10, P10, P3, P7, P7, P7, Invalid, ..., P4 .... 
//
// Used by:
//				RL_LJ_Evaluation_Unit.v
//
// Dependency:
//				FP_ADD.v
//
// Testbench:
//				Ref_Partial_Force_Acc_tb.v
//
// Timing: 
//				FP_ADD: 3 cycles
//
// Created by: Chen Yang 12/14/2018
//
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

module Ref_Partial_Force_Acc
#(
	parameter DATA_WIDTH 					= 32,
	parameter PARTICLE_ID_WIDTH			= 20								// # of bit used to represent particle ID, 9*9*7 cells, each 4-bit, each cell have max of 200 particles, 8-bit
)
(
	input  clk,
	input  rst,
	input  in_input_valid,
	input  [PARTICLE_ID_WIDTH-1:0] in_particle_id,
	input  [DATA_WIDTH-1:0] in_partial_force_x,							// in IEEE single precision floating point format
	input  [DATA_WIDTH-1:0] in_partial_force_y,							// in IEEE single precision floating point format
	input  [DATA_WIDTH-1:0] in_partial_force_z,							// in IEEE single precision floating point format
	output reg [PARTICLE_ID_WIDTH-1:0] out_particle_id,
	output reg [DATA_WIDTH-1:0] out_particle_acc_force_x,
	output reg [DATA_WIDTH-1:0] out_particle_acc_force_y,
	output reg [DATA_WIDTH-1:0] out_particle_acc_force_z,
	output reg out_acc_force_valid											// only set as valid when the particle_id changes, which means the accumulation for the current particle is done
);

	reg [PARTICLE_ID_WIDTH-1:0] cur_particle_id;							// Record the particle id for the current accumulated particle
	
	//////////////////////////////////////////////////////////////////////////////////////////////////////
	// Signals connected to accumulators
	//////////////////////////////////////////////////////////////////////////////////////////////////////
	// Enable the accumulation operation
	// Always set as enable
	wire acc_enable;
	assign acc_enable = ~rst;
	
	// Accumulated output value
	wire [DATA_WIDTH-1:0] acc_value_out_x;									
	wire [DATA_WIDTH-1:0] acc_value_out_y;
	wire [DATA_WIDTH-1:0] acc_value_out_z;
	
	// Assign wires for partial force, if the incoming data is invalid, set as 0
	wire [DATA_WIDTH-1:0] partial_force_x_in_wire;
	wire [DATA_WIDTH-1:0] partial_force_y_in_wire;
	wire [DATA_WIDTH-1:0] partial_force_z_in_wire;
	assign partial_force_x_in_wire = (in_input_valid) ? in_partial_force_x : 0;
	assign partial_force_y_in_wire = (in_input_valid) ? in_partial_force_y : 0;
	assign partial_force_z_in_wire = (in_input_valid) ? in_partial_force_z : 0;
	
	// Assign wires for accumulation data, if particle id changes, set the acc value as 0
	wire [DATA_WIDTH-1:0] acc_force_x_in_wire;
	wire [DATA_WIDTH-1:0] acc_force_y_in_wire;
	wire [DATA_WIDTH-1:0] acc_force_z_in_wire;
	assign acc_force_x_in_wire = (cur_particle_id == in_particle_id) ? acc_value_out_x : 0;
	assign acc_force_y_in_wire = (cur_particle_id == in_particle_id) ? acc_value_out_y : 0;
	assign acc_force_z_in_wire = (cur_particle_id == in_particle_id) ? acc_value_out_z : 0;

	// Controller for accumulation operation
	always@(posedge clk)
		begin
		if(rst)
			begin
			cur_particle_id <= 0;
			// Output signal
			out_particle_id <= 0;
			out_particle_acc_force_x <= 0;
			out_particle_acc_force_y <= 0;
			out_particle_acc_force_z <= 0;
			out_acc_force_valid <= 1'b0;
			end
		else
			begin
			////////////////////////////////////////////////////
			// Register the accumulated force
			////////////////////////////////////////////////////
			if(cur_particle_id == in_particle_id)
				begin
				cur_particle_id <= cur_particle_id;
				end
			else
				begin
				cur_particle_id <= in_particle_id;			// update the particle id
				end
			
			////////////////////////////////////////////////////
			// Assign the accumulated output forces
			////////////////////////////////////////////////////
			// When the particle id changes, assign the valid output register
			out_particle_id <= cur_particle_id;
			out_particle_acc_force_x <= acc_value_out_x;
			out_particle_acc_force_y <= acc_value_out_y;
			out_particle_acc_force_z <= acc_value_out_z;
			if(cur_particle_id != in_particle_id)
				begin
				out_acc_force_valid <= 1'b1;
				end
			else
				begin
				out_acc_force_valid <= 1'b0;
				end
				
			end
		end
		
	// Acc_Value_X
	FP_ADD
	#(
		.DATA_WIDTH(DATA_WIDTH)
	)
	FP_ACC_X (
		.clk(clk),
		.clr(rst),
		.ena(acc_enable),
		.ax(partial_force_x_in_wire),
		.ay(acc_force_x_in_wire),
		.result(acc_value_out_x)
	);
	
	// Acc_Value_Y
	FP_ADD
	#(
		.DATA_WIDTH(DATA_WIDTH)
	)
	FP_ACC_Y (
		.clk(clk),
		.clr(rst),
		.ena(acc_enable),
		.ax(partial_force_y_in_wire),
		.ay(acc_force_y_in_wire),
		.result(acc_value_out_y)
	);
	
	// Acc_Value_Z
	FP_ADD
	#(
		.DATA_WIDTH(DATA_WIDTH)
	)
	FP_ACC_Z (
		.clk(clk),
		.clr(rst),
		.ena(acc_enable),
		.ax(partial_force_z_in_wire),
		.ay(acc_force_z_in_wire),
		.result(acc_value_out_z)
	);
		
endmodule