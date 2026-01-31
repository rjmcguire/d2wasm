# The Architecture of Latency: Post-2024 Just-In-Time Compilation Paradigms

## 1\. Introduction: The Fragmentation of the JIT Monolith

The trajectory of Just-In-Time (JIT) compilation has historically bent toward a singular gravitational center: the "monolithic optimizing compiler." For nearly two decades, the prevailing architectural doctrine posited that the ultimate destiny of any dynamic language runtime—whether JavaScript, Python, or Ruby—was to eventually house a full-scale static compiler backend, typically LLVM, capable of generating near-native machine code at runtime. This "LLVM-or-bust" methodology, while successful in long-running server environments (e.g., the JVM’s HotSpot or V8’s TurboFan), has reached an inflection point in the post-2024 landscape. The computational cost of performing SSA (Static Single Assignment) construction, iterative dataflow analysis, and graph-coloring register allocation at runtime has become incompatible with the modern reality of ephemeral, serverless, and heterogeneous workloads.

We are currently witnessing a structural bifurcation in compiler architecture. The industry is moving away from general-purpose, high-latency compilers toward specialized, domain-driven architectures. This report analyzes three specific divergences from the traditional model: the "Copy-and-Patch" technique which reduces compilation to a memory-bound operation; the "Block-Based" IRs of AI compilers that align logical operations with hardware tile hierarchies; and the "Lazy Basic Block Versioning" (LBBV) approach that fragments control flow to manage dynamic typing without the catastrophic deoptimization penalties of the past.

These technologies represent a fundamental shift in engineering priorities: from maximizing peak theoretical throughput via exhaustive analysis, to minimizing "time-to-code" and "memory-to-code" latency. This analysis deconstructs the implementation mechanics, hardware implications, and future trajectories of these architectures, drawing on the developments in Python 3.13, OpenAI Triton, PyTorch 2.0, Ruby YJIT, and the WebAssembly ecosystem.

* * *

## 2\. The "Copy-and-Patch" Revolution: Python 3.13 and the Assembler-Free JIT

The introduction of the Copy-and-Patch JIT in Python 3.13 (via PEP 744) represents a rejection of the "tracing JIT" complexity that characterized previous failed attempts to accelerate CPython (e.g., Unladen Swallow, Pyston). Instead of attempting to lift Python bytecode into a high-level Intermediate Representation (IR) for optimization, Python 3.13 adopts a "template-based" strategy that effectively unrolls the interpreter loop into native machine code.

### 2.1 Implementation Mechanics: Stencils and Holes

The Copy-and-Patch architecture relies on a strict separation of concerns between **build-time** artifact generation and **run-time** code emission. This separation allows the heavy lifting of instruction selection and scheduling to be performed once by an optimizing static compiler (`clang` or `gcc`), rather than repeatedly by the JIT at runtime.

#### 2.1.1 Build-Time Stencil Generation

The process begins during the compilation of the CPython interpreter itself. The build system processes a file, `executor_cases.c.h`, which contains C implementations of Python's micro-opcodes. Unlike standard C compilation, these functions are compiled into separate object files with specific attributes to facilitate their later use as binary templates.

The architecture employs a domain-specific build tool (implemented in `Tools/jit/_targets.py` and `Tools/jit/template.c`) that parses the resulting ELF or Mach-O object files. This tool utilizes binary analysis (similar to `objdump`) to extract two critical components for each opcode:

1.  **The Instruction Body:** A contiguous sequence of machine code bytes representing the logic of the operation (e.g., reference counting, arithmetic, stack manipulation).
    
2.  **Relocation Holes:** A map of offsets within that instruction body where the static compiler has emitted placeholder values. These "holes" correspond to values that are unknown at build time, such as pointers to Python objects, jump targets, or specific immediate values.
    

These artifacts are serialized into a header file, `jit_stencils.h`. This header functions as a library of pre-compiled machine code fragments. For example, the stencil for `_BINARY_OP_ADD_INT` contains the optimized assembly sequence for adding two integers, including overflow checks and de-optimization guards, but with zeroed-out bytes where the instruction pointer relative offsets would normally reside.

#### 2.1.2 Runtime Copying and Patching

