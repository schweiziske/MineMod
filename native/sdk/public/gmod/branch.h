#ifndef GMOD_BRANCH_H
#define GMOD_BRANCH_H

// The public and beta engine branches expose different IAppSystem ABIs.
// Select exactly one default when compiling. The explicit Public/X86_64 types
// coexist for runtime branch selection; their engine pointers are not interchangeable.
#if !defined(_WIN32) || (!defined(_M_X64) && !defined(_M_IX86))
#error This SDK supports Windows x86 and x64 only.
#endif

#if defined(GMOD_SDK_PUBLIC) == defined(GMOD_SDK_X86_64)
#error Define exactly one of GMOD_SDK_PUBLIC or GMOD_SDK_X86_64.
#endif

#if defined(GMOD_SDK_X86_64) && !defined(_M_X64)
#error The x86-64 beta SDK requires Windows x64.
#endif

#endif // GMOD_BRANCH_H
