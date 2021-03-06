/*
 *  Copyright (C) 1991,1992  Linus Torvalds
 *
 * entry_32.S contains the system-call and low-level fault and trap handling routines.
 *
 * Stack layout while running C code:
 *	ptrace needs to have all registers on the stack.
 *	If the order here is changed, it needs to be
 *	updated in fork.c:copy_process(), signal.c:do_signal(),
 *	ptrace.c and ptrace.h
 *
 *	 0(%esp) - %ebx
 *	 4(%esp) - %ecx
 *	 8(%esp) - %edx
 *	 C(%esp) - %esi
 *	10(%esp) - %edi
 *	14(%esp) - %ebp
 *	18(%esp) - %eax
 *	1C(%esp) - %ds
 *	20(%esp) - %es
 *	24(%esp) - %fs
 *	28(%esp) - %gs		saved iff !CONFIG_X86_32_LAZY_GS
 *	2C(%esp) - orig_eax
 *	30(%esp) - %eip
 *	34(%esp) - %cs
 *	38(%esp) - %eflags
 *	3C(%esp) - %oldesp
 *	40(%esp) - %oldss
 */

#include <linux/linkage.h>
#include <linux/err.h>
#include <asm/thread_info.h>
#include <asm/irqflags.h>
#include <asm/errno.h>
#include <asm/segment.h>
#include <asm/smp.h>
#include <asm/page_types.h>
#include <asm/percpu.h>
#include <asm/processor-flags.h>
#include <asm/ftrace.h>
#include <asm/irq_vectors.h>
#include <asm/cpufeatures.h>
#include <asm/asm.h>
#include <asm/smap.h>
#include <asm/nospec-branch.h>

#include "calling.h"

	.section .entry.text, "ax"

/*
 * We use macros for low-level operations which need to be overridden
 * for paravirtualization.  The following will never clobber any registers:
 *   INTERRUPT_RETURN (aka. "iret")
 *   GET_CR0_INTO_EAX (aka. "movl %cr0, %eax")
 *   ENABLE_INTERRUPTS_SYSEXIT (aka "sti; sysexit").
 *
 * For DISABLE_INTERRUPTS/ENABLE_INTERRUPTS (aka "cli"/"sti"), you must
 * specify what registers can be overwritten (CLBR_NONE, CLBR_EAX/EDX/ECX/ANY).
 * Allowing a register to be clobbered can shrink the paravirt replacement
 * enough to patch inline, increasing performance.
 */

#ifdef CONFIG_PREEMPT
# define preempt_stop(clobbers)	DISABLE_INTERRUPTS(clobbers); TRACE_IRQS_OFF
#else
# define preempt_stop(clobbers)
# define resume_kernel		restore_all
#endif

.macro TRACE_IRQS_IRET
#ifdef CONFIG_TRACE_IRQFLAGS
	testl	$X86_EFLAGS_IF, PT_EFLAGS(%esp)     # interrupts off?
	jz	1f
	TRACE_IRQS_ON
1:
#endif
.endm

/*
 * User gs save/restore
 *
 * %gs is used for userland TLS and kernel only uses it for stack
 * canary which is required to be at %gs:20 by gcc.  Read the comment
 * at the top of stackprotector.h for more info.
 *
 * Local labels 98 and 99 are used.
 */
#ifdef CONFIG_X86_32_LAZY_GS

 /* unfortunately push/pop can't be no-op */
.macro PUSH_GS
	pushl	$0
.endm
.macro POP_GS pop=0
	addl	$(4 + \pop), %esp
.endm
.macro POP_GS_EX
.endm

 /* all the rest are no-op */
.macro PTGS_TO_GS
.endm
.macro PTGS_TO_GS_EX
.endm
.macro GS_TO_REG reg
.endm
.macro REG_TO_PTGS reg
.endm
.macro SET_KERNEL_GS reg
.endm

#else	/* CONFIG_X86_32_LAZY_GS */

.macro PUSH_GS
	pushl	%gs
.endm

.macro POP_GS pop=0
98:	popl	%gs
  .if \pop <> 0
	add	$\pop, %esp
  .endif
.endm
.macro POP_GS_EX
.pushsection .fixup, "ax"
99:	movl	$0, (%esp)
	jmp	98b
.popsection
	_ASM_EXTABLE(98b, 99b)
.endm

.macro PTGS_TO_GS
98:	mov	PT_GS(%esp), %gs
.endm
.macro PTGS_TO_GS_EX
.pushsection .fixup, "ax"
99:	movl	$0, PT_GS(%esp)
	jmp	98b
.popsection
	_ASM_EXTABLE(98b, 99b)
.endm

.macro GS_TO_REG reg
	movl	%gs, \reg
.endm
.macro REG_TO_PTGS reg
	movl	\reg, PT_GS(%esp)
.endm
.macro SET_KERNEL_GS reg

#ifdef CONFIG_CC_STACKPROTECTOR
	movl	$(__KERNEL_STACK_CANARY), \reg
#elif defined(CONFIG_PAX_MEMORY_UDEREF)
	movl $(__USER_DS), \reg
#else
	xorl \reg, \reg
#endif

	movl	\reg, %gs
.endm

#endif /* CONFIG_X86_32_LAZY_GS */

#ifdef CONFIG_PAX_KERNEXEC
ENTRY(pax_enter_kernel)
#ifdef CONFIG_PARAVIRT
	pushl %eax
	pushl %ecx
	call *PARA_INDIRECT(pv_cpu_ops+PV_CPU_read_cr0)
	mov %eax, %esi
