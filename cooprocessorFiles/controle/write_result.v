module write_result(
	input clk, 
	input [17:0] instruction_addr,
	input convolution_done,
	input [31:0] ram_data,
	input [7:0]new_data,
	output memory_acc,
	output reg done, 
	output reg WRITE_ENABLE, 
	output reg [31:0] data_in,
	output reg[15:0]phy_addr
);

reg[2:0]count;
reg[1:0]offset;
reg [7:0] buf_pixel;
assign memory_acc = (count != 0) | convolution_done;

reg delay;
assign true_done = !delay & convolution_done;

always @(posedge clk) begin
	
	delay <= convolution_done;
	
	case (count)
		0: begin
			if (true_done) begin
				offset <= instruction_addr[1:0];
				phy_addr <= instruction_addr[17:2];
				buf_pixel <= new_data;
				WRITE_ENABLE <= 0;
				count <= 1;
			end
		end

		1: begin
			count <= 2;
		end

		2: begin
			case (offset)
				0: data_in <= {ram_data[31:8], buf_pixel};
				1: data_in <= {ram_data[31:16], buf_pixel, ram_data[7:0]};
				2: data_in <= {ram_data[31:24], buf_pixel, ram_data[15:0]};
				3: data_in <= {buf_pixel, ram_data[23:0]};
			endcase
			count <= 3;
		end

		3: begin
			WRITE_ENABLE <= 1;
			count <= 4;
		end

		4: begin
			WRITE_ENABLE <= 0;
			done <= 1;
			count <= 0;
		end
	endcase
end



endmodule