When the Python runtime identifies a "hot" trace (via the Tier 2 optimizer), it does not invoke a compiler. Instead, it triggers a memory-bound transcription process. The JIT engine allocates a page of executable memory (`mmap` with `PROT_READ | PROT_WRITE`, later flipped to `PROT_EXEC`).

The JIT then iterates through the optimized trace of micro-ops. For each micro-op, it performs a `memcpy` of the corresponding stencil from `jit_stencils.h` into the executable buffer. Immediately following the copy, the "patching" phase occurs. The JIT looks up the relocation holes associated with that stencil and overwrites the placeholder bytes with the actual runtime values.

Crucially, this architecture leverages the `__attribute__((preserve_none))` calling convention (supported by Clang) for the stencil functions. This attribute informs the C compiler that the function does not need to preserve any registers for the caller. This allows the generated machine code to utilize the full register file for temporary calculations, minimizing stack spills. When these stencils are concatenated, the resulting machine code resembles a continuous stream of instructions where the "register allocation" is implicitly handled by the static compiler's decisions during the build phase, scoped within the boundaries of each stencil.

### 2.2 Comparative Analysis: Copy-and-Patch vs. HaLVM and Template JITs

The resurgence of template-based JITs invites comparison to both traditional approaches and high-assurance systems like the HaLVM.

#### 2.2.1 Comparison with Traditional Template JITs

Traditional template JITs, common in early Java implementations and simple scripting engines, relied on hand-written assembly fragments. This approach was brittle; porting the JIT to a new architecture (e.g., RISC-V or ARM64) required rewriting every template in the target assembly language.

Python 3.13's Copy-and-Patch improves upon this by generating templates _from C code_. This provides portability and optimization "for free." When CPython is compiled on an ARM64 machine, the build tool automatically captures ARM64 machine code for the stencils. Furthermore, because the stencils are generated by `clang -O3`, they benefit from advanced instruction scheduling and vectorization that would be difficult to maintain in hand-written assembly.

#### 2.2.2 Comparison with HaLVM (High-assurance LLVM)

HaLVM (Haskell Lightweight Virtual Machine) represents the opposite end of the spectrum. It involves running the Glasgow Haskell Compiler (GHC) runtime directly on a hypervisor (Xen), often utilizing LLVM for rigorous, high-assurance code generation suitable for unikernels and safety-critical systems. HaLVM prioritizes correctness, type safety, and formal verification properties, often at the cost of a heavyweight compilation pipeline that is unsuited for rapid iterative development or low-latency startup.

The Copy-and-Patch approach is gaining traction now because it solves the "maintenance complexity" problem that plagues LLVM-based JITs in dynamic languages. Integrating LLVM into CPython (as Pyston did) introduces a dependency on millions of lines of C++ code, massive binary size increases, and complex build requirements. Copy-and-Patch offers a "good enough" speedup (estimated 2-9% on macro-benchmarks, higher on specific loops) with almost zero runtime dependency overhead. It acts as a baseline JIT that requires no compiler theory expertise to maintain—core developers simply write C code, and the build system handles the machine code extraction.

### 2.3 Constraint Analysis: Binary Size vs. Instruction Cache Pressure

While Copy-and-Patch avoids the compilation latency of LLVM, it introduces significant inefficiencies regarding binary size and instruction cache (i-cache) utilization.

#### 2.3.1 The Code Bloat Mechanism

LLVM-based JITs (like MCJIT or ORC) utilize a global view of the code to perform "deduplication" and "outlining." If a specific error-handling sequence is used in multiple places, LLVM can emit it once and jump to it. Copy-and-Patch, by definition, operates on a "splat" basis: it copies the full stencil for every occurrence of an opcode.

If a Python loop contains ten integer additions, the machine code for `_BINARY_OP_ADD_INT`—including its tag checks, reference count increments, and error paths—is copied ten times sequentially into the instruction stream. This results in generated code that is significantly larger than what a standard optimizing JIT would produce. Reports indicate an overhead increase of **20-30%** in memory usage when the JIT is enabled, largely driven by this code duplication.

#### 2.3.2 I-Cache Pressure Comparison

