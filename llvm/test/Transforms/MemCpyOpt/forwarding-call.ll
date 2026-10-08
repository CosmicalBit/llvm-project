; RUN: opt -passes=memcpyopt -verify-memoryssa -S %s | FileCheck %s

declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg)
declare void @observe(ptr captures(none))
declare void @effect()
declare void @produce(ptr captures(address))
declare void @consume(ptr captures(address))

; The two field copies cover the entire aggregate, but occur in reverse order.
define dso_local void @forward(ptr noalias sret([48 x i8]) %out,
                               ptr noalias readonly dead_on_return %in) noinline {
  %in.second = getelementptr i8, ptr %in, i64 24
  %out.second = getelementptr i8, ptr %out, i64 24
  call void @llvm.memcpy.p0.p0.i64(ptr %out.second, ptr %in.second, i64 24, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 24, i1 false)
  ret void
}

define void @reuse_input_storage() {
; CHECK-LABEL: define void @reuse_input_storage() {
; CHECK: %src = alloca [48 x i8]
; CHECK-NOT: %dst = alloca
; CHECK-NOT: call void @forward
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @observe(ptr captures(none) %src)
; CHECK: ret void
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  store i64 42, ptr %src, align 8
  call void @forward(ptr noalias sret([48 x i8]) %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

define void @reuse_across_address_captures() {
; CHECK-LABEL: define void @reuse_across_address_captures() {
; CHECK-NOT: call void @forward
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @consume(
; CHECK: ret void
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @produce(ptr captures(address) %src)
  call void @forward(ptr noalias sret([48 x i8]) %dst, ptr noalias %src)
  call void @consume(ptr captures(address) %dst)
  ret void
}

; A partial copy cannot be promoted into a full aggregate copy.
define internal void @forward_half(ptr noalias sret([48 x i8]) %out,
                                   ptr noalias readonly %in) noinline {
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 24, i1 false)
  ret void
}

define void @keep_partial_copy() {
; CHECK-LABEL: define void @keep_partial_copy() {
; CHECK: call void @forward_half(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_half(ptr noalias sret([48 x i8]) %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; An extra effect must be preserved.
define internal void @forward_with_effect(ptr noalias sret([48 x i8]) %out,
                                          ptr noalias readonly %in) noinline {
  call void @effect()
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
}

define void @keep_effect() {
; CHECK-LABEL: define void @keep_effect() {
; CHECK: call void @forward_with_effect(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_with_effect(ptr noalias sret([48 x i8]) %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Without an argument aliasing guarantee, adjacent field copies might behave
; differently from a single full-size memcpy on overlapping storage.
define internal void @forward_aliasable(ptr %out, ptr %in) noinline {
  %in.second = getelementptr i8, ptr %in, i64 24
  %out.second = getelementptr i8, ptr %out, i64 24
  call void @llvm.memcpy.p0.p0.i64(ptr %out.second, ptr %in.second, i64 24, i1 false)
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 24, i1 false)
  ret void
}

define void @keep_aliasing_call() {
; CHECK-LABEL: define void @keep_aliasing_call() {
; CHECK: call void @forward_aliasable(ptr %dst, ptr %src)
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_aliasable(ptr %dst, ptr %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}
