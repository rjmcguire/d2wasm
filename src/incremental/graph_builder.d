/**
 * Build a DeclDependencyGraph from a type-checked AST.
 *
 * This runs AFTER type checking, so resolved references are available:
 *   - UserType.declaration points to the actual StructDecl/ClassDecl/etc.
 *   - CallExpression.resolvedInstantiation points to the resolved FunctionDecl
 *   - Expression.type is populated for all expressions
 *   - BinaryExpression.loweredCall / UnaryExpression.loweredCall are set
 *
 * The graph builder:
 *   1. Registers every top-level declaration as a node (with byte range + hashes)
 *   2. Walks function bodies, struct members, etc. to record dependency edges
 */
module incremental.graph_builder;

import incremental.dep_graph;
import incremental.hasher;
import codegen.mangle : computeMangledName;
import ast.nodes;
import ast.expressions;
import ast.statements;

/**
 * Builds a DeclDependencyGraph from one or more modules' type-checked ASTs.
 */
class GraphBuilder {

    DeclDependencyGraph graph;

    /// Source text keyed by filename, for source hashing.
    private string[string] sourceTexts;

    /// Map from Declaration identity (cast to void*) to node ID, for dedup.
    private uint[void*] declToNode;

    /// Current module path, used for computing mangled names.
    private const(string)[] currentModulePath;

    /// Module path keyed by filename, for cross-module lazy registration.
    private const(string)[][string] modulePathsByFile;


    this() {
        graph = new DeclDependencyGraph();
    }

    /**
     * Build graph nodes and edges from a module's type-checked AST.
     *
     * Params:
     *   filename = source file path (used as spatial-index key)
     *   sourceText = full source text of the file (for source hashing)
     *   ast = top-level declarations (after type checking + mixin expansion)
     *   modulePath = module path for D ABI name mangling (e.g. ["test"])
     */
    void build(string filename, string sourceText, Declaration[] ast,
               const(string)[] modulePath = null) {
        sourceTexts[filename] = sourceText;
        currentModulePath = modulePath;
        if (modulePath !is null)
            modulePathsByFile[filename] = modulePath;

        // Pass 1: register all declarations as nodes
        foreach (decl; ast)
            registerDecl(decl, filename);

        // Pass 2: walk each declaration to record edges
        foreach (decl; ast)
            walkDecl(decl);
    }

    // ------------------------------------------------------------------
    //  Pass 1: Node registration
    // ------------------------------------------------------------------

    private uint registerDecl(Declaration decl, string filename) {
        // Dedup: if already registered, return existing ID
        auto key = cast(void*)decl;
        if (auto existing = key in declToNode)
            return *existing;

        uint startByte = decl.location.startOffset;
        uint endByte = decl.location.endOffset;
        string source = filename in sourceTexts ? sourceTexts[filename] : "";

        uint id;

        if (auto func = cast(FunctionDecl)decl) {
            if (func.isTemplate) return uint.max; // uninstantiated templates: skip
            ulong sigHash = hashFunctionSignature(func);
            ulong srcHash = hashSourceText(source, startByte, endByte);
            // Compute mangled name for cache key correlation
            string mname = "";
            auto modPath = filename in modulePathsByFile ? modulePathsByFile[filename] : currentModulePath;
            if (modPath !is null)
                mname = computeMangledName(modPath, func);
            id = graph.addNode(filename, startByte, endByte, func.name, "function", sigHash, srcHash, mname);
        }
        else if (auto sd = cast(StructDecl)decl) {
            ulong sigHash = hashStructSignature(sd);
            ulong srcHash = hashSourceText(source, startByte, endByte);
            id = graph.addNode(filename, startByte, endByte, sd.name, "struct", sigHash, srcHash);
            // Register methods as separate nodes
            foreach (member; sd.members) {
                if (auto mfunc = cast(FunctionDecl)member)
                    registerDecl(mfunc, filename);
            }
        }
        else if (auto cd = cast(ClassDecl)decl) {
            ulong sigHash = hashStructSignature(cd); // same hash: fields + alias this
            ulong srcHash = hashSourceText(source, startByte, endByte);
            id = graph.addNode(filename, startByte, endByte, cd.name, "class", sigHash, srcHash);
            foreach (member; cd.members) {
                if (auto mfunc = cast(FunctionDecl)member)
                    registerDecl(mfunc, filename);
            }
        }
        else if (auto mc = cast(ManifestConstantDecl)decl) {
            ulong sigHash = hashManifestSignature(mc);
            ulong srcHash = hashSourceText(source, startByte, endByte);
            id = graph.addNode(filename, startByte, endByte, mc.name, "manifest", sigHash, srcHash);
        }
        else if (auto td = cast(TemplateDecl)decl) {
            ulong sigHash = hashTemplateSignature(td);
            ulong srcHash = hashSourceText(source, startByte, endByte);
            id = graph.addNode(filename, startByte, endByte, td.name, "template", sigHash, srcHash);
        }
        else if (auto vd = cast(VariableDecl)decl) {
            ulong sigHash = hashGlobalSignature(vd);
            ulong srcHash = hashSourceText(source, startByte, endByte);
            id = graph.addNode(filename, startByte, endByte, vd.name, "global", sigHash, srcHash);
        }
        else {
            // ImportDecl, ModuleDecl, AliasDecl, etc. — not tracked as nodes
            return uint.max;
        }

        declToNode[key] = id;
        return id;
    }

