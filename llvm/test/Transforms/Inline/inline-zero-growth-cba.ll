; RUN: opt -passes='require<profile-summary>,cgscc(inline)' -pass-remarks=inline -pass-remarks-missed=inline -S %s 2>&1 | FileCheck %s

; A call before unreachable has a zero size-growth threshold. Cost-benefit
; analysis must not override that limit, even for a profitable hot call.
; CHECK: 'callee' not inlined into 'caller' because too costly to inline (cost=15, threshold=0)
; CHECK: 'callee' inlined into 'control_caller' with (cost=always): benefit over cost

target triple = "x86_64-unknown-linux-gnu"

define i32 @callee(i32 %x) !prof !4 {
entry:
  %v0 = add i32 %x, 1
  %v1 = add i32 %v0, 2
  %v2 = add i32 %v1, 3
  %v3 = add i32 %v2, 4
  %v4 = add i32 %v3, 5
  %v5 = add i32 %v4, 6
  %v6 = add i32 %v5, 7
  %v7 = add i32 %v6, 8
  %v8 = add i32 %v7, 9
  %v9 = add i32 %v8, 10
  ret i32 %v9
}

; CHECK-LABEL: define void @caller(
; CHECK: call i32 @callee
define void @caller(i32 %x) !prof !5 {
entry:
  %v = call i32 @callee(i32 %x) "inline-cycle-savings-for-test"="100000" "inline-runtime-cost-for-test"="1"
  unreachable
}

; The same profitable call is inlined when its threshold is nonzero.
; CHECK-LABEL: define void @control_caller(
; CHECK-NOT: call i32 @callee
; CHECK: unreachable
define void @control_caller(i32 %x) !prof !5 {
entry:
  %v = call i32 @callee(i32 %x) "inline-cycle-savings-for-test"="100000" "inline-runtime-cost-for-test"="1" "function-inline-threshold"="1"
  unreachable
}

!llvm.module.flags = !{!0}
!0 = !{i32 1, !"ProfileSummary", !1}
!1 = !{!2, !3, !6, !7, !8, !9, !10, !11}
!2 = !{!"ProfileFormat", !"InstrProf"}
!3 = !{!"TotalCount", i64 10000}
!4 = !{!"function_entry_count", i64 200}
!5 = !{!"function_entry_count", i64 500}
!6 = !{!"MaxCount", i64 1000}
!7 = !{!"MaxInternalCount", i64 1}
!8 = !{!"MaxFunctionCount", i64 1000}
!9 = !{!"NumCounts", i64 3}
!10 = !{!"NumFunctions", i64 3}
!11 = !{!"DetailedSummary", !12}
!12 = !{!13, !14, !15}
!13 = !{i32 10000, i64 100, i32 1}
!14 = !{i32 990000, i64 100, i32 1}
!15 = !{i32 999999, i64 1, i32 2}
