`timescale 1ns / 100ps
`default_nettype none

`include "ili9341_defines.sv"
`include "spi_types.sv"
`include "ft6206_defines.sv"

/*
Display controller for the ili9341 chip on Adafruit's breakout baord.
Based on logic from: https://github.com/adafruit/Adafruit_ILI9341

*/

module ili9341_display_controller(
  clk, rst, ena, display_rstb, enable_test_pattern,
  interface_mode,
  spi_csb, spi_clk, spi_mosi, spi_miso, data_commandb,
  vsync, hsync,
  touch,
  vram_rd_addr, vram_rd_data
);

parameter CLK_HZ = 12_000_000; // aka ticks per second
parameter DISPLAY_WIDTH = 240;
localparam N_X = $clog2(DISPLAY_WIDTH);
parameter DISPLAY_HEIGHT = 320;
localparam N_Y = $clog2(DISPLAY_HEIGHT);
parameter VRAM_L = DISPLAY_HEIGHT*DISPLAY_WIDTH;
parameter CFG_CMD_DELAY = CLK_HZ*150/1000; // wait 150ms after certain configuration commands
parameter ROM_LENGTH=125; // Set this based on the output of generate_memories.py

input wire clk, rst, ena, enable_test_pattern;
output logic display_rstb; // Need a separate value because the display has an opposite reset polarity.
always_comb display_rstb = ~rst; // Fix the active low reset

// SPI Interface
output logic spi_csb, spi_clk, spi_mosi;
input wire spi_miso;

// Sets the mode (many parallel and serial options, see page 10 of the datasheet).
output logic [3:0] interface_mode;
always_comb interface_mode = 4'b1110; // Standard SPI 8-bit mode is 4'b1110.

output logic data_commandb; // Set to 1 to send data, 0 to send commands. Read as Data/Command_Bar

output logic vsync; // Should combinationally be high for one clock cycle when drawing the last pixel (239,319)
output logic hsync; // Should combinationally be high for one clock cycle when drawing the last pixel of any row (x = 239).

input touch_t touch;
// input ILI9341_color_t vram_rd_data;
input wire [15:0] vram_rd_data;
output logic [$clog2(VRAM_L)-1:0] vram_rd_addr;

// SPI Controller that talks to the ILI9341 chip
spi_transaction_t spi_mode;
wire i_ready;
logic i_valid;
logic [15:0] i_data;
logic o_ready;
wire o_valid;
wire [23:0] o_data;
wire [4:0] spi_bit_counter;
spi_controller SPI0(
    .clk(clk), .rst(rst), 
    .sclk(spi_clk), .csb(spi_csb), .mosi(spi_mosi), .miso(spi_miso),
    .spi_mode(spi_mode), .i_ready(i_ready), .i_valid(i_valid), .i_data(i_data),
    .o_ready(o_ready), .o_valid(o_valid), .o_data(o_data),
    .bit_counter(spi_bit_counter)
);

// ROM that stores the configuration sequence the display needs
wire [7:0] rom_data;
logic [$clog2(ROM_LENGTH)-1:0] rom_addr;
block_rom #(.INIT("memories/ili9341_init.memh"), .W(8), .L(ROM_LENGTH)) ILI9341_INIT_ROM (
  .clk(clk), .addr(rom_addr), .data(rom_data)
);

// Main FSM
enum logic [2:0] {
  S_INIT = 0,
  S_INCREMENT_PIXEL = 1,
  S_START_FRAME = 2,
  S_TX_PIXEL_DATA_START = 3,
  S_TX_PIXEL_DATA_BUSY = 4,
  S_WAIT_FOR_SPI = 5,
  S_ERROR //very useful for debugging
} state, state_after_wait;

// Configuration FSM
enum logic [2:0] {
  S_CFG_GET_DATA_SIZE = 0,
  S_CFG_GET_CMD = 1,
  S_CFG_SEND_CMD = 2,
  S_CFG_GET_DATA = 3,
  S_CFG_SEND_DATA = 4,
  S_CFG_SPI_WAIT = 5,
  S_CFG_MEM_WAIT = 6,
  S_CFG_DONE
} cfg_state, cfg_state_after_wait;

ILI9341_color_t pixel_color;
logic [N_X-1:0] pixel_x;
logic [N_Y-1:0] pixel_y;

ILI9341_register_t current_command;

// Comb. outputs
/* Note - it's pretty critical that you keep always_comb blocks small and separate.
   there's a weird order of operations that can mess up your synthesis or simulation.  
*/

always_comb case(state)
  // When starting a frame, set input valid high
  S_START_FRAME, S_TX_PIXEL_DATA_START : i_valid = 1;
  // When initializing and sending command and data, set input valid high
  S_INIT : begin
    case(cfg_state)
      S_CFG_SEND_CMD, S_CFG_SEND_DATA: i_valid = 1;
      default: i_valid = 0;
    endcase
  end
  default: i_valid = 0;
endcase

// When starting a frame, set our current command to RAM write
always_comb case (state) 
  S_START_FRAME : current_command = RAMWR;
  default : current_command = NOP;
endcase

always_comb case(state)
  // Draw from rom data
  S_INIT: i_data = {8'd0, rom_data};
  // Send current command
  S_START_FRAME: i_data = {8'd0, current_command};
  default: i_data = vram_rd_data_valid ? vram_rd_data : pixel_color;
endcase


always_comb case (state)
  // Setting write mode when starting a frame
  S_INIT, S_START_FRAME: spi_mode = WRITE_8;
  default : spi_mode = WRITE_16;
endcase

always_comb begin
  // Tells fsm when we're at the last pixel of each row and column respectively
  hsync = pixel_x == (DISPLAY_WIDTH-1);
  vsync = hsync & (pixel_y == (DISPLAY_HEIGHT-1));
end

logic vram_rd_data_valid;
always_comb begin  : display_color_logic
  if(enable_test_pattern) begin
    vram_rd_addr = 0;
    vram_rd_data_valid = 0;
    // Modify this section to have a different test pattern!
    // Draw a white border around every 16x16 area
    if ((pixel_x[4:0] == 5'd16) | (pixel_y[4:0] == 5'd16)) begin
      pixel_color = WHITE;
    end
    else begin
      case({pixel_x[4], pixel_y[4]})
        2'b00: pixel_color = RED;
        2'b01: pixel_color = GREEN;
        2'b10: pixel_color = BLUE;
        2'b11: pixel_color = BLACK;
      endcase
    end
  end else begin
    // Read the current color from video RAM.
    vram_rd_addr = pixel_y*DISPLAY_WIDTH + {8'd0, pixel_x};
    // If the pixel region is currently being touched, draw white so we can see a "cursor."
    if(touch.valid & 
      (touch.x[N_X-1:2] == pixel_x[N_X-1:2]) &
      (touch.y[N_Y-1:2] == pixel_y[N_Y-1:2])) begin
      pixel_color = WHITE;
      vram_rd_data_valid = 0;
    end else begin
      pixel_color = BLUE;
      vram_rd_data_valid = 1;
    end
  end
end

logic [$clog2(CFG_CMD_DELAY):0] cfg_delay_counter;
logic [7:0] cfg_bytes_remaining;

// Reads from ROM through SPI controller and increments pixel position data
always_ff @(posedge clk) begin : main_fsm
  // Reset state to initialize and config state to get size data
  if(rst) begin
    state <= S_INIT;
    cfg_state <= S_CFG_GET_DATA_SIZE;
    cfg_state_after_wait <= S_CFG_GET_DATA_SIZE;
    cfg_delay_counter <= 0;
    state_after_wait <= S_INIT;
    pixel_x <= 0;
    pixel_y <= 0;
    rom_addr <= 0;
    data_commandb <= 1;
  end
  else if(ena) begin
    // Multiplexer for state variable
    case (state)
      // Initialization process
      S_INIT: begin
        case (cfg_state)
          // Get the size of the data in the rom for each address
          S_CFG_GET_DATA_SIZE : begin
            cfg_state_after_wait <= S_CFG_GET_CMD;
            cfg_state <= S_CFG_MEM_WAIT;
            rom_addr <= rom_addr + 1;
            case(rom_data) 
              // Initialize delay counter
              8'hFF: begin
                cfg_bytes_remaining <= 0;
                cfg_delay_counter <= CFG_CMD_DELAY;
              end
              // Reset delay counter
              8'h00: begin
                cfg_bytes_remaining <= 0;
                cfg_delay_counter <= 0;
                cfg_state <= S_CFG_DONE;
              end
              default: begin
                cfg_bytes_remaining <= rom_data;
                cfg_delay_counter <= 0;
              end
            endcase
          end
          // Tell cfg to wait then send the command once command is fetched
          S_CFG_GET_CMD: begin
            cfg_state_after_wait <= S_CFG_SEND_CMD;
            cfg_state <= S_CFG_MEM_WAIT;
          end
          // Set the commands to wait and fetch data from SPI controller
          S_CFG_SEND_CMD : begin
            data_commandb <= 0;
            if(rom_data == 0) begin
              cfg_state <= S_CFG_DONE;
            end else begin
              cfg_state <= S_CFG_SPI_WAIT;
              cfg_state_after_wait <= S_CFG_GET_DATA;
            end
          end
          // If there is still rom data to be fetched, wait for SPI and then fetch that data
          S_CFG_GET_DATA: begin
            data_commandb <= 1;
            rom_addr <= rom_addr + 1;
            if(cfg_bytes_remaining > 0) begin
              cfg_state_after_wait <= S_CFG_SEND_DATA;
              cfg_state <= S_CFG_MEM_WAIT;
              cfg_bytes_remaining <= cfg_bytes_remaining - 1;
            end else begin
              cfg_state_after_wait <= S_CFG_GET_DATA_SIZE;
              cfg_state <= S_CFG_MEM_WAIT;
            end
          end
          // Set commands to send data through SPI
          S_CFG_SEND_DATA: begin
            cfg_state_after_wait <= S_CFG_GET_DATA;
            cfg_state <= S_CFG_SPI_WAIT;
          end
          // Begin drawing the frame by sending pixel data
          S_CFG_DONE : begin
            state <= S_START_FRAME; // S_TX_PIXEL_DATA_START; //TODO@(avinash)
          end
          S_CFG_SPI_WAIT : begin
            if(cfg_delay_counter > 0) cfg_delay_counter <= cfg_delay_counter-1;
            else if (i_ready) begin
               cfg_state <= cfg_state_after_wait;
               cfg_delay_counter <= 0;
               data_commandb <= 1;
            end
          end
          S_CFG_MEM_WAIT : begin
            // If you had a memory with larger or unknown latency you would put checks in this state to wait till the data was ready.
            cfg_state <= cfg_state_after_wait;
          end
          default: cfg_state <= S_CFG_DONE;
        endcase
      end
      // Wait for spi input to be ready
      S_WAIT_FOR_SPI: begin
        if(i_ready) begin
          state <= state_after_wait;
        end
      end
      // Set commands to wait for SPI and then send pixel data
      S_START_FRAME: begin
        data_commandb <= 0;
        state <= S_WAIT_FOR_SPI;
        state_after_wait <= S_TX_PIXEL_DATA_START;
      end
      // Set commands to wait fro SPI and then increment the pixel position value
      S_TX_PIXEL_DATA_START: begin
        data_commandb <= 1;
        state_after_wait <= S_INCREMENT_PIXEL;
        state <= S_WAIT_FOR_SPI;
      end
      // Wait for SPI input to be ready before incrementing pixel position
      S_TX_PIXEL_DATA_BUSY: begin
        if(i_ready) state <= S_INCREMENT_PIXEL;
      end
      // Incremement pixel position
      S_INCREMENT_PIXEL: begin
        state <= S_TX_PIXEL_DATA_START;
        if(pixel_x < (DISPLAY_WIDTH-1)) begin
          pixel_x <= pixel_x + 1;
        end else begin
          pixel_x <= 0;
          if (pixel_y < (DISPLAY_HEIGHT-1)) begin
            pixel_y <= pixel_y + 1;
          end else begin
            pixel_y <= 0;
            state <= S_START_FRAME;
          end
        end
      end
      default: begin
        state <= S_ERROR;
        pixel_y <= -1;
        pixel_x <= -1;
      end
    endcase
  end
end

endmodule