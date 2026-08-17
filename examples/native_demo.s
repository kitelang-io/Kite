	.text
	.globl _square
	.p2align 2
_square:
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	sub sp, sp, #16
	str x0, [x29, #-8]
	ldr x0, [x29, #-8]
	str x0, [sp, #-16]!
	ldr x0, [x29, #-8]
	mov x1, x0
	ldr x0, [sp], #16
	mul x0, x0, x1
Lepi_square:
	add sp, sp, #16
	ldp x29, x30, [sp], #16
	ret

	.globl _triangular
	.p2align 2
_triangular:
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	sub sp, sp, #16
	str x0, [x29, #-8]
	ldr x0, [x29, #-8]
	str x0, [sp, #-16]!
	ldr x0, [x29, #-8]
	str x0, [sp, #-16]!
	movz x0, #1
	mov x1, x0
	ldr x0, [sp], #16
	add x0, x0, x1
	mov x1, x0
	ldr x0, [sp], #16
	mul x0, x0, x1
	str x0, [sp, #-16]!
	movz x0, #2
	mov x1, x0
	ldr x0, [sp], #16
	sdiv x0, x0, x1
	b Lepi_triangular
Lepi_triangular:
	add sp, sp, #16
	ldp x29, x30, [sp], #16
	ret

	.globl _main
	.p2align 2
_main:
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	sub sp, sp, #16
	movz x0, #6
	str x0, [sp, #-16]!
	ldr x0, [sp], #16
	bl _square
	str x0, [x29, #-8]
	movz x0, #10
	str x0, [sp, #-16]!
	ldr x0, [sp], #16
	bl _triangular
	str x0, [x29, #-16]
	ldr x0, [x29, #-16]
	str x0, [sp, #-16]!
	ldr x0, [x29, #-8]
	mov x1, x0
	ldr x0, [sp], #16
	sub x0, x0, x1
	str x0, [sp, #-16]!
	movz x0, #5
	mov x1, x0
	ldr x0, [sp], #16
	add x0, x0, x1
	b Lepi_main
Lepi_main:
	add sp, sp, #16
	ldp x29, x30, [sp], #16
	ret

	.section __TEXT,__cstring,cstring_literals
Lfmt_println:
	.asciz "%ld\n"
Lfmt_print:
	.asciz "%ld"
