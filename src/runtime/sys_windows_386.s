// Copyright 2009 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "go_asm.h"
#include "go_tls.h"
#include "textflag.h"
#include "time_windows.h"

// Offsets into Thread Environment Block (pointer in FS)
#define TEB_TlsSlots 0xE10

// void runtime·asmstdcall(void *c);
TEXT runtime·asmstdcall(SB),NOSPLIT,$0
	MOVL	fn+0(FP), BX

	// SetLastError(0).
	MOVL	$0, 0x34(FS)

	// Copy args to the stack.
	MOVL	SP, BP
	MOVL	libcall_n(BX), CX	// words
	MOVL	CX, AX
	SALL	$2, AX
	SUBL	AX, SP			// room for args
	MOVL	SP, DI
	MOVL	libcall_args(BX), SI
	CLD
	REP; MOVSL

	// Call stdcall or cdecl function.
	// DI SI BP BX are preserved, SP is not
	CALL	libcall_fn(BX)
	MOVL	BP, SP

	// Return result.
	MOVL	fn+0(FP), BX
	MOVL	AX, libcall_r1(BX)
	MOVL	DX, libcall_r2(BX)

	// GetLastError().
	MOVL	0x34(FS), AX
	MOVL	AX, libcall_err(BX)

	RET

// faster get/set last error
TEXT runtime·getlasterror(SB),NOSPLIT,$0
	MOVL	0x34(FS), AX
	MOVL	AX, ret+0(FP)
	RET

TEXT runtime·sigFetchGSafe<ABIInternal>(SB),NOSPLIT,$0
	get_tls(AX)
	CMPL	AX, $0
	JE	2(PC)
	MOVL	g(AX), AX
	MOVL	AX, ret+0(FP)
	RET

// Called by Windows as a Vectored Exception Handler (VEH).
// AX is pointer to struct containing
// exception record and context pointers.
// CX is the kind of sigtramp function.
// Return value of sigtrampgo is stored in AX.
TEXT sigtramp<>(SB),NOSPLIT,$0-0
	SUBL	$40, SP

	// save callee-saved registers
	MOVL	BX, 28(SP)
	MOVL	BP, 16(SP)
	MOVL	SI, 20(SP)
	MOVL	DI, 24(SP)

	MOVL	AX, 0(SP)
	MOVL	CX, 4(SP)
	CALL	runtime·sigtrampgo(SB)
	MOVL	8(SP), AX

	// restore callee-saved registers
	MOVL	24(SP), DI
	MOVL	20(SP), SI
	MOVL	16(SP), BP
	MOVL	28(SP), BX

	ADDL	$40, SP
	// RET 4 (return and pop 4 bytes parameters)
	BYTE $0xC2; WORD $4
	RET // unreached; make assembler happy

// Trampoline to resume execution from exception handler.
// This is part of the control flow guard workaround.
// It switches stacks and jumps to the continuation address.
// DX and CX are set above at the end of sigtrampgo
// in the context that starts executing at sigresume.
TEXT runtime·sigresume(SB),NOSPLIT,$0
	MOVL	DX, SP
	JMP	CX

TEXT runtime·exceptiontramp(SB),NOSPLIT,$0
	MOVL	argframe+0(FP), AX
	MOVL	$const_callbackVEH, CX
	JMP	sigtramp<>(SB)

TEXT runtime·firstcontinuetramp(SB),NOSPLIT,$0-0
	// is never called
	INT	$3

TEXT runtime·lastcontinuetramp(SB),NOSPLIT,$0-0
	MOVL	argframe+0(FP), AX
	MOVL	$const_callbackLastVCH, CX
	JMP	sigtramp<>(SB)