#else
	mov %cr0, %esi
#endif
	bts $X86_CR0_WP_BIT, %esi
	jnc 1f
	mov %cs, %esi
	cmp $__KERNEL_CS, %esi
	jz 3f
	ljmp $__KERNEL_CS, $3f
1:	ljmp $__KERNEXEC_KERNEL_CS, $2f
2:
#ifdef CONFIG_PARAVIRT
	mov %esi, %eax
	call *PARA_INDIRECT(pv_cpu_ops+PV_CPU_write_cr0)
#else
	mov %esi, %cr0
#endif
3:
#ifdef CONFIG_PARAVIRT
	popl %ecx
	popl %eax
#endif
	ret
ENDPROC(pax_enter_kernel)

ENTRY(pax_exit_kernel)
#ifdef CONFIG_PARAVIRT
	pushl %eax
	pushl %ecx
#endif
	mov %cs, %esi
	cmp $__KERNEXEC_KERNEL_CS, %esi
	jnz 2f
#ifdef CONFIG_PARAVIRT
	call *PARA_INDIRECT(pv_cpu_ops+PV_CPU_read_cr0);
	mov %eax, %esi
#else
	mov %cr0, %esi
#endif
	btr $X86_CR0_WP_BIT, %esi
	ljmp $__KERNEL_CS, $1f
1:
#ifdef CONFIG_PARAVIRT
	mov %esi, %eax
	call *PARA_INDIRECT(pv_cpu_ops+PV_CPU_write_cr0);
#else
	mov %esi, %cr0
#endif
2:
#ifdef CONFIG_PARAVIRT
	popl %ecx
	popl %eax
#endif
	ret
ENDPROC(pax_exit_kernel)
#endif

#ifdef CONFIG_PAX_MEMORY_STACKLEAK
/*
 * ebp: thread_info
 */
ENTRY(pax_erase_kstack)
	pushl %edi
	pushl %ecx
	pushl %eax
	pushl %ebp

	GET_THREAD_INFO(%ebp)
	mov TI_lowest_stack(%ebp), %edi
	mov $-0xBEEF, %eax
	std

1:	mov %edi, %ecx
	and $THREAD_SIZE_asm - 1, %ecx
	shr $2, %ecx
	repne scasl
	jecxz 2f

	cmp $2*16, %ecx
	jc 2f

	mov $2*16, %ecx
	repe scasl
	jecxz 2f
	jne 1b

2:	cld
	or $2*4, %edi
	mov %esp, %ecx
	sub %edi, %ecx

	cmp $THREAD_SIZE_asm, %ecx
	jb 3f
	ud2
3:

	shr $2, %ecx
	rep stosl

	mov TI_task_thread_sp0(%ebp), %edi
	sub $128, %edi
	mov %edi, TI_lowest_stack(%ebp)

	popl %ebp
	popl %eax
	popl %ecx
	popl %edi
	ret
ENDPROC(pax_erase_kstack)
#endif

.macro __SAVE_ALL pt_regs_ax, _DS
	cld
	PUSH_GS
	pushl	%fs
	pushl	%es
	pushl	%ds
	pushl	\pt_regs_ax
	pushl	%ebp
	pushl	%edi
	pushl	%esi
	pushl	%edx
	pushl	%ecx
	pushl	%ebx
	movl	$\_DS, %edx
	movl	%edx, %ds
	movl	%edx, %es
	movl	$(__KERNEL_PERCPU), %edx
	movl	%edx, %fs
	SET_KERNEL_GS %edx
.endm

.macro SAVE_ALL pt_regs_ax=%eax
#if defined(CONFIG_PAX_KERNEXEC) || defined(CONFIG_PAX_PAGEEXEC) || defined(CONFIG_PAX_SEGMEXEC) || defined(CONFIG_PAX_MEMORY_UDEREF)
	__SAVE_ALL \pt_regs_ax, __KERNEL_DS
	pax_enter_kernel
#else
	__SAVE_ALL \pt_regs_ax, __USER_DS
#endif
.endm

.macro RESTORE_INT_REGS
	popl	%ebx
	popl	%ecx
	popl	%edx
	popl	%esi
	popl	%edi
	popl	%ebp
	popl	%eax
.endm

.macro RESTORE_REGS pop=0
	RESTORE_INT_REGS
1:	popl	%ds
2:	popl	%es
3:	popl	%fs
	POP_GS \pop
.pushsection .fixup, "ax"
4:	movl	$0, (%esp)
	jmp	1b
5:	movl	$0, (%esp)
	jmp	2b
6:	movl	$0, (%esp)
	jmp	3b
.popsection
	_ASM_EXTABLE(1b, 4b)
	_ASM_EXTABLE(2b, 5b)
	_ASM_EXTABLE(3b, 6b)
	POP_GS_EX
.endm

ENTRY(ret_from_fork)
	pushl	%eax
	call	schedule_tail
	GET_THREAD_INFO(%ebp)
	popl	%eax
	pushl	$0x0202				# Reset kernel eflags
	popfl

	/* When we fork, we trace the syscall return in the child, too. */
	movl    %esp, %eax
	call    syscall_return_slowpath
	jmp     restore_all
ENDPROC(ret_from_fork)

