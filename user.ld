ENTRY(_start)

/* PML4 index 64 (0x0000200000000000) -- deliberately NOT under PML4
   index 0. Every process's PML4[0] is a direct COPY of the kernel's own
   p4_table[0], which boot.asm created with flags PRESENT|WRITABLE only
   (no PAGE_USER) since it was only ever meant for kernel-internal
   low-identity-map use. PML4-level permissions gate everything beneath
   them, so ANY address under index 0 -- the first 512GiB of the address
   space -- is permanently inaccessible to user mode no matter what the
   PDPT/PD/PT entries beneath it say (confirmed via a direct page-table
   walk: the final PTE was correctly PRESENT|WRITABLE|USER with no NX,
   yet execution still faulted, because the copied PML4[0] entry itself
   lacks PAGE_USER). Index 64 is untouched by any shared entry, so
   paging_map_into's table_entry creates it fresh with proper
   PAGE_USER flags via its own default_flags. */
SECTIONS
{
    /* + SIZEOF_HEADERS so the ELF header and the program header table
       fall INSIDE the first PT_LOAD segment and therefore have a
       virtual address at run time. Without it the headers sit at file
       offset 64 while the segment starts at 0x1000, no loaded segment
       covers them, and the kernel has no address to put in AT_PHDR --
       which is the only way a static executable can find its own PT_TLS
       template. Costs one page of address space and nothing else. */
    . = 0x200000000000 + SIZEOF_HEADERS;

    /* musl's crt1 entry does `lea _DYNAMIC(%rip),%rsi` against a WEAK
       undefined symbol. Undefined means 0, and a PC-relative
       displacement from 0x200000000000 down to 0 does not fit in the
       32 bits the relocation has -- so the link fails with "relocation
       truncated to fit" before anything runs.
       Defining it HERE, inside the image, makes the displacement
       small. Nothing reads the value: crt1.c's _start_c takes only the
       stack pointer and ignores the second argument, which is where
       this lands. PROVIDE so a program that defines its own wins. */
    PROVIDE(_DYNAMIC = .);

    .text ALIGN(4K) : { *(.text .text.*) }
    .rodata ALIGN(4K) : { *(.rodata .rodata.*) }
    .data ALIGN(4K) : { *(.data .data.*) }

    /* .tdata and .tbss MUST be named here, and in this order. Left as
       orphan sections the linker placed both at the SAME address --
       .tbss at 0x...3e60 and .tdata at 0x...3e60 -- so every
       thread-local in .tdata overlapped one in .tbss and the offsets
       the compiler emitted bore no relation to where the initialised
       bytes actually were. The symptom was a __thread int initialised
       to 0x5a5a reading as 0.

       .tdata comes first because PT_TLS's file-backed part is its
       leading bytes: p_offset points at .tdata and p_filesz covers only
       it, with .tbss making up the rest of p_memsz as zero. */
    .tdata ALIGN(4K) : { *(.tdata .tdata.*) }
    .tbss : { *(.tbss .tbss.*) *(.tcommon) }

    .bss ALIGN(4K) : { *(COMMON) *(.bss .bss.*) }
}
