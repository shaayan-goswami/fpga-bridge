//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.2 (win64) Build 6299465 Fri Nov 14 19:35:11 GMT 2025
//Date        : Thu Oct 22 14:36:01 2026
//Host        : pc running 64-bit major release  (build 9200)
//Command     : generate_target mb_system_wrapper.bd
//Design      : mb_system_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module mb_system_wrapper
   (GPIO_0_tri_o,
    UART_0_rxd,
    UART_0_txd,
    reset,
    sys_clock);
  output [3:0]GPIO_0_tri_o;
  input UART_0_rxd;
  output UART_0_txd;
  input reset;
  input sys_clock;

  wire [3:0]GPIO_0_tri_o;
  wire UART_0_rxd;
  wire UART_0_txd;
  wire reset;
  wire sys_clock;

  mb_system mb_system_i
       (.GPIO_0_tri_o(GPIO_0_tri_o),
        .UART_0_rxd(UART_0_rxd),
        .UART_0_txd(UART_0_txd),
        .reset(reset),
        .sys_clock(sys_clock));
endmodule
