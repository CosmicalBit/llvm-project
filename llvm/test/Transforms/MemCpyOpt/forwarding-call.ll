; RUN: opt -passes=memcpyopt -verify-memoryssa -S %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64-ni:1"

declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64 immarg, i1 immarg)
declare void @observe(ptr captures(none))
declare void @effect()
declare void @produce(ptr captures(address))
declare void @consume(ptr captures(address))
@captured_address = global ptr null

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

; A mix of whole-field copies and byte-aligned scalar loads/stores forwards
; the complete result. The third argument is irrelevant to the copied bytes.
define internal void @forward_mixed(ptr noalias %out, ptr noalias %in,
                                    i32 %unused) noinline {
  %in.8 = getelementptr i8, ptr %in, i64 8
  %out.8 = getelementptr i8, ptr %out, i64 8
  %first = load i64, ptr %in, align 8
  store i64 %first, ptr %out, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr %out.8, ptr %in.8, i64 40, i1 false)
  ret void
}

define void @reuse_mixed_copy() {
; CHECK-LABEL: define void @reuse_mixed_copy() {
; CHECK-NOT: call void @forward_mixed
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @observe(
; CHECK: ret void
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_mixed(ptr noalias %dst, ptr noalias %src, i32 17)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; The branch condition changes the path, but each path forwards all 48 bytes.
define internal void @forward_branch(ptr noalias %out, ptr noalias %in,
                                     i1 %flag, i32 %unused) noinline {
entry:
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 8, i1 false)
  br i1 %flag, label %memcpy.path, label %mixed.path
memcpy.path:
  %in.memcpy.8 = getelementptr i8, ptr %in, i64 8
  %out.memcpy.8 = getelementptr i8, ptr %out, i64 8
  call void @llvm.memcpy.p0.p0.i64(ptr %out.memcpy.8, ptr %in.memcpy.8, i64 40, i1 false)
  br label %done
mixed.path:
  %in.8 = getelementptr i8, ptr %in, i64 8
  %out.8 = getelementptr i8, ptr %out, i64 8
  %next = load i64, ptr %in.8, align 8
  store i64 %next, ptr %out.8, align 8
  %in.16 = getelementptr i8, ptr %in, i64 16
  %out.16 = getelementptr i8, ptr %out, i64 16
  call void @llvm.memcpy.p0.p0.i64(ptr %out.16, ptr %in.16, i64 32, i1 false)
  br label %done
done:
  ret void
}

define void @reuse_across_branches(i1 %flag) {
; CHECK-LABEL: define void @reuse_across_branches(i1 %flag) {
; CHECK-NOT: call void @forward_branch
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @observe(
; CHECK: ret void
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_branch(ptr noalias %dst, ptr noalias %src,
                            i1 %flag, i32 19)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Both return sites forward the same bytes, using different copy operations.
define internal void @forward_two_returns(ptr noalias %out, ptr noalias %in,
                                          i1 %flag) noinline {
  br i1 %flag, label %one, label %two
one:
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 8, i1 false)
  ret void
two:
  %value = load i64, ptr %in
  store i64 %value, ptr %out
  ret void
}

define void @reuse_two_returns(i1 %flag) {
; CHECK-LABEL: define void @reuse_two_returns(i1 %flag) {
; CHECK-NOT: call void @forward_two_returns
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @observe(
; CHECK: ret void
  %src = alloca [8 x i8], align 8
  %dst = alloca [8 x i8], align 8
  call void @forward_two_returns(ptr noalias %dst, ptr noalias %src, i1 %flag)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Pointer fields can be forwarded without changing their representation.
define internal void @forward_pointer(ptr noalias %out, ptr noalias %in) noinline {
  %value = load ptr, ptr %in
  store ptr %value, ptr %out
  ret void
}

define void @reuse_pointer_field() {
; CHECK-LABEL: define void @reuse_pointer_field() {
; CHECK-NOT: call void @forward_pointer
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @observe(
; CHECK: ret void
  %src = alloca [8 x i8], align 8
  %dst = alloca [8 x i8], align 8
  call void @forward_pointer(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; One load can feed stores in different successor blocks.
define internal void @forward_split_store(ptr noalias %out, ptr noalias %in,
                                          i1 %flag) noinline {
entry:
  %value = load i64, ptr %in
  br i1 %flag, label %left, label %right
left:
  store i64 %value, ptr %out
  ret void
right:
  store i64 %value, ptr %out
  ret void
}

define void @reuse_split_store(i1 %flag) {
; CHECK-LABEL: define void @reuse_split_store(i1 %flag) {
; CHECK-NOT: call void @forward_split_store
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @observe(
; CHECK: ret void
  %src = alloca [8 x i8], align 8
  %dst = alloca [8 x i8], align 8
  call void @forward_split_store(ptr noalias %dst, ptr noalias %src, i1 %flag)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; A larger input is safe when every result byte is copied from its prefix.
define internal void @forward_prefix(ptr noalias %out, ptr noalias %in) noinline {
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
}

define void @reuse_larger_input() {
; CHECK-LABEL: define void @reuse_larger_input() {
; CHECK-NOT: call void @forward_prefix
; CHECK-NOT: call void @llvm.memcpy
; CHECK: call void @observe(
; CHECK: ret void
  %src = alloca [56 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_prefix(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; One branch leaves the final eight bytes untouched.
define internal void @forward_missing_path(ptr noalias %out, ptr noalias %in,
                                            i1 %flag) noinline {
  br i1 %flag, label %whole, label %partial
whole:
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
partial:
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 40, i1 false)
  ret void
}

define void @keep_missing_path(i1 %flag) {
; CHECK-LABEL: define void @keep_missing_path(i1 %flag) {
; CHECK: call void @forward_missing_path(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_missing_path(ptr noalias %dst, ptr noalias %src, i1 %flag)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; A loop can fail to return, so the call cannot be replaced by a finite copy.
define internal void @forward_loop(ptr noalias %out, ptr noalias %in,
                                   i1 %again) noinline {
entry:
  br label %loop
loop:
  br i1 %again, label %loop, label %done
done:
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
}

define void @keep_loop(i1 %again) {
; CHECK-LABEL: define void @keep_loop(i1 %again) {
; CHECK: call void @forward_loop(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_loop(ptr noalias %dst, ptr noalias %src, i1 %again)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; An extra argument that changes an output byte is not ignored.
define internal void @forward_modified(ptr noalias %out, ptr noalias %in,
                                       i8 %replacement) noinline {
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  store i8 %replacement, ptr %out
  ret void
}

define void @keep_modified(i8 %replacement) {
; CHECK-LABEL: define void @keep_modified(i8 %replacement) {
; CHECK: call void @forward_modified(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_modified(ptr noalias %dst, ptr noalias %src,
                              i8 %replacement)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Escaping a pointer argument is an observable effect of the call.
define internal void @forward_capture(ptr noalias %out, ptr noalias %in) noinline {
  store ptr %in, ptr @captured_address
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
}

define void @keep_capture() {
; CHECK-LABEL: define void @keep_capture() {
; CHECK: call void @forward_capture(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_capture(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; A byval extra argument has implicit memory semantics at the call boundary.
define internal void @forward_byval_extra(ptr noalias %out, ptr noalias %in,
                                          ptr byval([8 x i8]) align 8 %extra) noinline {
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
}

define void @keep_byval_extra() {
; CHECK-LABEL: define void @keep_byval_extra() {
; CHECK: call void @forward_byval_extra(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  %extra = alloca [8 x i8], align 8
  call void @forward_byval_extra(ptr noalias %dst, ptr noalias %src,
                                 ptr byval([8 x i8]) align 8 %extra)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; A byval destination names a private callee copy, not the caller's alloca.
define internal void @forward_byval_dest(ptr noalias byval([48 x i8]) align 8 %out,
                                         ptr noalias %in) noinline {
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
}

define void @keep_byval_destination() {
; CHECK-LABEL: define void @keep_byval_destination() {
; CHECK: call void @forward_byval_dest(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_byval_dest(ptr noalias byval([48 x i8]) align 8 %dst,
                                ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; An i1 store need not preserve the unused bits in its byte.
define internal void @forward_i1(ptr noalias %out, ptr noalias %in) noinline {
  %bit = load i1, ptr %in
  store i1 %bit, ptr %out
  ret void
}

define void @keep_i1() {
; CHECK-LABEL: define void @keep_i1() {
; CHECK: call void @forward_i1(
  %src = alloca [1 x i8]
  %dst = alloca [1 x i8]
  call void @forward_i1(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Non-integral pointers can carry state outside their in-memory bit pattern.
define internal void @forward_nonintegral(ptr noalias %out,
                                          ptr noalias %in) noinline {
  %value = load ptr addrspace(1), ptr %in
  store ptr addrspace(1) %value, ptr %out
  ret void
}

define void @keep_nonintegral_pointer() {
; CHECK-LABEL: define void @keep_nonintegral_pointer() {
; CHECK: call void @forward_nonintegral(
  %src = alloca [8 x i8]
  %dst = alloca [8 x i8]
  call void @forward_nonintegral(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Freezing a loaded value changes undef/poison behavior.
define internal void @forward_frozen(ptr noalias %out, ptr noalias %in) noinline {
  %v = load i64, ptr %in
  %frozen = freeze i64 %v
  store i64 %frozen, ptr %out
  ret void
}

define void @keep_frozen() {
; CHECK-LABEL: define void @keep_frozen() {
; CHECK: call void @forward_frozen(
  %src = alloca [8 x i8]
  %dst = alloca [8 x i8]
  call void @forward_frozen(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Range metadata changes the loaded value's poison behavior.
define internal void @forward_range_load(ptr noalias %out,
                                         ptr noalias %in) noinline {
  %v = load i64, ptr %in, !range !0
  store i64 %v, ptr %out
  ret void
}

define void @keep_range_load() {
; CHECK-LABEL: define void @keep_range_load() {
; CHECK: call void @forward_range_load(
  %src = alloca [8 x i8]
  %dst = alloca [8 x i8]
  call void @forward_range_load(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Volatile reads are observable even if the output bytes would match.
define internal void @forward_volatile(ptr noalias %out, ptr noalias %in) noinline {
  %v = load volatile i64, ptr %in
  store i64 %v, ptr %out
  ret void
}

define void @keep_volatile() {
; CHECK-LABEL: define void @keep_volatile() {
; CHECK: call void @forward_volatile(
  %src = alloca [8 x i8]
  %dst = alloca [8 x i8]
  call void @forward_volatile(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; llvm.memcpy.inline must not be replaced by a copy that may lower to a call.
define internal void @forward_inline_copy(ptr noalias %out,
                                          ptr noalias %in) noinline {
  call void @llvm.memcpy.inline.p0.p0.i64(ptr %out, ptr %in, i64 48, i1 false)
  ret void
}

define void @keep_inline_copy() {
; CHECK-LABEL: define void @keep_inline_copy() {
; CHECK: call void @forward_inline_copy(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_inline_copy(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; A destination larger than the input contains bytes not forwarded by the call.
define void @keep_larger_destination() {
; CHECK-LABEL: define void @keep_larger_destination() {
; CHECK: call void @forward_prefix(
  %src = alloca [48 x i8]
  %dst = alloca [56 x i8]
  call void @forward_prefix(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; A copy from a different input offset does not preserve the aggregate.
define internal void @forward_shifted(ptr noalias %out, ptr noalias %in) noinline {
  %in.8 = getelementptr i8, ptr %in, i64 8
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in.8, i64 48, i1 false)
  ret void
}

define void @keep_shifted() {
; CHECK-LABEL: define void @keep_shifted() {
; CHECK: call void @forward_shifted(
  %src = alloca [56 x i8]
  %dst = alloca [48 x i8]
  call void @forward_shifted(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Avoid per-call scans of arbitrarily large control-flow graphs.
define internal void @forward_too_many_blocks(ptr noalias %out,
                                               ptr noalias %in) noinline {
entry:
  br label %b1
b1:
  br label %b2
b2:
  br label %b3
b3:
  br label %b4
b4:
  br label %b5
b5:
  br label %b6
b6:
  br label %b7
b7:
  br label %b8
b8:
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 8, i1 false)
  ret void
}

define void @keep_large_cfg() {
; CHECK-LABEL: define void @keep_large_cfg() {
; CHECK: call void @forward_too_many_blocks(
  %src = alloca [8 x i8]
  %dst = alloca [8 x i8]
  call void @forward_too_many_blocks(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

define internal void @forward_too_many_bytes(ptr noalias %out,
                                              ptr noalias %in) noinline {
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 1025, i1 false)
  ret void
}

define void @keep_large_aggregate() {
; CHECK-LABEL: define void @keep_large_aggregate() {
; CHECK: call void @forward_too_many_bytes(
  %src = alloca [1025 x i8]
  %dst = alloca [1025 x i8]
  call void @forward_too_many_bytes(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

!0 = !{i64 0, i64 10}

; An operand bundle on the inner memcpy can introduce additional effects.
define internal void @forward_bundled_copy(ptr noalias %out, ptr noalias %in) noinline {
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 8, i1 false) [ "unknown"(ptr %in) ]
  ret void
}

define void @keep_bundled_copy() {
; CHECK-LABEL: define void @keep_bundled_copy() {
; CHECK: call void @forward_bundled_copy(
  %src = alloca [8 x i8], align 8
  %dst = alloca [8 x i8], align 8
  call void @forward_bundled_copy(ptr noalias %dst, ptr noalias %src)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Contradictory memory attributes must not crash the MemorySSA update, even
; though executing these calls has undefined behavior.
define void @keep_readnone_call() {
; CHECK-LABEL: define void @keep_readnone_call() {
; CHECK: call void @forward_prefix(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_prefix(ptr noalias %dst, ptr noalias %src) memory(none)
  call void @observe(ptr captures(none) %dst)
  ret void
}

define void @keep_readonly_call() {
; CHECK-LABEL: define void @keep_readonly_call() {
; CHECK: call void @forward_prefix(
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @forward_prefix(ptr noalias %dst, ptr noalias %src) memory(read)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; The join must intersect coverage: the second half is absent on one path.
define internal void @forward_partial_join(ptr noalias %out, ptr noalias %in,
                                          i1 %flag) noinline {
entry:
  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %in, i64 8, i1 false)
  br i1 %flag, label %rest, label %done
rest:
  %in.8 = getelementptr i8, ptr %in, i64 8
  %out.8 = getelementptr i8, ptr %out, i64 8
  call void @llvm.memcpy.p0.p0.i64(ptr %out.8, ptr %in.8, i64 8, i1 false)
  br label %done
done:
  ret void
}

define void @keep_partial_join(i1 %flag) {
; CHECK-LABEL: define void @keep_partial_join(i1 %flag) {
; CHECK: call void @forward_partial_join(
  %src = alloca [16 x i8], align 8
  %dst = alloca [16 x i8], align 8
  call void @forward_partial_join(ptr noalias %dst, ptr noalias %src, i1 %flag)
  call void @observe(ptr captures(none) %dst)
  ret void
}

; Distinct contents needed after the call must still have distinct storage.
define void @keep_independent_storage() {
; CHECK-LABEL: define void @keep_independent_storage() {
; CHECK: %src = alloca [48 x i8]
; CHECK: %dst = alloca [48 x i8]
; CHECK-NOT: call void @forward_prefix
; CHECK: call void @llvm.memcpy.p0.p0.i64(ptr align 8 %dst, ptr align 8 %src, i64 48, i1 false)
; CHECK: store i8 7, ptr %src
; CHECK: call void @observe(ptr captures(none) %dst)
; CHECK: call void @observe(ptr captures(none) %src)
  %src = alloca [48 x i8], align 8
  %dst = alloca [48 x i8], align 8
  call void @produce(ptr captures(address) %src)
  call void @forward_prefix(ptr noalias %dst, ptr noalias %src)
  store i8 7, ptr %src
  call void @observe(ptr captures(none) %dst)
  call void @observe(ptr captures(none) %src)
  ret void
}