ENTRY(ret_from_kernel_thread)
	pushl	%eax
	call	schedule_tail
	GET_THREAD_INFO(%ebp)
	popl	%eax
	pushl	$0x0202				# Reset kernel eflags
	popfl
	movl	PT_EBP(%esp), %eax
	movl	PT_EBX(%esp), %edx
	CALL_NOSPEC edx, kthreadd
	movl	$0, PT_EAX(%esp)

	/*
	 * Kernel threads return to userspace as if returning from a syscall.
	 * We should check whether anything actually uses this path and, if so,
	 * consider switching it over to ret_from_fork.
	 */
	movl    %esp, %eax
	call    syscall_return_slowpath
	jmp     restore_all
ENDPROC(ret_from_kernel_thread)

/*
 * Return to user mode is not as complex as all this looks,
 * but we want the default path for a system call return to
 * go as quickly as possible which is why some of this is
 * less clear than it otherwise should be.
 */

	# userspace resumption stub bypassing syscall exit tracing
	ALIGN
ret_from_exception:
	preempt_stop(CLBR_ANY)
ret_from_intr:
	GET_THREAD_INFO(%ebp)
#ifdef CONFIG_VM86
	movl	PT_EFLAGS(%esp), %eax		# mix EFLAGS and CS
	movb	PT_CS(%esp), %al
	andl	$(X86_EFLAGS_VM | SEGMENT_RPL_MASK), %eax
#else
	/*
	 * We can be coming here from child spawned by kernel_thread().
	 */
	movl	PT_CS(%esp), %eax
	andl	$SEGMENT_RPL_MASK, %eax
#endif
	cmpl	$USER_RPL, %eax

#ifdef CONFIG_PAX_KERNEXEC
	jae	resume_userspace

	pax_exit_kernel
	jmp	resume_kernel
#else
	jb	resume_kernel			# not returning to v8086 or userspace
#endif

ENTRY(resume_userspace)
	DISABLE_INTERRUPTS(CLBR_ANY)
	TRACE_IRQS_OFF
	movl	%esp, %eax
	call	prepare_exit_to_usermode
	jmp	.Lsyscall_32_done
ENDPROC(ret_from_exception)

#ifdef CONFIG_PREEMPT
ENTRY(resume_kernel)
	DISABLE_INTERRUPTS(CLBR_ANY)
need_resched:
	cmpl	$0, PER_CPU_VAR(__preempt_count)
	jnz	restore_all
	testl	$X86_EFLAGS_IF, PT_EFLAGS(%esp)	# interrupts off (exception path) ?
	jz	restore_all
	call	preempt_schedule_irq
	jmp	need_resched
ENDPROC(resume_kernel)
#endif

	# SYSENTER  call handler stub
ENTRY(entry_SYSENTER_32)
	movl	TSS_sysenter_sp0(%esp), %esp
sysenter_past_esp:
	pushl	$__USER_DS		/* pt_regs->ss */
	pushl	%ebp			/* pt_regs->sp (stashed in bp) */
	pushfl				/* pt_regs->flags (except IF = 0) */
	orl	$X86_EFLAGS_IF, (%esp)	/* Fix IF */
	pushl	$__USER_CS		/* pt_regs->cs */
	pushl	$0			/* pt_regs->ip = 0 (placeholder) */
	pushl	%eax			/* pt_regs->orig_ax */
	SAVE_ALL pt_regs_ax=$-ENOSYS	/* save rest */

#ifdef CONFIG_PAX_RANDKSTACK
	pax_erase_kstack
#endif

	/*
	 * User mode is traced as though IRQs are on, and SYSENTER
	 * turned them off.
	 */
	TRACE_IRQS_OFF

	movl	%esp, %eax
	call	do_fast_syscall_32
	/* XEN PV guests always use IRET path */
	ALTERNATIVE "testl %eax, %eax; jz .Lsyscall_32_done", \
		    "jmp .Lsyscall_32_done", X86_FEATURE_XENPV

#ifdef CONFIG_PAX_RANDKSTACK
	movl	%esp, %eax
	call	pax_randomize_kstack
#endif

	pax_erase_kstack

/* Opportunistic SYSEXIT */
	TRACE_IRQS_ON			/* User mode traces as IRQs on. */
	movl	PT_EIP(%esp), %edx	/* pt_regs->ip */
	movl	PT_OLDESP(%esp), %ecx	/* pt_regs->sp */
1:	mov	PT_FS(%esp), %fs
2:	mov	PT_DS(%esp), %ds
3:	mov	PT_ES(%esp), %es
	PTGS_TO_GS
	popl	%ebx			/* pt_regs->bx */
	addl	$2*4, %esp		/* skip pt_regs->cx and pt_regs->dx */
	popl	%esi			/* pt_regs->si */
	popl	%edi			/* pt_regs->di */
	popl	%ebp			/* pt_regs->bp */

	INVLUTLB

	popl	%eax			/* pt_regs->ax */

	/*
	 * Return back to the vDSO, which will pop ecx and edx.
	 * Don't bother with DS and ES (they already contain __USER_DS).
	 */
	ENABLE_INTERRUPTS_SYSEXIT

.pushsection .fixup, "ax"
4:	movl	$0, PT_FS(%esp)
	jmp	1b
5:	movl	$0, PT_DS(%esp)
	jmp	1b
6:	movl	$0, PT_ES(%esp)
	jmp	1b
.popsection
	_ASM_EXTABLE(1b, 4b)
	_ASM_EXTABLE(2b, 5b)
	_ASM_EXTABLE(3b, 6b)
	PTGS_TO_GS_EX
ENDPROC(entry_SYSENTER_32)

	# system call handler stub
