; RUN: opt -passes=function-attrs -S %s | FileCheck %s

; CHECK-LABEL: define {{.*}}@infinite_recursion()
; CHECK-SAME: #[[NORETURN:[0-9]+]]
define void @infinite_recursion() {
entry:
  call void @infinite_recursion()
  ret void
}

; A reachable base case still permits the recursive call to return.
; CHECK-LABEL: define {{.*}}@recursive_with_base_case(i1 %recurse)
; CHECK-NOT: noreturn
define void @recursive_with_base_case(i1 %recurse) {
entry:
  br i1 %recurse, label %again, label %base

again:
  call void @recursive_with_base_case(i1 %recurse)
  ret void

base:
  ret void
}

; CHECK: attributes #[[NORETURN]] = { {{.*}}noreturn{{.*}} }
