/* Linker script for a minimal binary.
 *
 * This script is intended to generate a very small and compact binary.
 *
 * When segments are loaded into memory their memory offset must match their
 * file offset modulo page size. To generate a compact binary we make sections
 * which have data in the binary follow each other with exactly one page size
 * space between them. This way they require no padding between each other
 * within the file. The page boundary is needed because segments with different
 * permissions must be located in different pages. Analogously, we align the
 * section following .bss such that it has the same offset as .bss module page
 * size.
 */

PHDRS
{
  READONLY PT_LOAD FILEHDR PHDRS;
  EXEC PT_LOAD;
  READWRITE PT_LOAD;
}

SECTIONS
{
  . = 0x200000 + SIZEOF_HEADERS;
  .rodata : { *(.rodata*) } : READONLY
  . += 0x10000;
  .text : { *(.text*) } : EXEC
  . += 0x10000;
  .got : { *(.got*) } : READWRITE
  . += 0x10000;
  .bss : { *(.bss*) } : READWRITE
  . += 0x10000 - SIZEOF(.bss) % 0x10000;
  .data : { *(.data*) } : READWRITE
}