    /// Look up (or lazily register) the node ID for a declaration.
    private uint nodeIdFor(Declaration decl) {
        if (decl is null) return uint.max;
        auto key = cast(void*)decl;
        if (auto p = key in declToNode)
            return *p;
        // Try to register it (may come from a different module)
        string fname = decl.location.filename;
        if (fname.length == 0) return uint.max;
        return registerDecl(decl, fname);
    }

    // ------------------------------------------------------------------
    //  Pass 2: Edge recording
    // ------------------------------------------------------------------

    private void walkDecl(Declaration decl) {
        auto ownerId = nodeIdFor(decl);
        if (ownerId == uint.max) return;

        if (auto func = cast(FunctionDecl)decl) {
            walkFunction(ownerId, func);
        }
        else if (auto sd = cast(StructDecl)decl) {
            walkStruct(ownerId, sd);
        }
        else if (auto cd = cast(ClassDecl)decl) {
            walkClass(ownerId, cd);
        }
        else if (auto mc = cast(ManifestConstantDecl)decl) {
            // Manifest initializer may reference other decls
            if (mc.initializer !is null)
                walkExpression(ownerId, mc.initializer);
        }
        else if (auto vd = cast(VariableDecl)decl) {
            walkType(ownerId, vd.type);
            if (vd.initializer !is null)
                walkExpression(ownerId, vd.initializer);
        }
    }

    private void walkFunction(uint funcId, FunctionDecl func) {
        // Return type
        walkType(funcId, func.returnType);

        // Parameter types
        foreach (param; func.parameters)
            walkType(funcId, param.type);

        // Method → parent struct/class edge
        if (func.parent !is null) {
            auto parentId = nodeIdFor(func.parent);
            if (parentId != uint.max)
                graph.addEdge(funcId, parentId, EdgeKind.methodOf);
        }

        // Body
        if (func.body_ !is null)
            walkStatement(funcId, func.body_);
    }

    private void walkStruct(uint structId, StructDecl sd) {
        // Field types → usesType edges
        foreach (field; sd.fields)
            walkType(structId, field.type);

        // Members: methods get methodOf edge, recurse
        foreach (member; sd.members) {
            if (auto mfunc = cast(FunctionDecl)member) {
                auto mid = nodeIdFor(mfunc);
                if (mid != uint.max)
                    graph.addEdge(mid, structId, EdgeKind.methodOf);
                walkFunction(mid, mfunc);
            }
        }
    }

    private void walkClass(uint classId, ClassDecl cd) {
        // Base class
        walkType(classId, cd.baseClass);

        // Interfaces
        foreach (iface; cd.interfaces)
            walkType(classId, iface);

        // Field types
        foreach (field; cd.fields)
            walkType(classId, field.type);

        // Members
        foreach (member; cd.members) {
            if (auto mfunc = cast(FunctionDecl)member) {
                auto mid = nodeIdFor(mfunc);
                if (mid != uint.max)
                    graph.addEdge(mid, classId, EdgeKind.methodOf);
                walkFunction(mid, mfunc);
            }
        }
    }

    // ------------------------------------------------------------------
    //  Type walking — usesType edges
    // ------------------------------------------------------------------

    private void walkType(uint ownerId, Type type) {
        if (type is null) return;

        if (auto ut = cast(UserType)type) {
            if (ut.declaration !is null) {
                auto targetId = nodeIdFor(ut.declaration);
                if (targetId != uint.max)
                    graph.addEdge(ownerId, targetId, EdgeKind.usesType);
            }
            // Template args
            if (ut.templateArgs !is null) {
                foreach (ta; ut.templateArgs)
                    walkType(ownerId, ta);
            }
        }
        else if (auto at = cast(ArrayType)type) {
            walkType(ownerId, at.elementType);
        }
        else if (auto pt = cast(PointerType)type) {
            walkType(ownerId, pt.pointeeType);
        }
        else if (auto ft = cast(FunctionType)type) {
            walkType(ownerId, ft.returnType);
            foreach (p; ft.parameterTypes)
                walkType(ownerId, p);
        }
        // BasicType: no edges
    }