| **Metric** | **LLVM MCJIT / ORC** | **Copy-and-Patch (Python 3.13)** |
| --- | --- | --- |
| **Code Density** | **High.** Uses outlining, common subexpression elimination (CSE), and function calls for cold paths. | **Low.** Linear concatenation of full instruction sequences; minimal deduplication. |
| **I-Cache Locality** | **High.** Hot paths are compacted; cold paths are moved to separate pages (PGO-like layout). | **Poor.** Hot loops are interspersed with cold error-handling code "splatted" from stencils. |
| **Branch Prediction** | **Optimized.** Uses static branch probabilities to order basic blocks. | **Static.** Relies on the static layout of the C stencil; cannot reorder blocks based on runtime trace data. |
| **Binary Size Impact** | Moderate runtime growth; overhead is in the compiler data structures (IR). | Significant runtime growth; overhead is in the raw volume of executable machine code. |

**Implication:** The Copy-and-Patch JIT creates substantial pressure on the L1 instruction cache. The "unrolled" nature of the code means that a relatively simple Python loop can easily exceed the size of the L1 cache (typically 32KB), causing pipeline stalls as the CPU fetches instructions from L2. Unlike LLVM, which can perform "shrink wrapping" to minimize the register save/restore overhead for specific paths, Copy-and-Patch accepts the "generic" overhead of the stencil for every execution. This architectural limitation explains why performance gains are modest (2-9%); the reduction in dispatch overhead is partially offset by the increase in cache misses and memory bandwidth consumption.

* * *

## 3\. AI & GPU Compilers: The Block-Based Paradigm

The compilation challenges for AI workloads differ fundamentally from scalar scripting languages. The bottleneck is not instruction dispatch, but data movement and massive parallelism. This has necessitated a shift from scalar IRs (like LLVM IR) to "Block-Based" or "Tile-Based" IRs, as seen in OpenAI Triton and PyTorch 2.0.

### 3.1 Deconstructing OpenAI Triton's Intermediate Representation (IR)

Standard compiler infrastructures, including LLVM, operate on the **Single Instruction, Single Data (SISD)** or **Single Instruction, Multiple Data (SIMD)** model where the atomic unit of computation is a scalar value or a short vector (e.g., AVX-512). To target a GPU, these compilers must engage in complex "auto-vectorization" analysis to infer parallelism from loops.

#### 3.1.1 The Block-Based Programming Model

Triton abandons the scalar abstraction. In Triton's IR (based on MLIR), the fundamental atom is the **Tile** (or Block)—a statically shaped, multi-dimensional array. An operation in Triton does not add two floating-point numbers; it adds two tensors of dimensions $128 \\times 128$.

**IR Comparison:**

| **Feature** | **LLVM IR (Scalar SSA)** | **Triton IR (Block-Based MLIR)** |
| --- | --- | --- |
| **Atomic Unit** | `i32`, `float`, `<4 x float>` | `tensor<128x128xf32>` |
| **Memory Access** | `load`, `getelementptr` (pointer arithmetic) | `tt.load` (block load with mask) |
| **Parallelism** | Implicit (Recovered via LoopVectorize pass) | **Explicit** (Embedded in the type system) |
| **Synchronization** | Explicit barriers (`fence`) | Implicit (Data dependency between blocks) |
| **Optimization** | Loop Unrolling, LICM | **Layout Swizzling**, Shared Memory Banking |

#### 3.1.2 Mechanism: `tt.dot` and Layout Analysis

The semantic gap between scalar IR and GPU hardware is most visible in matrix multiplication. In LLVM, a matrix multiplication is a triply-nested loop. In Triton IR, it is a single instruction: `tt.dot`.

MLIR

    // Example Triton IR for Matrix Multiplication
    %a = tt.load %ptr_a : tensor<128x64xf16>
    %b = tt.load %ptr_b : tensor<64x128xf16>
    %c = tt.dot %a, %b, %acc : tensor<128x64xf16> * tensor<64x128xf16> -> tensor<128x128xf32>