ENTRY(entry_INT80_32)
	ASM_CLAC
	pushl	%eax			/* pt_regs->orig_ax */
	SAVE_ALL pt_regs_ax=$-ENOSYS	/* save rest */

#ifdef CONFIG_PAX_RANDKSTACK
	pax_erase_kstack
#endif

	/*
	 * User mode is traced as though IRQs are on.  Unlike the 64-bit
	 * case, INT80 is a trap gate on 32-bit kernels, so interrupts
	 * are already on (unless user code is messing around with iopl).
	 */

	movl	%esp, %eax
	call	do_syscall_32_irqs_on
.Lsyscall_32_done:

#ifdef CONFIG_PAX_RANDKSTACK
	movl	%esp, %eax
	call	pax_randomize_kstack
#endif

	pax_erase_kstack

	INVLUTLB

restore_all:
	TRACE_IRQS_IRET
.Lrestore_all_notrace:
#ifdef CONFIG_X86_ESPFIX32
	movl	PT_EFLAGS(%esp), %eax		# mix EFLAGS, SS and CS
	/*
	 * Warning: PT_OLDSS(%esp) contains the wrong/random values if we
	 * are returning to the kernel.
	 * See comments in process.c:copy_thread() for details.
	 */
	movb	PT_OLDSS(%esp), %ah
	movb	PT_CS(%esp), %al
	andl	$(X86_EFLAGS_VM | (SEGMENT_TI_MASK << 8) | SEGMENT_RPL_MASK), %eax
	cmpl	$((SEGMENT_LDT << 8) | USER_RPL), %eax
	je ldt_ss				# returning to user-space with LDT SS
#endif
restore_nocheck:
	RESTORE_REGS 4				# skip orig_eax/error_code
irq_return:
	INTERRUPT_RETURN
.section .fixup, "ax"
ENTRY(iret_exc	)
	pushl	$0				# no error code
	pushl	$do_iret_error
	jmp	error_code
.previous
	_ASM_EXTABLE(irq_return, iret_exc)

#ifdef CONFIG_X86_ESPFIX32
ldt_ss:
#ifdef CONFIG_PARAVIRT
	/*
	 * The kernel can't run on a non-flat stack if paravirt mode
	 * is active.  Rather than try to fixup the high bits of
	 * ESP, bypass this code entirely.  This may break DOSemu
	 * and/or Wine support in a paravirt VM, although the option
	 * is still available to implement the setting of the high
	 * 16-bits in the INTERRUPT_RETURN paravirt-op.
	 */
	cmpl	$0, pv_info+PARAVIRT_enabled
	jne	restore_nocheck
#endif

/*
 * Setup and switch to ESPFIX stack
 *
 * We're returning to userspace with a 16 bit stack. The CPU will not
 * restore the high word of ESP for us on executing iret... This is an
 * "official" bug of all the x86-compatible CPUs, which we can work
 * around to make dosemu and wine happy. We do this by preloading the
 * high word of ESP with the high word of the userspace ESP while
 * compensating for the offset by changing to the ESPFIX segment with
 * a base address that matches for the difference.
 */
#define GDT_ESPFIX_SS (GDT_ENTRY_ESPFIX_SS * 8)(%ebx)
	mov	%esp, %edx			/* load kernel esp */
	mov	PT_OLDESP(%esp), %eax		/* load userspace esp */
	mov	%dx, %ax			/* eax: new kernel esp */
	sub	%eax, %edx			/* offset (low word is 0) */
#ifdef CONFIG_SMP
	movl	PER_CPU_VAR(cpu_number), %ebx
	shll	$PAGE_SHIFT_asm, %ebx
	addl	$cpu_gdt_table, %ebx
#else
	movl	$cpu_gdt_table, %ebx
#endif
	shr	$16, %edx

#ifdef CONFIG_PAX_KERNEXEC
	mov	%cr0, %esi
	btr	$X86_CR0_WP_BIT, %esi
	mov	%esi, %cr0
#endif

	mov	%dl, 4 + GDT_ESPFIX_SS /* bits 16..23 */
	mov	%dh, 7 + GDT_ESPFIX_SS /* bits 24..31 */

#ifdef CONFIG_PAX_KERNEXEC
	bts	$X86_CR0_WP_BIT, %esi
	mov	%esi, %cr0
#endif

	pushl	$__ESPFIX_SS
	pushl	%eax				/* new kernel esp */
	/*
	 * Disable interrupts, but do not irqtrace this section: we
	 * will soon execute iret and the tracer was already set to
	 * the irqstate after the IRET:
	 */
	DISABLE_INTERRUPTS(CLBR_EAX)
	lss	(%esp), %esp			/* switch to espfix segment */
	jmp	restore_nocheck
#endif
ENDPROC(entry_INT80_32)

.macro FIXUP_ESPFIX_STACK
/*
 * Switch back for ESPFIX stack to the normal zerobased stack
 *
 * We can't call C functions using the ESPFIX stack. This code reads
 * the high word of the segment base from the GDT and swiches to the
 * normal stack and adjusts ESP with the matching offset.
 */
#ifdef CONFIG_X86_ESPFIX32
	/* fixup the stack */
#ifdef CONFIG_SMP
	movl	PER_CPU_VAR(cpu_number), %ebx
	shll	$PAGE_SHIFT_asm, %ebx
	addl	$cpu_gdt_table, %ebx
#else
	movl	$cpu_gdt_table, %ebx
