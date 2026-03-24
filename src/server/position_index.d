/**
 * Position Index — maps cursor positions to AST nodes in O(log n).
 *
 * Built by walking the AST once after type checking. Stores all nodes
 * sorted by byte offset for binary search. Returns the innermost
 * (most specific) node containing a given cursor position.
 */
module server.position_index;

import ast.nodes;
import ast.expressions;
import ast.statements;

/// An entry in the position index
struct IndexEntry {
    uint startByte;
    uint endByte;
    ASTNode node;
}

/**
 * Position index for a single file. Sorted by startByte for binary search.
 */
class PositionIndex {
    private IndexEntry[] entries;

    /// Build the index from a module's AST
    void build(Declaration[] ast) {
        entries = null;
        foreach (decl; ast)
            collectNode(decl);

        // Sort by startByte, then by endByte descending (larger ranges first)
        import std.algorithm : sort;
        entries.sort!((a, b) {
            if (a.startByte != b.startByte)
                return a.startByte < b.startByte;
            return a.endByte > b.endByte;  // larger range first
        });
    }

    /// Find the innermost AST node at a byte offset.
    /// Returns null if no node contains the position.
    ASTNode findAt(uint byteOffset) {
        ASTNode best = null;
        uint bestSpan = uint.max;

        // Binary search for the first entry that could contain this offset
        size_t lo = 0, hi = entries.length;
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (entries[mid].startByte > byteOffset)
                hi = mid;
            else
                lo = mid + 1;
        }

        // Walk backward from the insertion point to find containing nodes
        foreach_reverse (i; 0 .. lo) {
            auto e = &entries[i];
            if (e.startByte > byteOffset)
                continue;
            if (e.endByte <= byteOffset)
                continue;  // doesn't contain position

            // This node contains the position — is it the smallest?
            uint span = e.endByte - e.startByte;
            if (span < bestSpan) {
                bestSpan = span;
                best = e.node;
            }

            // If we've passed nodes that start before our window, stop
            if (byteOffset - e.startByte > 10000)
                break;
        }

        return best;
    }

    /// Find the declaration at a byte offset (skips expressions).
    Declaration findDeclAt(uint byteOffset) {
        auto node = findAt(byteOffset);
        if (auto decl = cast(Declaration)node)
            return decl;
        return null;
    }

    /// Find the expression at a byte offset.
    Expression findExprAt(uint byteOffset) {
        // Look for the innermost expression
        Expression best = null;
        uint bestSpan = uint.max;

        size_t lo = 0, hi = entries.length;
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (entries[mid].startByte > byteOffset)
                hi = mid;
            else
                lo = mid + 1;
        }

        foreach_reverse (i; 0 .. lo) {
            auto e = &entries[i];
            if (e.startByte > byteOffset) continue;
            if (e.endByte <= byteOffset) continue;

            if (auto expr = cast(Expression)e.node) {
                uint span = e.endByte - e.startByte;
                if (span < bestSpan) {
                    bestSpan = span;
                    best = expr;
                }
            }

            if (byteOffset - e.startByte > 10000) break;
        }

        return best;
    }

    /// Number of indexed nodes
    size_t length() const { return entries.length; }

    private void collectNode(ASTNode node) {
        if (node is null) return;
        auto loc = node.location;
        if (loc.startOffset < loc.endOffset) {
            entries ~= IndexEntry(loc.startOffset, loc.endOffset, node);
        }

        // Recurse into children based on node type
        if (auto decl = cast(Declaration)node)
            collectDecl(decl);
        else if (auto stmt = cast(Statement)node)
            collectStmt(stmt);
        else if (auto expr = cast(Expression)node)
            collectExpr(expr);
    }

    private void collectDecl(Declaration decl) {
        if (auto funcDecl = cast(FunctionDecl)decl) {
            foreach (param; funcDecl.parameters)
                collectNode(param.type);
            if (funcDecl.body_)
                collectNode(funcDecl.body_);
        } else if (auto aggDecl = cast(AggregateDecl)decl) {
            foreach (member; aggDecl.members)
                collectNode(member);
        } else if (auto varDecl = cast(VariableDecl)decl) {
            if (varDecl.initializer)
                collectNode(varDecl.initializer);
        } else if (auto manifestDecl = cast(ManifestConstantDecl)decl) {
            if (manifestDecl.initializer)
                collectNode(manifestDecl.initializer);
        }
    }

    private void collectStmt(Statement stmt) {
        if (auto compound = cast(CompoundStatement)stmt) {
            foreach (s; compound.statements)
                collectNode(s);
        } else if (auto exprStmt = cast(ExpressionStatement)stmt) {
            collectNode(exprStmt.expression);
        } else if (auto retStmt = cast(ReturnStatement)stmt) {
            if (retStmt.value)
                collectNode(retStmt.value);
        } else if (auto ifStmt = cast(IfStatement)stmt) {
            collectNode(ifStmt.condition);
            collectNode(ifStmt.thenStatement);
            if (ifStmt.elseStatement)
                collectNode(ifStmt.elseStatement);
        } else if (auto whileStmt = cast(WhileStatement)stmt) {
            collectNode(whileStmt.condition);
            collectNode(whileStmt.body_);
        } else if (auto forStmt = cast(ForStatement)stmt) {
            if (forStmt.init)
                collectNode(forStmt.init);
            if (forStmt.condition)
                collectNode(forStmt.condition);
            if (forStmt.update)
                collectNode(forStmt.update);
            collectNode(forStmt.body_);
        } else if (auto varDeclStmt = cast(VariableDeclarationStatement)stmt) {
            if (varDeclStmt.initializer)
                collectNode(varDeclStmt.initializer);
        }
    }

    private void collectExpr(Expression expr) {
        if (auto binExpr = cast(BinaryExpression)expr) {
            collectNode(binExpr.left);
            collectNode(binExpr.right);
        } else if (auto unaryExpr = cast(UnaryExpression)expr) {
            collectNode(unaryExpr.operand);
        } else if (auto callExpr = cast(CallExpression)expr) {
            collectNode(callExpr.function_);
            foreach (arg; callExpr.arguments)
                collectNode(arg);
        } else if (auto memberExpr = cast(MemberExpression)expr) {
            collectNode(memberExpr.object);
        } else if (auto assignExpr = cast(AssignmentExpression)expr) {
            collectNode(assignExpr.left);
            collectNode(assignExpr.right);
        } else if (auto castExpr = cast(CastExpression)expr) {
            collectNode(castExpr.expression);
        } else if (auto indexExpr = cast(IndexExpression)expr) {
            collectNode(indexExpr.array);
            collectNode(indexExpr.index);
        }
    }
}
