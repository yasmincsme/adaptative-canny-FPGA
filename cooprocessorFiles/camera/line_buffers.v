module line_buffers(
	input clk,
	input [31:0] datain, 
	input [8:0] address, 
	input save_data,
	input next_matrix, 
	input new_line,
	input [1:0] size, 
	output reg [199:0] matrix
);


reg [4095:0] BUFFER0, BUFFER1, BUFFER2, BUFFER3, BUFFER4;

always @(*) begin

	case (size)
		2'd0: begin // 2x2
			matrix = {8'b0, 8'b0, 8'b0, BUFFER0[8+:8], BUFFER0[0+:8],
						 8'b0, 8'b0, 8'b0, BUFFER1[8+:8], BUFFER1[0+:8]};
		end

		2'd1: begin // 3x3
			matrix = {8'b0, 8'b0, BUFFER0[8+:8], BUFFER0[0+:8], BUFFER0[4088+:8],
						 8'b0, 8'b0, BUFFER1[8+:8], BUFFER1[0+:8], BUFFER1[4088+:8],
						 8'b0, 8'b0, BUFFER2[8+:8], BUFFER2[0+:8], BUFFER2[4088+:8]};
		end

		2'd3: begin // 5x5
			matrix = {BUFFER0[16+:8],  BUFFER0[8+:8],  BUFFER0[0+:8],  BUFFER0[4088+:8],  BUFFER0[4080+:8],
						 BUFFER1[16+:8],  BUFFER1[8+:8],  BUFFER1[0+:8],  BUFFER1[4088+:8],  BUFFER1[4080+:8],
						 BUFFER2[16+:8],  BUFFER2[8+:8],  BUFFER2[0+:8],  BUFFER2[4088+:8],  BUFFER2[4080+:8],
						 BUFFER3[16+:8],  BUFFER3[8+:8],  BUFFER3[0+:8],  BUFFER3[4088+:8],  BUFFER3[4080+:8],
						 BUFFER4[16+:8],  BUFFER4[8+:8],  BUFFER4[0+:8],  BUFFER4[4088+:8],  BUFFER4[4080+:8]};
		end
		
		default:
			matrix = 0;
	endcase

end

wire [2:0] instruction;
assign instruction = {save_data,new_line,next_matrix};

always @(posedge clk) begin

	case (instruction) 
		3'b100: begin
			BUFFER0[address[8:2] * 32 +:32] <= datain;
		end
	
		3'b010: begin
			BUFFER1 <= BUFFER0;
			BUFFER2 <= BUFFER1;
			BUFFER3 <= BUFFER2;
			BUFFER4 <= BUFFER3;		
		end
		
		3'b001: begin
			BUFFER0 <= {BUFFER0[7:0],BUFFER0[4095:8]};
			BUFFER1 <= {BUFFER1[7:0],BUFFER1[4095:8]};
			BUFFER2 <= {BUFFER2[7:0],BUFFER2[4095:8]};
			BUFFER3 <= {BUFFER3[7:0],BUFFER3[4095:8]};
			BUFFER4 <= {BUFFER4[7:0],BUFFER4[4095:8]};		
		end
		
		default: begin
			BUFFER0 <= BUFFER0;
			BUFFER1 <= BUFFER1;
			BUFFER2 <= BUFFER2;
			BUFFER3 <= BUFFER3;
			BUFFER4 <= BUFFER4;
		end
	endcase
end


endmodule