#endif
	mov	4 + GDT_ESPFIX_SS, %al /* bits 16..23 */
	mov	7 + GDT_ESPFIX_SS, %ah /* bits 24..31 */
	shl	$16, %eax
	addl	%esp, %eax			/* the adjusted stack pointer */
	pushl	$__KERNEL_DS
	pushl	%eax
	lss	(%esp), %esp			/* switch to the normal stack segment */
#endif
.endm
.macro UNWIND_ESPFIX_STACK
#ifdef CONFIG_X86_ESPFIX32
	movl	%ss, %eax
	/* see if on espfix stack */
	cmpw	$__ESPFIX_SS, %ax
	jne	27f
	movl	$__KERNEL_DS, %eax
	movl	%eax, %ds
	movl	%eax, %es
	/* switch to normal stack */
	FIXUP_ESPFIX_STACK
27:
#endif
.endm

/*
 * Build the entry stubs with some assembler magic.
 * We pack 1 stub into every 8-byte block.
 */
	.align 8
ENTRY(irq_entries_start)
    vector=FIRST_EXTERNAL_VECTOR
    .rept (FIRST_SYSTEM_VECTOR - FIRST_EXTERNAL_VECTOR)
	pushl	$(~vector+0x80)			/* Note: always in signed byte range */
    vector=vector+1
	jmp	common_interrupt
	.align	8
    .endr
ENDPROC(irq_entries_start)

/*
 * the CPU automatically disables interrupts when executing an IRQ vector,
 * so IRQ-flags tracing has to follow that:
 */
	.p2align CONFIG_X86_L1_CACHE_SHIFT
common_interrupt:
	ASM_CLAC
	addl	$-0x80, (%esp)			/* Adjust vector into the [-256, -1] range */
	SAVE_ALL
	TRACE_IRQS_OFF
	movl	%esp, %eax
	call	do_IRQ
	jmp	ret_from_intr
ENDPROC(common_interrupt)

#define BUILD_INTERRUPT3(name, nr, fn)	\
ENTRY(name)				\
	ASM_CLAC;			\
	pushl	$~(nr);			\
	SAVE_ALL;			\
	TRACE_IRQS_OFF			\
	movl	%esp, %eax;		\
	call	fn;			\
	jmp	ret_from_intr;		\
ENDPROC(name)


#ifdef CONFIG_TRACING
# define TRACE_BUILD_INTERRUPT(name, nr)	BUILD_INTERRUPT3(trace_##name, nr, smp_trace_##name)
#else
# define TRACE_BUILD_INTERRUPT(name, nr)
#endif

