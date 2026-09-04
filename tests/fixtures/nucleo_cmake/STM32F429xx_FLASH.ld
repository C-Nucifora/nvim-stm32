/*
******************************************************************************
**

**  File        : LinkerScript.ld
**
**  Author		: STM32CubeMX
**
**  Abstract    : Linker script for STM32F429ZITx series
**                2048Kbytes FLASH and 256Kbytes RAM
**
**                Set heap size, stack size and stack location according
**                to application requirements.
**
**                Set memory bank area and size if external memory is used.
**
**  Target      : STMicroelectronics STM32
**
**  Distribution: The file is distributed “as is,” without any warranty
**                of any kind.
*/

ENTRY(Reset_Handler)

MEMORY
{
RAM (xrw)      : ORIGIN = 0x20000000, LENGTH = 192K
CCMRAM (xrw)   : ORIGIN = 0x10000000, LENGTH = 64K
FLASH (rx)     : ORIGIN = 0x8000000, LENGTH = 2048K
}
