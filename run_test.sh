#!/bin/bash
# Test runner for D-to-WASM console output

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <d-file>"
    exit 1
fi

D_FILE="$1"
BASE_NAME=$(basename "$D_FILE" .d)
WAT_FILE="${BASE_NAME}.wat"
WASM_FILE="${BASE_NAME}.wasm"

echo "🔄 Compiling D to WAT..."
./d2wasm "$D_FILE" "$WAT_FILE"

echo "📝 Generated WAT:"
echo "----------------------------------------"
cat "$WAT_FILE"
echo "----------------------------------------"

echo ""
echo "🔄 Converting WAT to WASM..."
if ! command -v wat2wasm &> /dev/null; then
    echo "⚠️  wat2wasm not found. Please install wabt (WebAssembly Binary Toolkit)"
    echo "   brew install wabt"
    echo "   or download from: https://github.com/WebAssembly/wabt"
    exit 1
fi

wat2wasm "$WAT_FILE" -o "$WASM_FILE"

echo "✅ Generated WASM file: $WASM_FILE"

echo ""
echo "🚀 Running with JavaScript host..."

# Extract string literals from D file for runtime
# For now, we'll do this manually - in a real implementation, 
# the compiler would generate this information
STRING_LITERALS='{"1193031338":"Hello from D!","2006766244":"Program finished"}'

cd runtime
node host.js "../$WASM_FILE" "$STRING_LITERALS"

echo ""
echo "✅ Test completed!"