This "Block-Based" model allows the compiler to reason about **Data Layouts** rather than just values. The Triton compiler performs a "Layout Analysis" pass. It determines how a `tensor<128x128>` should be distributed across the GPU's threads (warps). It might decide that `%a` should be stored in Shared Memory with a specific "swizzled" pattern to avoid bank conflicts, while `%c` resides in Registers. This optimization is mathematically impossible for a scalar compiler to derive reliably because the high-level intent (matrix multiplication) is lost after lowering to scalar loops.

By preserving the block semantics, Triton can lower `tt.dot` directly to the specialized PTX instructions for Tensor Cores (e.g., `mma.sync` on NVIDIA or `mfma` on AMD), ensuring maximum hardware utilization.

### 3.2 PyTorch 2.0 (TorchInductor): Fusion Logic and Backend Selection

TorchInductor serves as the high-level compiler for PyTorch, sitting above Triton. Its primary function is to solve the **Operator Fusion** problem. In Deep Learning, execution time is dominated by memory bandwidth (loading/storing tensors to HBM) rather than compute. Fusion combines multiple operators (e.g., `Add -> ReLU -> Log`) into a single kernel, reading inputs once and writing the final output once.

#### 3.2.1 Fusion Decision Matrix

TorchInductor utilizes a greedy, dependency-aware fusion algorithm. It analyzes the FX graph (a DAG of PyTorch operators) and attempts to group nodes into a single kernel based on the following logic :

1.  **Pointwise Operations:** Operations like `add`, `sub`, `relu`, `sin` are always candidates for fusion. They are "vertical" fusions that happen within the same thread.
    
2.  **Reduction Operations:** Operations like `sum` or `mean` are "horizontal" fusions. Inductor supports "Epilogue Fusion," where a pointwise op following a reduction (e.g., `softmax`) is fused into the reduction kernel.
    
3.  **Layout Constraints:** Fusion is broken if the stride patterns of the tensors are incompatible (e.g., trying to fuse a contiguous tensor operation with a channel-last tensor operation) unless a re-indexing cost is paid.
    

#### 3.2.2 Backend Emission: Triton vs. C++ Wrapper

Once the graph is partitioned into fused subgraphs, Inductor must decide which backend code to generate. This decision is driven by the device target and the presence of "Graph Breaks."

**1\. The GPU Path (Triton):** For NVIDIA and AMD GPUs, Inductor generates **Triton Kernels**. It writes a Python function decorated with `@triton.jit` that implements the fused logic using Triton's block semantics. It then generates a Python wrapper to launch this kernel.

-   _Why Triton?_ Writing fused kernels in raw CUDA/C++ is error-prone and verbose. Triton handles the indexing math and shared memory management automatically.
    

**2\. The CPU Path (C++ Wrapper):** For CPU execution, Inductor generates **C++ code** leveraging OpenMP for parallelism and AVX for vectorization. Crucially, it employs a **C++ Wrapper** (`cpp_wrapper`) mechanism.

-   _Mechanism:_ Instead of returning to Python to launch each kernel (which incurs Python interpreter overhead), Inductor generates a standalone C++ binary (shared library) that chains the kernel calls together. This removes the "Python Tax" entirely for the compiled subgraph.
    

**3\. Handling Graph Breaks:** A critical limitation is the "Graph Break." If Inductor encounters Python code it cannot trace (e.g., `if tensor.sum() > 0:` where the condition depends on data), it must split the graph.

-   **Result:** The pipeline is: `Compiled Kernel 1` -> `Python Interpreter (Check If)` -> `Compiled Kernel 2`.
    
-   **Penalty:** This forces a synchronization between the GPU and CPU, flushing the pipeline and destroying performance. The architecture prioritizes "graph capture" (using TorchDynamo) to minimize these breaks.
    

* * *

## 4\. Basic Block Versioning: Ruby YJIT and Dynamic Stability

While Python explores Copy-and-Patch and AI compilers explore Block-based IRs, Ruby's YJIT pioneers a different approach to handling dynamic languages: **Lazy Basic Block Versioning (LBBV)**. This technique addresses the "Type Instability" problem without the complexity of V8-style deoptimization.

### 4.1 Mechanics of Lazy Basic Block Versioning (LBBV)