    // ------------------------------------------------------------------
    //  Statement walking
    // ------------------------------------------------------------------

    private void walkStatement(uint ownerId, Statement stmt) {
        if (stmt is null) return;

        if (auto cs = cast(CompoundStatement)stmt) {
            foreach (s; cs.statements)
                walkStatement(ownerId, s);
        }
        else if (auto ifs = cast(IfStatement)stmt) {
            walkExpression(ownerId, ifs.condition);
            walkStatement(ownerId, ifs.thenStatement);
            walkStatement(ownerId, ifs.elseStatement);
        }
        else if (auto ws = cast(WhileStatement)stmt) {
            walkExpression(ownerId, ws.condition);
            walkStatement(ownerId, ws.body_);
        }
        else if (auto fs = cast(ForStatement)stmt) {
            walkStatement(ownerId, fs.init);
            walkExpression(ownerId, fs.condition);
            walkExpression(ownerId, fs.update);
            walkStatement(ownerId, fs.body_);
        }
        else if (auto rs = cast(ReturnStatement)stmt) {
            walkExpression(ownerId, rs.value);
        }
        else if (auto es = cast(ExpressionStatement)stmt) {
            walkExpression(ownerId, es.expression);
        }
        else if (auto vds = cast(VariableDeclarationStatement)stmt) {
            walkType(ownerId, vds.type);
            walkExpression(ownerId, vds.initializer);
        }
        else if (auto ms = cast(MixinStatement)stmt) {
            walkExpression(ownerId, ms.mixinExpr);
            if (ms.expandedStatements !is null) {
                foreach (s; ms.expandedStatements)
                    walkStatement(ownerId, s);
            }
        }
        else if (auto sds = cast(StructDeclarationStatement)stmt) {
            if (sds.structDecl !is null) {
                auto innerStructId = nodeIdFor(sds.structDecl);
                if (innerStructId != uint.max) {
                    graph.addEdge(ownerId, innerStructId, EdgeKind.usesType);
                    walkStruct(innerStructId, sds.structDecl);
                }
            }
        }
        else if (auto ts = cast(TryStatement)stmt) {
            walkStatement(ownerId, ts.tryBody);
            foreach (c; ts.catches) {
                walkType(ownerId, c.exceptionType);
                walkStatement(ownerId, c.body_);
            }
            walkStatement(ownerId, ts.finallyBody);
        }
        // BreakStatement, ContinueStatement: no edges
    }

    // ------------------------------------------------------------------
    //  Expression walking
    // ------------------------------------------------------------------

