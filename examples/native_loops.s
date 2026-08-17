	.text
	.globl _gcd
	.p2align 2
_gcd:
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	sub sp, sp, #48
	str x0, [x29, #-8]
	str x1, [x29, #-16]
	ldr x0, [x29, #-8]
	str x0, [x29, #-24]
	ldr x0, [x29, #-16]
	str x0, [x29, #-32]
Lwhile_1:
	ldr x0, [x29, #-32]
	str x0, [sp, #-16]!
	movz x0, #0
	mov x1, x0
	ldr x0, [sp], #16
	cmp x0, x1
	cset x0, ne
	cbz x0, Lwend_1
	ldr x0, [x29, #-32]
	str x0, [x29, #-40]
	ldr x0, [x29, #-24]
	str x0, [sp, #-16]!
	ldr x0, [x29, #-32]
	mov x1, x0
	ldr x0, [sp], #16
	sdiv x2, x0, x1
	msub x0, x2, x1, x0
	str x0, [x29, #-32]
	ldr x0, [x29, #-40]
	str x0, [x29, #-24]
	b Lwhile_1
Lwend_1:
	ldr x0, [x29, #-24]
	b Lepi_gcd
Lepi_gcd:
	add sp, sp, #48
	ldp x29, x30, [sp], #16
	ret

	.globl _fib
	.p2align 2
_fib:
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	sub sp, sp, #48
	str x0, [x29, #-8]
	movz x0, #0
	str x0, [x29, #-16]
	movz x0, #1
	str x0, [x29, #-24]
	movz x0, #0
	str x0, [x29, #-32]
Lwhile_2:
	ldr x0, [x29, #-32]
	str x0, [sp, #-16]!
	ldr x0, [x29, #-8]
	mov x1, x0
	ldr x0, [sp], #16
	cmp x0, x1
	cset x0, lt
	cbz x0, Lwend_2
	ldr x0, [x29, #-16]
	str x0, [sp, #-16]!
	ldr x0, [x29, #-24]
	mov x1, x0
	ldr x0, [sp], #16
	add x0, x0, x1
	str x0, [x29, #-40]
	ldr x0, [x29, #-24]
	str x0, [x29, #-16]
	ldr x0, [x29, #-40]
	str x0, [x29, #-24]
	ldr x0, [x29, #-32]
	str x0, [sp, #-16]!
	movz x0, #1
	mov x1, x0
	ldr x0, [sp], #16
	add x0, x0, x1
	str x0, [x29, #-32]
	b Lwhile_2
Lwend_2:
	ldr x0, [x29, #-16]
	b Lepi_fib
Lepi_fib:
	add sp, sp, #48
	ldp x29, x30, [sp], #16
	ret

	.globl _main
	.p2align 2
_main:
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	movz x0, #48
	str x0, [sp, #-16]!
	movz x0, #36
	str x0, [sp, #-16]!
	ldr x1, [sp], #16
	ldr x0, [sp], #16
	bl _gcd
	str x0, [sp, #-16]!
	movz x0, #10
	str x0, [sp, #-16]!
	ldr x0, [sp], #16
	bl _fib
	mov x1, x0
	ldr x0, [sp], #16
	add x0, x0, x1
	b Lepi_main
Lepi_main:
	ldp x29, x30, [sp], #16
	ret

	.section __TEXT,__cstring,cstring_literals
Lfmt_println:
	.asciz "%ld\n"
Lfmt_print:
	.asciz "%ld"
