; RUN: opt -passes=licm -S < %s | FileCheck %s
; RUN: opt -aa-pipeline=basic-aa -passes='require<aa>,require<target-ir>,require<scalar-evolution>,require<opt-remark-emit>,loop-mssa(licm)' -S < %s | FileCheck %s

; The clobbering call cannot change %p while the invariant region is active.
define i32 @end_after_loop(ptr dereferenceable(4) %p, i32 %n) {
; CHECK-LABEL: @end_after_loop(
; CHECK:       entry:
; CHECK:         %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
; CHECK-NEXT:    %value = load i32, ptr %p
; CHECK:       loop:
; CHECK-NOT:     load i32, ptr %p
; CHECK:         call void @clobber(ptr %p)
; CHECK:       exit:
; CHECK:         call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
  %value = load i32, ptr %p
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  ret i32 %next_sum
}

; An end on only one exit path is sufficient: on the other path the region
; remains active until the function returns.
define i32 @end_on_one_exit(ptr dereferenceable(4) %p, i32 %n, i1 %end_it) {
; CHECK-LABEL: @end_on_one_exit(
; CHECK:       entry:
; CHECK:         %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
; CHECK-NEXT:    %value = load i32, ptr %p
; CHECK:       loop:
; CHECK-NOT:     load i32, ptr %p
; CHECK:         call void @clobber(ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
  %value = load i32, ptr %p
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  br i1 %end_it, label %end, label %ret

end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  br label %ret

ret:
  ret i32 %next_sum
}

; The end can execute before the loop, so the load remains in the loop.
define i32 @end_before_loop(ptr dereferenceable(4) %p, i32 %n) {
; CHECK-LABEL: @end_before_loop(
; CHECK:       loop:
; CHECK:         %value = load i32, ptr %p
; CHECK-NEXT:    call void @clobber(ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
  %value = load i32, ptr %p
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  ret i32 %next_sum
}

; This end is outside the loop but can run on a path before loop entry.
define i32 @end_on_entry_path(ptr dereferenceable(4) %p, i32 %n, i1 %early) {
; CHECK-LABEL: @end_on_entry_path(
; CHECK:       loop:
; CHECK:         %value = load i32, ptr %p
; CHECK-NEXT:    call void @clobber(ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  br i1 %early, label %end, label %loop

end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ 0, %end ], [ %next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ 0, %end ], [ %next_sum, %loop ]
  %value = load i32, ptr %p
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  ret i32 %next_sum
}

; An end in the loop can permit a later iteration to observe a new value.
define i32 @end_in_loop(ptr dereferenceable(4) %p, i32 %n) {
; CHECK-LABEL: @end_in_loop(
; CHECK:       loop:
; CHECK:         %value = load i32, ptr %p
; CHECK:       end:
; CHECK:         call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %next, %after_end ]
  %sum = phi i32 [ 0, %entry ], [ %next_sum, %after_end ]
  %value = load i32, ptr %p
  %first = icmp eq i32 %i, 0
  br i1 %first, label %end, label %after_end

end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  br label %after_end

after_end:
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  ret i32 %next_sum
}

; An outer iteration can re-enter the inner loop after ending the invariant
; region. The second visit may observe changes made by the clobbering call.
define i32 @end_before_reentry(ptr dereferenceable(4) %p) {
; CHECK-LABEL: @end_before_reentry(
; CHECK:       inner:
; CHECK:         %value = load i32, ptr %p
; CHECK:       clobber:
; CHECK:         call void @clobber(ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  br label %outer

outer:
  %j = phi i32 [ 0, %entry ], [ %j.next, %after_end ]
  %outer_sum = phi i32 [ 0, %entry ], [ %inner_sum, %after_end ]
  %first = icmp eq i32 %j, 0
  br label %inner

inner:
  %i = phi i32 [ 0, %outer ], [ %i.next, %inner_next ]
  %sum = phi i32 [ %outer_sum, %outer ], [ %sum.next, %inner_next ]
  %value = load i32, ptr %p
  %sum.next = add i32 %sum, %value
  br i1 %first, label %inner_next, label %clobber

clobber:
  call void @clobber(ptr %p)
  br label %inner_next

inner_next:
  %i.next = add i32 %i, 1
  %again = icmp ult i32 %i.next, 2
  br i1 %again, label %inner, label %inner_exit

inner_exit:
  %inner_sum = phi i32 [ %sum.next, %inner_next ]
  br i1 %first, label %end, label %after_end

end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  br label %after_end

after_end:
  call void @clobber(ptr %p)
  %j.next = add i32 %j, 1
  br i1 %first, label %outer, label %exit

exit:
  ret i32 %inner_sum
}

; Separate exits can each end the same invariant region.
define i32 @end_on_each_exit(ptr dereferenceable(4) %p, i32 %n, i1 %end_it) {
; CHECK-LABEL: @end_on_each_exit(
; CHECK:       entry:
; CHECK:         %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
; CHECK-NEXT:    %value = load i32, ptr %p
; CHECK:       loop:
; CHECK-NOT:     load i32, ptr %p
; CHECK:         call void @clobber(ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
  %value = load i32, ptr %p
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  br i1 %end_it, label %end, label %other_end

end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  ret i32 %next_sum

other_end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  ret i32 %next_sum
}

; A safe end does not compensate for another end before loop entry.
define i32 @ends_before_and_after_loop(ptr dereferenceable(4) %p, i32 %n, i1 %early) {
; CHECK-LABEL: @ends_before_and_after_loop(
; CHECK:       loop:
; CHECK:         %value = load i32, ptr %p
; CHECK-NEXT:    call void @clobber(ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  br i1 %early, label %end, label %loop

end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ 0, %end ], [ %next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ 0, %end ], [ %next_sum, %loop ]
  %value = load i32, ptr %p
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  br i1 %early, label %ret, label %late_end

late_end:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  br label %ret

ret:
  ret i32 %next_sum
}

; A direct end is insufficient if the token also escapes.
define i32 @end_and_escape(ptr dereferenceable(4) %p, i32 %n) {
; CHECK-LABEL: @end_and_escape(
; CHECK:       loop:
; CHECK:         %value = load i32, ptr %p
; CHECK-NEXT:    call void @clobber(ptr %p)
entry:
  %scope = call ptr @llvm.invariant.start.p0(i64 4, ptr %p)
  call void @escape(ptr %scope)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %next, %loop ]
  %sum = phi i32 [ 0, %entry ], [ %next_sum, %loop ]
  %value = load i32, ptr %p
  call void @clobber(ptr %p)
  %next_sum = add i32 %sum, %value
  %next = add i32 %i, 1
  %again = icmp slt i32 %next, %n
  br i1 %again, label %loop, label %exit

exit:
  call void @llvm.invariant.end.p0(ptr %scope, i64 4, ptr %p)
  ret i32 %next_sum
}

declare ptr @llvm.invariant.start.p0(i64, ptr)
declare void @llvm.invariant.end.p0(ptr, i64, ptr)
declare void @clobber(ptr)
declare void @escape(ptr)