    private void walkExpression(uint ownerId, Expression expr) {
        if (expr is null) return;

        if (auto call = cast(CallExpression)expr) {
            walkCallExpression(ownerId, call);
        }
        else if (auto tie = cast(TemplateInstantiationExpression)expr) {
            walkTemplateInstantiation(ownerId, tie);
        }
        else if (auto bin = cast(BinaryExpression)expr) {
            // Check lowered call first (shift operators → opShiftLeft, etc.)
            if (bin.loweredCall !is null)
                walkExpression(ownerId, bin.loweredCall);
            walkExpression(ownerId, bin.left);
            walkExpression(ownerId, bin.right);
        }
        else if (auto un = cast(UnaryExpression)expr) {
            if (un.loweredCall !is null)
                walkExpression(ownerId, un.loweredCall);
            walkExpression(ownerId, un.operand);
        }
        else if (auto assign = cast(AssignmentExpression)expr) {
            if (assign.loweredCall !is null)
                walkExpression(ownerId, assign.loweredCall);
            walkExpression(ownerId, assign.left);
            walkExpression(ownerId, assign.right);
        }
        else if (auto idx = cast(IndexExpression)expr) {
            walkExpression(ownerId, idx.array);
            walkExpression(ownerId, idx.index);
            if (idx.opIndexMethod !is null) {
                auto mid = nodeIdFor(idx.opIndexMethod);
                if (mid != uint.max)
                    graph.addEdge(ownerId, mid, EdgeKind.calls);
            }
        }
        else if (auto sl = cast(SliceExpression)expr) {
            walkExpression(ownerId, sl.array);
            walkExpression(ownerId, sl.start);
            walkExpression(ownerId, sl.end);
        }
        else if (auto mem = cast(MemberExpression)expr) {
            walkExpression(ownerId, mem.object);
            // The resolved type of the member may reference a struct/class
            if (expr.type !is null)
                walkType(ownerId, expr.type);
        }
        else if (auto ident = cast(IdentifierExpression)expr) {
            if (ident.declaration !is null) {
                if (auto mc = cast(ManifestConstantDecl)ident.declaration) {
                    auto mid = nodeIdFor(mc);
                    if (mid != uint.max)
                        graph.addEdge(ownerId, mid, EdgeKind.readsManifest);
                }
            }
            // Also check the resolved type for type dependencies
            if (expr.type !is null)
                walkType(ownerId, expr.type);
        }
        else if (auto cast_ = cast(CastExpression)expr) {
            walkType(ownerId, cast_.targetType);
            walkExpression(ownerId, cast_.expression);
        }
        else if (auto arr = cast(ArrayLiteralExpression)expr) {
            foreach (elem; arr.elements)
                walkExpression(ownerId, elem);
        }
        else if (auto ne = cast(NewExpression)expr) {
            walkType(ownerId, ne.allocatedType);
            if (ne.resolvedStruct !is null) {
                auto sid = nodeIdFor(ne.resolvedStruct);
                if (sid != uint.max)
                    graph.addEdge(ownerId, sid, EdgeKind.usesType);
            }
            if (ne.resolvedClass !is null) {
                auto cid = nodeIdFor(ne.resolvedClass);
                if (cid != uint.max)
                    graph.addEdge(ownerId, cid, EdgeKind.usesType);
            }
            foreach (arg; ne.arguments)
                walkExpression(ownerId, arg);
        }
        else if (auto fle = cast(FunctionLiteralExpression)expr) {
            // Lambda: if lifted, record call to lifted function
            if (fle.liftedFunction !is null) {
                auto lid = nodeIdFor(fle.liftedFunction);
                if (lid != uint.max)
                    graph.addEdge(ownerId, lid, EdgeKind.calls);
            }
            if (fle.body_ !is null)
                walkStatement(ownerId, fle.body_);
        }
        else if (auto is_ = cast(IsExpression)expr) {
            walkType(ownerId, is_.checkedType);
            walkType(ownerId, is_.specType);
        }
        else if (auto traits = cast(TraitsExpression)expr) {
            if (traits.typeArguments !is null) {
                foreach (ta; traits.typeArguments)
                    walkType(ownerId, ta);
            }
            if (traits.arguments !is null) {
                foreach (arg; traits.arguments)
                    walkExpression(ownerId, arg);
            }
        }
        else if (auto te = cast(ThrowExpression)expr) {
            walkExpression(ownerId, te.operand);
        }
        // LiteralExpression, ImportExpression: no dependency edges
    }

    private void walkCallExpression(uint ownerId, CallExpression call) {
        // Resolve the call target
        if (call.resolvedInstantiation !is null) {
            // IFTI or explicit template call
            auto targetId = nodeIdFor(call.resolvedInstantiation);
            if (targetId != uint.max)
                graph.addEdge(ownerId, targetId, EdgeKind.calls);
        }
        else if (auto ident = cast(IdentifierExpression)call.function_) {
            // Direct call by name — try to find the declaration via type
            if (ident.declaration !is null) {
                auto targetId = nodeIdFor(ident.declaration);
                if (targetId != uint.max)
                    graph.addEdge(ownerId, targetId, EdgeKind.calls);
            }
        }

        // Walk callee expression (for method calls via MemberExpression, etc.)
        walkExpression(ownerId, call.function_);

        // Walk arguments
        foreach (arg; call.arguments)
            walkExpression(ownerId, arg);
    }

    private void walkTemplateInstantiation(uint ownerId, TemplateInstantiationExpression tie) {
        if (tie.resolvedInstantiation !is null) {
            auto targetId = nodeIdFor(tie.resolvedInstantiation);
            if (targetId != uint.max)
                graph.addEdge(ownerId, targetId, EdgeKind.calls);
        }
        if (tie.resolvedStructInstantiation !is null) {
            auto targetId = nodeIdFor(tie.resolvedStructInstantiation);
            if (targetId != uint.max)
                graph.addEdge(ownerId, targetId, EdgeKind.usesType);
        }

        // Template type arguments
        if (tie.templateArguments !is null) {
            foreach (ta; tie.templateArguments)
                walkType(ownerId, ta);
        }

        // Call arguments
        if (tie.callArguments !is null) {
            foreach (arg; tie.callArguments)
                walkExpression(ownerId, arg);
        }
    }
}