TEXT runtime·callbackasm1(SB),NOSPLIT,$0
  	MOVL	0(SP), AX	// will use to find our callback context

	// remove return address from stack, we are not returning to callbackasm, but to its caller.
	ADDL	$4, SP

	// address to callback parameters into CX
	LEAL	4(SP), CX

	// save registers as required for windows callback
	PUSHL	DI
	PUSHL	SI
	PUSHL	BP
	PUSHL	BX

	// Go ABI requires DF flag to be cleared.
	CLD

	// determine index into runtime·cbs table
	SUBL	$runtime·callbackasm(SB), AX
	MOVL	$0, DX
	MOVL	$5, BX	// divide by 5 because each call instruction in runtime·callbacks is 5 bytes long
	DIVL	BX
	SUBL	$1, AX	// subtract 1 because return PC is to the next slot

	// Create a struct callbackArgs on our stack.
	SUBL	$(12+callbackArgs__size), SP
	MOVL	AX, (12+callbackArgs_index)(SP)		// callback index
	MOVL	CX, (12+callbackArgs_args)(SP)		// address of args vector
	MOVL	$0, (12+callbackArgs_result)(SP)	// result
	LEAL	12(SP), AX	// AX = &callbackArgs{...}

	// Call cgocallback, which will call callbackWrap(frame).
	MOVL	$0, 8(SP)	// context
	MOVL	AX, 4(SP)	// frame (address of callbackArgs)
	LEAL	·callbackWrap(SB), AX
	MOVL	AX, 0(SP)	// PC of function to call
	CALL	runtime·cgocallback(SB)

	// Get callback result.
	MOVL	(12+callbackArgs_result)(SP), AX
	// Get popRet.
	MOVL	(12+callbackArgs_retPop)(SP), CX	// Can't use a callee-save register
	ADDL	$(12+callbackArgs__size), SP

	// restore registers as required for windows callback
	POPL	BX
	POPL	BP
	POPL	SI
	POPL	DI

	// remove callback parameters before return (as per Windows spec)
	POPL	DX
	ADDL	CX, SP
	PUSHL	DX

	CLD

	RET

// void tstart(M *newm);
TEXT tstart<>(SB),NOSPLIT,$8-4
	MOVL	newm+0(FP), CX		// m
	MOVL	m_g0(CX), DX		// g

	// Layout new m scheduler stack on os stack.
	MOVL	SP, AX
	MOVL	AX, (g_stack+stack_hi)(DX)
	SUBL	$(64*1024), AX		// initial stack size (adjusted later)
	MOVL	AX, (g_stack+stack_lo)(DX)
	ADDL	$const__StackGuard, AX
	MOVL	AX, g_stackguard0(DX)
	MOVL	AX, g_stackguard1(DX)

	// Set up tls.
	LEAL	m_tls(CX), DI
	MOVL	CX, g_m(DX)
	MOVL	DX, g(DI)
	MOVL	DI, 4(SP)
	CALL	runtime·setldt(SB) // clobbers CX and DX

	// Someday the convention will be D is always cleared.
	CLD

	CALL	runtime·stackcheck(SB)	// clobbers AX,CX
	CALL	runtime·mstart(SB)

	RET

// uint32 tstart_stdcall(M *newm);
TEXT runtime·tstart_stdcall(SB),NOSPLIT,$0
	MOVL	newm+0(FP), BX

	PUSHL	BX
	CALL	tstart<>(SB)
	POPL	BX

	// Adjust stack for stdcall to return properly.
	MOVL	(SP), AX		// save return address
	ADDL	$4, SP			// remove single parameter
	MOVL	AX, (SP)		// restore return address

	XORL	AX, AX			// return 0 == success

	RET

// setldt(int slot, int base, int size)
TEXT runtime·setldt(SB),NOSPLIT,$0-12
	MOVL	base+4(FP), DX
	MOVL	runtime·tls_g(SB), CX
	MOVL	DX, 0(CX)(FS)
	RET

