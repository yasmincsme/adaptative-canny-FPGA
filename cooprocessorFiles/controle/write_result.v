module write_result(
	input clk, 
	input [17:0] instruction_addr,
	input convolution_done,
	input [31:0] ram_data,
	input [7:0]new_data,
	output reg memory_acc,
	output reg done, 
	output reg WRITE_ENABLE, 
	output reg [31:0] data_in,
	output wire [15:0] phy_addr
);

reg [3:0]state, next_state;
wire [1:0]offset;
reg delay, true_done;

assign offset = instruction_addr[1:0];
assign phy_addr = instruction_addr[17:2];


always @(*) begin
	true_done = !delay & convolution_done;
	case (offset)
		0: data_in = {ram_data[31:8], new_data};
		1: data_in = {ram_data[31:16], new_data, ram_data[7:0]};
		2: data_in = {ram_data[31:24], new_data, ram_data[15:0]};
		3: data_in = {new_data, ram_data[23:0]};
	endcase
	case (state) 
		0: begin
			if (true_done) begin
				next_state = 1;
				memory_acc = 1;
			end else begin
				next_state = 0;
				memory_acc = 0;
			end
			WRITE_ENABLE = 0;
			done = 0;
		end
		1: begin
			next_state = 2;
			WRITE_ENABLE = 0;
			done = 0;
			memory_acc = 1;
		end
		
		2: begin
			next_state = 3;
			WRITE_ENABLE = 1;
			done = 0;
			memory_acc = 1;
		end
		
		3: begin
			next_state = 0;
			WRITE_ENABLE = 0;
			done = 1;
			memory_acc = 1;
		end
		/*
		4: begin
			next_state = 5;
			WRITE_ENABLE = 0;
			done = 0;
			memory_acc = 1;
		end
		
		5: begin
			next_state = 6;
			WRITE_ENABLE = 0;
			done = 0;
			memory_acc = 1;
		end
		
		6: begin
			next_state = 7;
			WRITE_ENABLE = 0;
			done = 0;
			memory_acc = 1;
		end
		
		7: begin
			next_state = 8;
			done = 0;
			WRITE_ENABLE = 0;
			memory_acc = 1;
		end

		8: begin
			next_state = 9;
			done = 0;
			WRITE_ENABLE = 0;
			memory_acc = 1;
		end
		
		9: begin
			next_state = 10;
			done = 0;
			WRITE_ENABLE = 0;
			memory_acc = 1;
		end
		
		10: begin
			next_state = 0;
			done = 1;
			WRITE_ENABLE = 0;
			memory_acc = 1;
		end
		*/
		default: begin
			next_state = 0;
			WRITE_ENABLE = 0;
			done = 0;
			memory_acc = 0;
		end
	endcase
end


always @(posedge clk) begin
	delay <= convolution_done;
	state <= next_state;
end



endmodule