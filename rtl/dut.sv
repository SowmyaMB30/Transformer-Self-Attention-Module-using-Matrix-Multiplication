module MyDesign (
    input wire clk,
    input wire reset_n,
    input wire dut_valid,
    output wire dut_ready,
    
    // SRAM interfaces
    output wire dut__tb__sram_input_write_enable,
    output wire [15:0] dut__tb__sram_input_write_address,
    output wire [31:0] dut__tb__sram_input_write_data,
    output wire [15:0] dut__tb__sram_input_read_address,
    input wire [31:0] tb__dut__sram_input_read_data,
    
    output wire dut__tb__sram_weight_write_enable,
    output wire [15:0] dut__tb__sram_weight_write_address,
    output wire [31:0] dut__tb__sram_weight_write_data,
    output wire [15:0] dut__tb__sram_weight_read_address,
    input wire [31:0] tb__dut__sram_weight_read_data,
    
    output wire dut__tb__sram_result_write_enable,
    output wire [15:0] dut__tb__sram_result_write_address,
    output wire [31:0] dut__tb__sram_result_write_data,
    output wire [15:0] dut__tb__sram_result_read_address,
    input wire [31:0] tb__dut__sram_result_read_data,
    
    output wire dut__tb__sram_scratchpad_write_enable,
    output wire [15:0] dut__tb__sram_scratchpad_write_address,
    output wire [31:0] dut__tb__sram_scratchpad_write_data,
    output wire [15:0] dut__tb__sram_scratchpad_read_address,
    input wire [31:0] tb__dut__sram_scratchpad_read_data
);

    // Define states using one-hot encoding for better synthesis
    localparam IDLE = 5'd0;
    localparam READ_DIM = 5'd1;
    localparam SETUP = 5'd2;
    localparam WAIT_DATA = 5'd3;
    localparam CALC = 5'd4;
    localparam S_INIT = 5'd5;
    localparam S_CALC = 5'd6;
    localparam S_WRITE = 5'd7;
    localparam Z_INIT = 5'd8;
    localparam Z_CALC = 5'd9;
    localparam Z_WRITE = 5'd10;
    localparam DONE = 5'd11;
    
    reg [4:0] current_state, next_state;
    
    // Matrix parameters and counters
    reg ready_reg;
    reg write_enable;
    reg [15:0] input_rows, input_cols;
    reg [15:0] weight_rows, weight_cols;
    reg [15:0] row_counter, col_counter, k_counter;
    reg [31:0] acc_sum;
    reg [15:0] read_addr_input;
    reg [15:0] read_addr_weight;
    reg [15:0] read_addr_result;
    reg [15:0] write_addr_result;
    reg [31:0] write_data_result;
    
    // Matrix type selection (Q, K, V)
    reg [1:0] matrix_type;  // 0 for Q, 1 for K, 2 for V
    reg [15:0] q_result_size;  // Size of Q results
    reg [15:0] k_result_size;  // Size of K results
    reg [15:0] v_result_size;  // Size of V results
    reg [15:0] s_result_size;  // Size of S results
    
    // Memory for Q, K, V, S values - ensure fixed size for synthesis
    reg [31:0] q_values [0:15][0:15];  // Max 16x16 matrix
    reg [31:0] k_values [0:15][0:15];  // Max 16x16 matrix
    reg [31:0] v_values [0:15][0:15];  // Max 16x16 matrix
    reg [31:0] s_values [0:15][0:15];  // Max 16x16 matrix
    
    // S and Z matrix calculation
    reg [15:0] s_row, s_col, s_k;
    reg [15:0] z_row, z_col, z_k;
    
    // Sequential logic
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            current_state <= IDLE;
            ready_reg <= 1'b1;
            write_enable <= 1'b0;
            row_counter <= 16'b0;
            col_counter <= 16'b0;
            k_counter <= 16'b0;
            acc_sum <= 32'b0;
            read_addr_input <= 16'b0;
            read_addr_weight <= 16'b0;
            read_addr_result <= 16'b0;
            write_addr_result <= 16'b0;
            write_data_result <= 32'b0;
            input_rows <= 16'b0;
            input_cols <= 16'b0;
            weight_rows <= 16'b0;
            weight_cols <= 16'b0;
            matrix_type <= 2'b0;
            q_result_size <= 16'b0;
            k_result_size <= 16'b0;
            v_result_size <= 16'b0;
            s_result_size <= 16'b0;
            s_row <= 16'b0;
            s_col <= 16'b0;
            s_k <= 16'b0;
            z_row <= 16'b0;
            z_col <= 16'b0;
            z_k <= 16'b0;
        end else begin
            current_state <= next_state;
            
            case (current_state)
                IDLE: begin
                    if (dut_valid) begin
                        ready_reg <= 1'b0;
                        read_addr_input <= 16'b0;
                        read_addr_weight <= 16'b0;
                        read_addr_result <= 16'b0;
                        row_counter <= 16'b0;
                        col_counter <= 16'b0;
                        k_counter <= 16'b0;
                        acc_sum <= 32'b0;
                        write_enable <= 1'b0;
                        matrix_type <= 2'b0;  // Start with Q matrix
                    end else begin
                        ready_reg <= 1'b1;
                    end
                end

                READ_DIM: begin
                    input_rows <= tb__dut__sram_input_read_data[31:16];
                    input_cols <= tb__dut__sram_input_read_data[15:0];
                    weight_rows <= tb__dut__sram_weight_read_data[31:16];
                    weight_cols <= tb__dut__sram_weight_read_data[15:0];
                    row_counter <= 16'b0;
                    col_counter <= 16'b0;
                    k_counter <= 16'b0;
                    acc_sum <= 32'b0;
                    q_result_size <= 16'b0;
                    k_result_size <= 16'b0;
                    v_result_size <= 16'b0;
                    s_result_size <= 16'b0;
                end

                SETUP: begin
                    // Calculate memory addresses for matrix computation
                    read_addr_input <= 16'h001 + k_counter + (row_counter * input_cols);
                    
                    case (matrix_type)
                        2'b00: begin  // Q weights
                            read_addr_weight <= 16'h001 + k_counter + (col_counter * weight_rows);
                        end
                        
                        2'b01: begin  // K weights
                            read_addr_weight <= 16'h001 + (weight_rows * weight_cols) + 
                                              k_counter + (col_counter * weight_rows);
                        end
                        
                        2'b10: begin  // V weights
                            read_addr_weight <= 16'h001 + (2 * weight_rows * weight_cols) + 
                                              k_counter + (col_counter * weight_rows);
                        end
                        default: begin
                            read_addr_weight <= 16'b0;
                        end
                    endcase
                    
                    write_enable <= 1'b0;
                end
                
                WAIT_DATA: begin
                    // Wait for SRAM read latency
                end

                CALC: begin
                    reg [31:0] product;
                    
                    // Calculate current product
                    product = tb__dut__sram_input_read_data * tb__dut__sram_weight_read_data;
                    
                    // Accumulate product
                    if (k_counter == 16'b0) begin
                        acc_sum <= product;
                    end else begin
                        acc_sum <= acc_sum + product;
                    end

                    // When done with all products for this cell
                    if (k_counter == input_cols - 16'b1) begin
                        // Write result to memory
                        write_enable <= 1'b1;
                        
                        // Final accumulated value
                        write_data_result <= (k_counter > 16'b0) ? acc_sum + product : product;
                        
                        // Store results based on matrix type
                        case (matrix_type)
                            2'b00: begin  // Q matrix
                                write_addr_result <= row_counter * weight_cols + col_counter;
                                // Store in local memory for S calculation
                                q_values[row_counter][col_counter] <= (k_counter > 16'b0) ? 
                                                                    acc_sum + product : product;
                            end
                            
                            2'b01: begin  // K matrix
                                write_addr_result <= q_result_size + (row_counter * weight_cols + col_counter);
                                // Store in local memory for S calculation
                                k_values[row_counter][col_counter] <= (k_counter > 16'b0) ? 
                                                                    acc_sum + product : product;
                            end
                            
                            2'b10: begin  // V matrix
                                write_addr_result <= q_result_size + k_result_size + 
                                                   (row_counter * weight_cols + col_counter);
                                // Store in local memory for Z calculation
                                v_values[row_counter][col_counter] <= (k_counter > 16'b0) ? 
                                                                    acc_sum + product : product;
                            end
                            default: begin
                                write_addr_result <= 16'b0;
                            end
                        endcase
                        
                        // Reset for next cell
                        acc_sum <= 32'b0;
                        k_counter <= 16'b0;
                        
                        // Move to next cell in output matrix
                        if (col_counter == weight_cols - 16'b1) begin
                            col_counter <= 16'b0;
                            
                            if (row_counter == input_rows - 16'b1) begin
                                // Finished current matrix
                                row_counter <= 16'b0;
                                
                                case (matrix_type)
                                    2'b00: begin  // Finished Q matrix
                                        matrix_type <= 2'b01;
                                        q_result_size <= input_rows * weight_cols;
                                    end
                                    
                                    2'b01: begin  // Finished K matrix
                                        matrix_type <= 2'b10;
                                        k_result_size <= input_rows * weight_cols;
                                    end
                                    
                                    2'b10: begin  // Finished V matrix, move to S
                                        v_result_size <= input_rows * weight_cols;
                                    end
                                    default: begin
                                        matrix_type <= 2'b00;
                                    end
                                endcase
                            end else begin
                                // Move to next row
                                row_counter <= row_counter + 16'b1;
                            end
                        end else begin
                            // Move to next column
                            col_counter <= col_counter + 16'b1;
                        end
                    end else begin
                        // Next k
                        k_counter <= k_counter + 16'b1;
                        write_enable <= 1'b0;
                    end
                end
                
                // S matrix calculation (Q * K^T)
                S_INIT: begin
                    s_row <= 16'b0;
                    s_col <= 16'b0;
                    s_k <= 16'b0;
                    acc_sum <= 32'b0;
                    write_enable <= 1'b0;
                end
                
                S_CALC: begin
                    // Compute dot product element for S matrix
                    reg [31:0] s_product;
                    
                    // First element or accumulation
                    if (s_k == 16'b0) begin
                        acc_sum <= q_values[s_row][s_k] * k_values[s_col][s_k];
                    end else begin
                        acc_sum <= acc_sum + (q_values[s_row][s_k] * k_values[s_col][s_k]);
                    end
                    
                    // Increment k or finished dot product
                    if (s_k == weight_cols - 16'b1) begin
                        // Completed dot product
                        s_k <= 16'b0;
                    end else begin
                        s_k <= s_k + 16'b1;
                    end
                end
                
                S_WRITE: begin
                    // Store S result
                    s_values[s_row][s_col] <= acc_sum;
                    
                    // Write to memory
                    write_enable <= 1'b1;
                    write_data_result <= acc_sum;
                    write_addr_result <= q_result_size + k_result_size + v_result_size + 
                                       (s_row * input_rows + s_col);
                    
                    // Advance to next element
                    if (s_col == input_rows - 16'b1) begin
                        s_col <= 16'b0;
                        if (s_row == input_rows - 16'b1) begin
                            // S matrix complete
                            s_result_size <= input_rows * input_rows;
                        end else begin
                            s_row <= s_row + 16'b1;
                        end
                    end else begin
                        s_col <= s_col + 16'b1;
                    end
                end
                
                // Z matrix calculation (S * V)
                Z_INIT: begin
                    z_row <= 16'b0;
                    z_col <= 16'b0;
                    z_k <= 16'b0;
                    acc_sum <= 32'b0;
                    write_enable <= 1'b0;
                end
                
                Z_CALC: begin
                    // Compute dot product element for Z matrix
                    
                    // First element or accumulation
                    if (z_k == 16'b0) begin
                        acc_sum <= s_values[z_row][z_k] * v_values[z_k][z_col];
                    end else begin
                        acc_sum <= acc_sum + (s_values[z_row][z_k] * v_values[z_k][z_col]);
                    end
                    
                    // Increment k or finished dot product
                    if (z_k == input_rows - 16'b1) begin
                        // Completed dot product
                        z_k <= 16'b0;
                    end else begin
                        z_k <= z_k + 16'b1;
                    end
                end
                
                Z_WRITE: begin
                    // Write to memory
                    write_enable <= 1'b1;
                    write_data_result <= acc_sum;
                    write_addr_result <= q_result_size + k_result_size + v_result_size + 
                                       s_result_size + (z_row * weight_cols + z_col);
                    
                    // Advance to next element
                    if (z_col == weight_cols - 16'b1) begin
                        z_col <= 16'b0;
                        if (z_row == input_rows - 16'b1) begin
                            // Z matrix complete
                        end else begin
                            z_row <= z_row + 16'b1;
                        end
                    end else begin
                        z_col <= z_col + 16'b1;
                    end
                end
                
                DONE: begin
                    ready_reg <= 1'b1;
                    write_enable <= 1'b0;
                    
                    if (!dut_valid) begin
                        row_counter <= 16'b0;
                        col_counter <= 16'b0;
                        k_counter <= 16'b0;
                        acc_sum <= 32'b0;
                        read_addr_input <= 16'b0;
                        read_addr_weight <= 16'b0;
                        read_addr_result <= 16'b0;
                        matrix_type <= 2'b0;
                    end
                end
                
                default: begin
                    // Default case to avoid latches
                end
            endcase
        end
    end

    // Next state logic (combinational)
    always @(*) begin
        next_state = current_state;
        
        case (current_state)
            IDLE: 
                if (dut_valid) next_state = READ_DIM;
            
            READ_DIM:
                next_state = SETUP;
            
            SETUP:
                next_state = WAIT_DATA;
                
            WAIT_DATA:
                next_state = CALC;
                
            CALC: begin
                if ((row_counter == input_rows - 16'b1) && 
                    (col_counter == weight_cols - 16'b1) && 
                    (k_counter == input_cols - 16'b1)) begin
                    
                    case (matrix_type)
                        2'b00, 2'b01: 
                            next_state = SETUP;  // Continue with K or V
                        2'b10: 
                            next_state = S_INIT;  // Move to S after V
                        default:
                            next_state = IDLE;
                    endcase
                end else if (k_counter == input_cols - 16'b1) begin
                    next_state = SETUP; // Next matrix cell
                end else begin
                    next_state = SETUP; // Continue current cell
                end
            end
            
            // S matrix calculation
            S_INIT:
                next_state = S_CALC;
                
            S_CALC:
                if (s_k == weight_cols - 16'b1) next_state = S_WRITE;
                else next_state = S_CALC;
                
            S_WRITE:
                if (s_row == input_rows - 16'b1 && s_col == input_rows - 16'b1)
                    next_state = Z_INIT;
                else
                    next_state = S_CALC;
                
            // Z matrix calculation
            Z_INIT:
                next_state = Z_CALC;
                
            Z_CALC:
                if (z_k == input_rows - 16'b1) next_state = Z_WRITE;
                else next_state = Z_CALC;
                
            Z_WRITE:
                if (z_row == input_rows - 16'b1 && z_col == weight_cols - 16'b1)
                    next_state = DONE;
                else
                    next_state = Z_CALC;
                
            DONE:
                if (!dut_valid) next_state = IDLE;
                
            default:
                next_state = IDLE;
        endcase
    end

    // Output assignments
    assign dut_ready = ready_reg;
    assign dut__tb__sram_input_read_address = read_addr_input;
    assign dut__tb__sram_weight_read_address = read_addr_weight;
    assign dut__tb__sram_result_read_address = read_addr_result;
    
    assign dut__tb__sram_result_write_enable = write_enable;
    assign dut__tb__sram_result_write_address = write_addr_result;
    assign dut__tb__sram_result_write_data = write_data_result;

    // Tie off unused outputs
    assign dut__tb__sram_input_write_enable = 1'b0;
    assign dut__tb__sram_input_write_address = 16'b0;
    assign dut__tb__sram_input_write_data = 32'b0;
    assign dut__tb__sram_weight_write_enable = 1'b0;
    assign dut__tb__sram_weight_write_address = 16'b0;
    assign dut__tb__sram_weight_write_data = 32'b0;
    assign dut__tb__sram_scratchpad_write_enable = 1'b0;
    assign dut__tb__sram_scratchpad_write_address = 16'b0;
    assign dut__tb__sram_scratchpad_write_data = 32'b0;
    assign dut__tb__sram_scratchpad_read_address = 16'b0;

endmodule