// Runs on OS stack.
// duration (in -100ns units) is in dt+0(FP).
// g may be nil.
TEXT runtime·usleep2(SB),NOSPLIT,$20-4
	MOVL	dt+0(FP), BX
	MOVL	$-1, hi-4(SP)
	MOVL	BX, lo-8(SP)
	LEAL	lo-8(SP), BX
	MOVL	BX, ptime-12(SP)
	MOVL	$0, alertable-16(SP)
	MOVL	$-1, handle-20(SP)
	MOVL	SP, BP
	MOVL	runtime·_NtWaitForSingleObject(SB), AX
	CALL	AX
	MOVL	BP, SP
	RET

// Runs on OS stack.
// duration (in -100ns units) is in dt+0(FP).
// g is valid.
TEXT runtime·usleep2HighRes(SB),NOSPLIT,$36-4
	MOVL	dt+0(FP), BX
	MOVL	$-1, hi-4(SP)
	MOVL	BX, lo-8(SP)

	get_tls(CX)
	MOVL	g(CX), CX
	MOVL	g_m(CX), CX
	MOVL	(m_mOS+mOS_highResTimer)(CX), CX
	MOVL	CX, saved_timer-12(SP)

	MOVL	$0, fResume-16(SP)
	MOVL	$0, lpArgToCompletionRoutine-20(SP)
	MOVL	$0, pfnCompletionRoutine-24(SP)
	MOVL	$0, lPeriod-28(SP)
	LEAL	lo-8(SP), BX
	MOVL	BX, lpDueTime-32(SP)
	MOVL	CX, hTimer-36(SP)
	MOVL	SP, BP
	MOVL	runtime·_SetWaitableTimer(SB), AX
	CALL	AX
	MOVL	BP, SP

	MOVL	$0, ptime-28(SP)
	MOVL	$0, alertable-32(SP)
	MOVL	saved_timer-12(SP), CX
	MOVL	CX, handle-36(SP)
	MOVL	SP, BP
	MOVL	runtime·_NtWaitForSingleObject(SB), AX
	CALL	AX
	MOVL	BP, SP

	RET

// Runs on OS stack.
TEXT runtime·switchtothread(SB),NOSPLIT,$0
	MOVL	SP, BP
	MOVL	runtime·_SwitchToThread(SB), AX
	CALL	AX
	MOVL	BP, SP
	RET

TEXT runtime·nanotime1(SB),NOSPLIT,$0-8
	CMPB	runtime·useQPCTime(SB), $0
	JNE	useQPC
loop:
	MOVL	(_INTERRUPT_TIME+time_hi1), AX
	MOVL	(_INTERRUPT_TIME+time_lo), CX
	MOVL	(_INTERRUPT_TIME+time_hi2), DI
	CMPL	AX, DI
	JNE	loop

	// wintime = DI:CX, multiply by 100
	MOVL	$100, AX
	MULL	CX
	IMULL	$100, DI
	ADDL	DI, DX
	// wintime*100 = DX:AX
	MOVL	AX, ret_lo+0(FP)
	MOVL	DX, ret_hi+4(FP)
	RET
useQPC:
	JMP	runtime·nanotimeQPC(SB)
	RET

// This is called from rt0_go, which runs on the system stack
// using the initial stack allocated by the OS.
TEXT runtime·wintls(SB),NOSPLIT,$0
	// Allocate a TLS slot to hold g across calls to external code
	MOVL	SP, BP
	MOVL	runtime·_TlsAlloc(SB), AX
	CALL	AX
	MOVL	BP, SP

	MOVL	AX, CX	// TLS index

	// Assert that slot is less than 64 so we can use _TEB->TlsSlots
	CMPL	CX, $64
	JB	ok
	CALL	runtime·abort(SB)
ok:
	// Convert the TLS index at CX into
	// an offset from TEB_TlsSlots.
	SHLL	$2, CX

	// Save offset from TLS into tls_g.
	ADDL	$TEB_TlsSlots, CX
	MOVL	CX, runtime·tls_g(SB)
	RET