In a dynamic language, a method like `def add(a, b); a + b; end` is structurally ambiguous. `a` and `b` could be Integers, Floats, Strings, or Arrays. A traditional Method-JIT (like V8 or the older Ruby MJIT) compiles the whole function assuming a specific type profile (e.g., Integers). If the assumption fails, the entire compilation is discarded (Deoptimization).

**LBBV Architecture:**

YJIT operates at the granularity of the **Basic Block** (a sequence of instructions with a single entry and exit), not the method.

1.  **Context Tracking:** When entering a block, YJIT tracks the _context_—specifically, the types of values on the stack and in local variables.
    
2.  **Stub Generation:** At the end of a block (e.g., a branch or call), YJIT does not compile the next block immediately. Instead, it emits a **Stub** (a small piece of machine code that calls back into the compiler).
    
3.  **Lazy Specialization:** When execution hits the stub, YJIT inspects the _current_ runtime types.
    
    -   If `a` is an Integer, it compiles a version of the destination block specialized for Integers.
        
    -   It then patches the jump in the previous block to point to this new version.
        

If the types change later (e.g., `a` becomes a String), YJIT does not deoptimize the previous code. It simply compiles a _new version_ of the target block specialized for Strings and leaves the original Integer version in memory. The branch instruction in the predecessor block is patched (or a polymorphic inline cache is used) to route execution to the correct version based on the runtime type.

### 4.2 Side Exits vs. Deoptimization

The contrast with V8 is stark. V8 uses "On-Stack Replacement" (OSR) to reconstruct the interpreter's stack frame when a type guard fails, effectively rewinding time. This is computationally expensive and requires complex metadata maps.

YJIT uses **Side Exits**. A side exit is a guard instruction (e.g., `test tag_bit, reg; jne side_exit`).

-   **Mechanism:** If the guard fails (e.g., an Integer overflow occurs, turning the result into a Float), execution jumps to a "side exit" handler.
    
-   **Flow:** This handler writes the current machine registers back into the Ruby Virtual Machine's stack structure (`rb_control_frame_t`) and jumps directly to the interpreter's instruction pointer corresponding to that location.
    
-   **Advantage:** Because LBBV maintains a 1:1 mapping between machine state and interpreter state at block boundaries, the "bailout" is nearly instantaneous. There is no complex stack reconstruction, only a register spill. This makes Ruby 3.4 highly resilient to "deopt loops" that plague other JITs.
    

### 4.3 Memory Footprint and Code GC

The trade-off for LBBV is memory fragmentation. A single Ruby method is no longer a contiguous chunk of machine code; it is a "cloud" of basic block versions scattered across the executable memory space, linked by jumps.

**The Long-Running Server Problem:**

In persistent processes (e.g., a Rails server running for days), the JIT accumulates "cold" versions—blocks that were compiled for initialization code or rare edge cases and never used again. In earlier versions, this led to unbounded memory growth until the JIT disabled itself.

**Ruby 3.4 Code GC:** To mitigate this, Ruby 3.4 introduced a **Code Garbage Collector**.

-   **Challenge:** You cannot simply `free()` a block of machine code because other blocks might jump to it.
    
-   **Solution:** The Code GC tracks the "liveness" of blocks using hardware access bits or software counters. When a page of code is deemed "cold," the GC patches all incoming jumps from "live" blocks to point back to the interpreter or a generic stub. Once isolated, the page can be reclaimed.
    
-   **Impact:** This allows YJIT to run within a fixed memory budget (configurable via `--yjit-exec-mem-size`, typically 256MB) without degrading performance over time, a critical requirement for containerized deployments.
    

* * *

## 5\. WebAssembly & Cranelift: The Register Allocation Compromise

Cranelift, the code generator behind the Wasmtime runtime, occupies a unique niche. It rejects the "compile time doesn't matter" philosophy of LLVM but demands higher code quality than a copy-and-patch baseline. The crux of its design is the **Register Allocator**.

### 5.1 Cranelift vs. LLVM: The Design Rift

LLVM's register allocator (Greedy or PBQP - Partitioned Boolean Quadratic Programming) is designed to squeeze every ounce of performance from the target CPU. It iterates multiple times over the interference graph, splitting live ranges aggressively to fit variables into registers. This is an NP-complete problem (graph coloring), and LLVM trades compilation time for execution speed.

