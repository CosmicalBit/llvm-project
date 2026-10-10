//===- InstructionSimplifyTest.cpp - Instruction simplification tests ----===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/InstructionSimplify.h"
#include "llvm/AsmParser/Parser.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/SourceMgr.h"
#include "gtest/gtest.h"

using namespace llvm;

TEST(InstructionSimplifyTest, ShuffleOfWideOutOfRangeInsert) {
  LLVMContext Context;
  SMDiagnostic Error;
  auto M = parseAssemblyString(R"(
    define <2 x i32> @test(<1 x i32> %v) {
      %insert = insertelement <1 x i32> %v, i32 42,
                              i128 18446744073709551616
      %shuffle = shufflevector <1 x i32> %insert, <1 x i32> poison,
                               <2 x i32> zeroinitializer
      ret <2 x i32> %shuffle
    }
  )",
                               Error, Context);
  ASSERT_TRUE(M);

  auto *F = M->getFunction("test");
  ASSERT_TRUE(F);
  auto *Shuffle = cast<ShuffleVectorInst>(
      cast<ReturnInst>(F->getEntryBlock().getTerminator())->getReturnValue());
  SimplifyQuery Q(M->getDataLayout());
  EXPECT_EQ(nullptr, simplifyShuffleVectorInst(
                         Shuffle->getOperand(0), Shuffle->getOperand(1),
                         Shuffle->getShuffleMask(), Shuffle->getType(), Q));
}