#define BUILD_INTERRUPT(name, nr)		\
	BUILD_INTERRUPT3(name, nr, smp_##name);	\
	TRACE_BUILD_INTERRUPT(name, nr)

/* The include is where all of the SMP etc. interrupts come from */
#include <asm/entry_arch.h>

ENTRY(coprocessor_error)
	ASM_CLAC
	pushl	$0
	pushl	$do_coprocessor_error
	jmp	error_code
ENDPROC(coprocessor_error)

ENTRY(simd_coprocessor_error)
	ASM_CLAC
	pushl	$0
#ifdef CONFIG_X86_INVD_BUG
	/* AMD 486 bug: invd from userspace calls exception 19 instead of #GP */
	ALTERNATIVE "pushl	$do_general_protection",	\
		    "pushl	$do_simd_coprocessor_error",	\
		    X86_FEATURE_XMM
#else
	pushl	$do_simd_coprocessor_error
#endif
	jmp	error_code
ENDPROC(simd_coprocessor_error)

ENTRY(device_not_available)
	ASM_CLAC
	pushl	$-1				# mark this as an int
	pushl	$do_device_not_available
	jmp	error_code
ENDPROC(device_not_available)

#ifdef CONFIG_PARAVIRT
ENTRY(native_iret)
	iret
	_ASM_EXTABLE(native_iret, iret_exc)
ENDPROC(native_iret)

ENTRY(native_irq_enable_sysexit)
	sti
	sysexit
ENDPROC(native_irq_enable_sysexit)
#endif

ENTRY(overflow)
	ASM_CLAC
	pushl	$0
	pushl	$do_overflow
	jmp	error_code
ENDPROC(overflow)

ENTRY(bounds)
	ASM_CLAC
	pushl	$0
	pushl	$do_bounds
	jmp	error_code
ENDPROC(bounds)

ENTRY(invalid_op)
	ASM_CLAC
	pushl	$0
	pushl	$do_invalid_op
	jmp	error_code
ENDPROC(invalid_op)

ENTRY(coprocessor_segment_overrun)
	ASM_CLAC
	pushl	$0
	pushl	$do_coprocessor_segment_overrun
	jmp	error_code
ENDPROC(coprocessor_segment_overrun)

ENTRY(invalid_TSS)
	ASM_CLAC
	pushl	$do_invalid_TSS
	jmp	error_code
ENDPROC(invalid_TSS)

ENTRY(segment_not_present)
	ASM_CLAC
	pushl	$do_segment_not_present
	jmp	error_code
ENDPROC(segment_not_present)

ENTRY(stack_segment)
	ASM_CLAC
	pushl	$do_stack_segment
	jmp	error_code
ENDPROC(stack_segment)

ENTRY(alignment_check)
	ASM_CLAC
	pushl	$do_alignment_check
	jmp	error_code
ENDPROC(alignment_check)

ENTRY(divide_error)
	ASM_CLAC
	pushl	$0				# no error code
	pushl	$do_divide_error
	jmp	error_code
ENDPROC(divide_error)

#ifdef CONFIG_X86_MCE
ENTRY(machine_check)
	ASM_CLAC
	pushl	$0
	pushl	machine_check_vector
	jmp	error_code
ENDPROC(machine_check)
#endif

ENTRY(spurious_interrupt_bug)
	ASM_CLAC
	pushl	$0
	pushl	$do_spurious_interrupt_bug
	jmp	error_code
ENDPROC(spurious_interrupt_bug)

#ifdef CONFIG_PAX_REFCOUNT
ENTRY(refcount_error)
	ASM_CLAC
	pushl	$0
	pushl	$do_refcount_error
	jmp	error_code
ENDPROC(refcount_error)
#endif

#ifdef CONFIG_XEN
/*
 * Xen doesn't set %esp to be precisely what the normal SYSENTER
 * entry point expects, so fix it up before using the normal path.
 */
ENTRY(xen_sysenter_target)
	addl	$5*4, %esp			/* remove xen-provided frame */
	jmp	sysenter_past_esp

ENTRY(xen_hypervisor_callback)
	pushl	$-1				/* orig_ax = -1 => not a system call */
	SAVE_ALL
	TRACE_IRQS_OFF

	/*
	 * Check to see if we got the event in the critical
	 * region in xen_iret_direct, after we've reenabled
	 * events and checked for pending events.  This simulates
	 * iret instruction's behaviour where it delivers a
	 * pending interrupt when enabling interrupts:
	 */
	movl	PT_EIP(%esp), %eax
	cmpl	$xen_iret_start_crit, %eax
	jb	1f
	cmpl	$xen_iret_end_crit, %eax
	jae	1f

	jmp	xen_iret_crit_fixup

ENTRY(xen_do_upcall)
1:	mov	%esp, %eax
	call	xen_evtchn_do_upcall
#ifndef CONFIG_PREEMPT
	call	xen_maybe_preempt_hcall
#endif
	jmp	ret_from_intr
ENDPROC(xen_hypervisor_callback)

/*
 * Hypervisor uses this for application faults while it executes.
 * We get here for two reasons:
 *  1. Fault while reloading DS, ES, FS or GS
 *  2. Fault while executing IRET
 * Category 1 we fix up by reattempting the load, and zeroing the segment
 * register if the load fails.
 * Category 2 we fix up by jumping to do_iret_error. We cannot use the
 * normal Linux return path in this case because if we use the IRET hypercall
 * to pop the stack frame we end up in an infinite loop of failsafe callbacks.
 * We distinguish between categories by maintaining a status value in EAX.
 */
ENTRY(xen_failsafe_callback)
	pushl	%eax
	movl	$1, %eax
1:	mov	4(%esp), %ds
2:	mov	8(%esp), %es
3:	mov	12(%esp), %fs
4:	mov	16(%esp), %gs
	/* EAX == 0 => Category 1 (Bad segment)
	   EAX != 0 => Category 2 (Bad IRET) */
	testl	%eax, %eax
	popl	%eax
	lea	16(%esp), %esp
	jz	5f
	jmp	iret_exc
5:	pushl	$-1				/* orig_ax = -1 => not a system call */
	SAVE_ALL
	jmp	ret_from_exception

.section .fixup, "ax"
6:	xorl	%eax, %eax
	movl	%eax, 4(%esp)
	jmp	1b
7:	xorl	%eax, %eax
	movl	%eax, 8(%esp)
	jmp	2b
8:	xorl	%eax, %eax
	movl	%eax, 12(%esp)
	jmp	3b
9:	xorl	%eax, %eax
	movl	%eax, 16(%esp)
	jmp	4b
.previous
	_ASM_EXTABLE(1b, 6b)
	_ASM_EXTABLE(2b, 7b)
	_ASM_EXTABLE(3b, 8b)
	_ASM_EXTABLE(4b, 9b)
ENDPROC(xen_failsafe_callback)

BUILD_INTERRUPT3(xen_hvm_callback_vector, HYPERVISOR_CALLBACK_VECTOR,
		xen_evtchn_do_upcall)

#endif /* CONFIG_XEN */

#if IS_ENABLED(CONFIG_HYPERV)

BUILD_INTERRUPT3(hyperv_callback_vector, HYPERVISOR_CALLBACK_VECTOR,
	hyperv_vector_handler)

#endif /* CONFIG_HYPERV */

#ifdef CONFIG_FUNCTION_TRACER
#ifdef CONFIG_DYNAMIC_FTRACE

ENTRY(mcount)
	ret
ENDPROC(mcount)

ENTRY(ftrace_caller)
	pushl	%eax
	pushl	%ecx
	pushl	%edx
	pushl	$0				/* Pass NULL as regs pointer */
	movl	4*4(%esp), %eax
	movl	0x4(%ebp), %edx
	movl	function_trace_op, %ecx
	subl	$MCOUNT_INSN_SIZE, %eax

.globl ftrace_call
ftrace_call:
	call	ftrace_stub

	addl	$4, %esp			/* skip NULL pointer */
	popl	%edx
	popl	%ecx
	popl	%eax
ftrace_ret:
#ifdef CONFIG_FUNCTION_GRAPH_TRACER
.globl ftrace_graph_call
ftrace_graph_call:
	jmp	ftrace_stub
#endif

/* This is weak to keep gas from relaxing the jumps */
WEAK(ftrace_stub)
	ret
ENDPROC(ftrace_caller)

ENTRY(ftrace_regs_caller)
	pushf	/* push flags before compare (in cs location) */

	/*
	 * i386 does not save SS and ESP when coming from kernel.
	 * Instead, to get sp, &regs->sp is used (see ptrace.h).
	 * Unfortunately, that means eflags must be at the same location
	 * as the current return ip is. We move the return ip into the
	 * ip location, and move flags into the return ip location.
	 */
	pushl	4(%esp)				/* save return ip into ip slot */

	pushl	$0				/* Load 0 into orig_ax */
	pushl	%gs
	pushl	%fs
	pushl	%es
	pushl	%ds
	pushl	%eax
	pushl	%ebp
	pushl	%edi
	pushl	%esi
	pushl	%edx
	pushl	%ecx
	pushl	%ebx

	movl	13*4(%esp), %eax		/* Get the saved flags */
	movl	%eax, 14*4(%esp)		/* Move saved flags into regs->flags location */
						/* clobbering return ip */
	movl	$__KERNEL_CS, 13*4(%esp)

	movl	12*4(%esp), %eax		/* Load ip (1st parameter) */
	subl	$MCOUNT_INSN_SIZE, %eax		/* Adjust ip */
	movl	0x4(%ebp), %edx			/* Load parent ip (2nd parameter) */
	movl	function_trace_op, %ecx		/* Save ftrace_pos in 3rd parameter */
	pushl	%esp				/* Save pt_regs as 4th parameter */

GLOBAL(ftrace_regs_call)
	call	ftrace_stub

	addl	$4, %esp			/* Skip pt_regs */
	movl	14*4(%esp), %eax		/* Move flags back into cs */
	movl	%eax, 13*4(%esp)		/* Needed to keep addl	from modifying flags */
	movl	12*4(%esp), %eax		/* Get return ip from regs->ip */
	movl	%eax, 14*4(%esp)		/* Put return ip back for ret */

	popl	%ebx
	popl	%ecx
	popl	%edx
	popl	%esi
	popl	%edi
	popl	%ebp
	popl	%eax
	popl	%ds
	popl	%es
	popl	%fs
	popl	%gs
	addl	$8, %esp			/* Skip orig_ax and ip */
	popf					/* Pop flags at end (no addl to corrupt flags) */
	jmp	ftrace_ret

	popf
	jmp	ftrace_stub
#else /* ! CONFIG_DYNAMIC_FTRACE */

ENTRY(mcount)
	cmpl	$__PAGE_OFFSET, %esp
	jb	ftrace_stub			/* Paging not enabled yet? */

	cmpl	$ftrace_stub, ftrace_trace_function
	jnz	trace
#ifdef CONFIG_FUNCTION_GRAPH_TRACER
	cmpl	$ftrace_stub, ftrace_graph_return
	jnz	ftrace_graph_caller

	cmpl	$ftrace_graph_entry_stub, ftrace_graph_entry
	jnz	ftrace_graph_caller
#endif
.globl ftrace_stub
ftrace_stub:
	ret

	/* taken from glibc */
trace:
	pushl	%eax
	pushl	%ecx
	pushl	%edx
	movl	0xc(%esp), %eax
	movl	0x4(%ebp), %edx
	subl	$MCOUNT_INSN_SIZE, %eax

	movl    ftrace_trace_function, %ecx
	CALL_NOSPEC ecx, ftrace_stub

	popl	%edx
	popl	%ecx
	popl	%eax
	jmp	ftrace_stub
ENDPROC(mcount)
#endif /* CONFIG_DYNAMIC_FTRACE */
#endif /* CONFIG_FUNCTION_TRACER */

#ifdef CONFIG_FUNCTION_GRAPH_TRACER
ENTRY(ftrace_graph_caller)
	pushl	%eax
	pushl	%ecx
	pushl	%edx
	movl	0xc(%esp), %eax
	lea	0x4(%ebp), %edx
	movl	(%ebp), %ecx
	subl	$MCOUNT_INSN_SIZE, %eax
	call	prepare_ftrace_return
	popl	%edx
	popl	%ecx
	popl	%eax
	ret
ENDPROC(ftrace_graph_caller)

.globl return_to_handler
return_to_handler:
	pushl	%eax
	pushl	%edx
	movl	%ebp, %eax
	call	ftrace_return_to_handler
	movl	%eax, %ecx
	popl	%edx
	popl	%eax
	JMP_NOSPEC ecx
#endif

#ifdef CONFIG_TRACING
ENTRY(trace_page_fault)
	ASM_CLAC
	pushl	$trace_do_page_fault
	jmp	error_code
ENDPROC(trace_page_fault)
#endif

ENTRY(page_fault)
	ASM_CLAC
	pushl	$do_page_fault
	ALIGN
error_code:
	/* the function address is in %gs's slot on the stack */
	pushl	%fs
	pushl	%es
	pushl	%ds
	pushl	%eax
	pushl	%ebp
	pushl	%edi
	pushl	%esi
	pushl	%edx
	pushl	%ecx
	pushl	%ebx
	cld
	movl	$(__KERNEL_PERCPU), %ecx
	movl	%ecx, %fs
	UNWIND_ESPFIX_STACK
	GS_TO_REG %ecx
	movl	PT_GS(%esp), %edi		# get the function address
	movl	PT_ORIG_EAX(%esp), %edx		# get the error code
	movl	$-1, PT_ORIG_EAX(%esp)		# no syscall to restart
	REG_TO_PTGS %ecx
	SET_KERNEL_GS %ecx
	movl	$(__KERNEL_DS), %ecx
	movl	%ecx, %ds
	movl	%ecx, %es

	pax_enter_kernel

	TRACE_IRQS_OFF
	movl	%esp, %eax			# pt_regs pointer
	CALL_NOSPEC edi, do_page_fault
	jmp	ret_from_exception
ENDPROC(page_fault)

/*
 * Debug traps and NMI can happen at the one SYSENTER instruction
 * that sets up the real kernel stack. Check here, since we can't
 * allow the wrong stack to be used.
 *
 * "TSS_sysenter_sp0+12" is because the NMI/debug handler will have
 * already pushed 3 words if it hits on the sysenter instruction:
 * eflags, cs and eip.
 *
 * We just load the right stack, and push the three (known) values
 * by hand onto the new stack - while updating the return eip past
 * the instruction that would have done it for sysenter.
 */
.macro FIX_STACK offset ok label
	cmpw	$__KERNEL_CS, 4(%esp)
	jne	\ok
\label:
	movl	TSS_sysenter_sp0 + \offset(%esp), %esp
	pushfl
	pushl	$__KERNEL_CS
	pushl	$sysenter_past_esp
.endm

ENTRY(int1)
	ASM_CLAC
	pushl	$-1				# mark this as an int
	SAVE_ALL
	xorl	%edx, %edx			# error code 0
	movl	%esp, %eax			# pt_regs pointer

	/* Are we currently on the SYSENTER stack? */
	movl	PER_CPU_VAR(cpu_entry_area), %ecx
	addl	$CPU_ENTRY_AREA_entry_stack + SIZEOF_entry_stack, %ecx
	subl	%eax, %ecx	/* ecx = (end of entry_stack) - esp */
	cmpl	$SIZEOF_entry_stack, %ecx
	jb	.Ldebug_from_sysenter_stack

	TRACE_IRQS_OFF
	call	do_debug
	jmp	ret_from_exception

.Ldebug_from_sysenter_stack:
	/* We're on the SYSENTER stack.  Switch off. */
	movl	%esp, %ebx
	movl	PER_CPU_VAR(cpu_current_top_of_stack), %esp
	TRACE_IRQS_OFF
	call	do_debug
	movl	%ebx, %esp
	jmp	ret_from_exception
ENDPROC(int1)

/*
 * NMI is doubly nasty. It can happen _while_ we're handling
 * a debug fault, and the debug fault hasn't yet been able to
 * clear up the stack. So we first check whether we got  an
 * NMI on the sysenter entry path, but after that we need to
 * check whether we got an NMI on the debug path where the debug
 * fault happened on the sysenter path.
 */
ENTRY(nmi)
	ASM_CLAC
#ifdef CONFIG_X86_ESPFIX32
	pushl	%eax
	movl	%ss, %eax
	cmpw	$__ESPFIX_SS, %ax
	popl	%eax
	je	.Lnmi_espfix_stack
#endif

	pushl	%eax				# pt_regs->orig_ax
	SAVE_ALL
	xorl	%edx, %edx			# zero error code
	movl	%esp, %eax			# pt_regs pointer

	/* Are we currently on the SYSENTER stack? */
	movl	PER_CPU_VAR(cpu_entry_area), %ecx
	addl	$CPU_ENTRY_AREA_entry_stack + SIZEOF_entry_stack, %ecx
	subl	%eax, %ecx	/* ecx = (end of entry_stack) - esp */
	cmpl	$SIZEOF_entry_stack, %ecx
	jb	.Lnmi_from_sysenter_stack

	/* Not on SYSENTER stack. */
	call	do_nmi

	pax_exit_kernel

	jmp	.Lrestore_all_notrace

.Lnmi_from_sysenter_stack:
	/*
	 * We're on the SYSENTER stack.  Switch off.  No one (not even debug)
	 * is using the thread stack right now, so it's safe for us to use it.
	 */
	movl	%esp, %ebx
	movl	PER_CPU_VAR(cpu_current_top_of_stack), %esp
	call	do_nmi
	movl	%ebx, %esp

	pax_exit_kernel

	jmp	.Lrestore_all_notrace

#ifdef CONFIG_X86_ESPFIX32
.Lnmi_espfix_stack:
	/*
	 * create the pointer to lss back
	 */
	pushl	%ss
	pushl	%esp
	addl	$4, (%esp)
	/* copy the iret frame of 12 bytes */
	.rept 3
	pushl	16(%esp)
	.endr
	pushl	%eax
	SAVE_ALL
	FIXUP_ESPFIX_STACK			# %eax == %esp
	xorl	%edx, %edx			# zero error code
	call	do_nmi

	pax_exit_kernel

	RESTORE_REGS
	lss	12+4(%esp), %esp		# back to espfix stack
	jmp	irq_return
#endif
ENDPROC(nmi)

ENTRY(int3)
	ASM_CLAC
	pushl	$-1				# mark this as an int
	SAVE_ALL
	TRACE_IRQS_OFF
	xorl	%edx, %edx			# zero error code
	movl	%esp, %eax			# pt_regs pointer
	call	do_int3
	jmp	ret_from_exception
ENDPROC(int3)

ENTRY(general_protection)
	pushl	$do_general_protection
	jmp	error_code
ENDPROC(general_protection)

#ifdef CONFIG_KVM_GUEST
ENTRY(async_page_fault)
	ASM_CLAC
	pushl	$do_async_page_fault
	jmp	error_code
ENDPROC(async_page_fault)
#endif