Cranelift targets **WebAssembly**, where the compiler runs on the user's machine (in a browser or edge worker). "Compile bombs"—code that triggers exponential compilation time—are a denial-of-service vector. Therefore, Cranelift must guarantee linear (or near-linear) compilation time.

### 5.2 Mechanics of `regalloc2`

Cranelift employs a custom allocator named `regalloc2`. Its design is a **Decoupled Block-Local with Global Backtracking** approach.

-   **Bundling:** Instead of coloring a global graph, `regalloc2` groups operands that have strict constraints (e.g., x86 instructions requiring specific registers like `RAX` for division) into "bundles."
    
-   **Single-Pass Backtracking:** It processes code linearly. When it runs out of registers, instead of restarting a global analysis (like LLVM), it backtracks _locally_ within the current bundle to find a spill candidate. This limits the worst-case complexity.
    
-   **Liverange Splitting:** `regalloc2` splits live ranges at block boundaries. A variable might be in `Register A` in Block 1 and `Stack Slot B` in Block 2. LLVM would try to unify these; Cranelift accepts the cost of a `move` instruction to keep the allocation logic simple.
    

**Performance Characteristics:**

-   **Compilation Speed:** Cranelift is consistently **10x faster** to compile than LLVM.
    
-   **Execution Speed:** The generated code is roughly **80% as fast** as LLVM-optimized code. The gap comes from LLVM's superior handling of loop-invariant code motion and vectorization, which Cranelift (prioritizing safety and speed) performs less aggressively.
    
-   **Safety:** Written in Rust, Cranelift is memory-safe, eliminating a class of bugs (buffer overflows in the compiler itself) that have historically plagued C++ compilers like LLVM.
    

* * *

## 6\. Conclusion: The State of the Art Matrix

The post-2024 landscape demonstrates that the monolithic JIT era is over. Compiler architecture has become a function of the specific latency and granularity requirements of the workload.

### State of the Art Technology Matrix

| **Feature** | **Copy-and-Patch (Python 3.13)** | **Triton / TorchInductor** | **Ruby YJIT (LBBV)** | **Cranelift (Wasm)** | **LLVM (Reference)** |
| --- | --- | --- | --- | --- | --- |
| **Startup Latency** | **Instant** (< 1ms via `memcpy`) | Moderate (Seconds for kernel compile) | Fast (Lazy accumulation) | Fast (Tens of ms) | Slow (Seconds/Minutes) |
| **Peak Throughput** | Low (+5-10% over interp) | **Extreme** (GPU Native / Tensor Core) | Moderate (+20-40% over interp) | High (~80% of LLVM) | **Maximum** (Global Optimization) |
| **Granularity** | Instruction (Micro-op) | Block (Tensor Tile) | Basic Block (Instruction Sequence) | Function / Module | Module / LTO |
| **Memory Overhead** | **High** (Code Duplication/Bloat) | Moderate (Kernel Cache) | Moderate (Fragmentation/Poly-versions) | Low (Streamlined) | **Extreme** (IR + Analysis Data) |
| **Engineering Complexity** | **Low** (Assembler-free maintenance) | **High** (Requires deep GPU Arch knowledge) | **High** (Complex VM state integration) | Moderate (Rust safety benefits) | **Extreme** (Millions of LOC) |
| **Primary Use Case** | Baseline JIT for dynamic scripts | High-Performance AI/ML Kernels | Dynamic, Type-Unstable Server Workloads | Sandboxed/Edge Execution | Static AOT / Long-running Server |

### Future Trajectory

The trajectory is clear: **Hybridization**. We are moving toward systems that use Copy-and-Patch as a "Tier 1" JIT for instant startup, feeding into a "Tier 2" LBBV or Block-based JIT for hot paths, potentially reserving LLVM only for the rarest, long-running numerical kernels. The "Interpreter" as a distinct execution mode is fading; in its place is a spectrum of dynamic code generation strategies, ranging from the simple memory-copying of Python 3.13 to the sophisticated tile-swizzling of OpenAI Triton. The future of JIT is not about finding the best compiler, but about choosing the right _granularity_ of compilation for the millisecond in question.