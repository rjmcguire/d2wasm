#!/bin/bash
# Run dispatch benchmarks with different hierarchy sizes

set -e

cd "$(dirname "$0")"

# Build the generator
echo "Building hierarchy generator..."
ldc2 -O3 -of=generate_hierarchy generate_hierarchy.d

# Test configurations
CONFIGS=(
    "10 2"   # 10 + 100 = 110 types (shallow)
    "10 3"   # 10 + 100 + 1000 = 1110 types (medium)
    "5 4"    # 5 + 25 + 125 + 625 = 780 types (deeper, narrower)
    "4 5"    # 4 + 16 + 64 + 256 + 1024 = 1364 types (deep)
)

for config in "${CONFIGS[@]}"; do
    read -r branching depth <<< "$config"
    
    echo ""
    echo "=============================================="
    echo "Testing: branching=$branching, depth=$depth"
    echo "=============================================="
    
    # Generate hierarchy
    ./generate_hierarchy --branching $branching --depth $depth --output hierarchy_${branching}_${depth}.d
    
    # Combine with harness and compile
    cat hierarchy_${branching}_${depth}.d bench_harness.d > combined_${branching}_${depth}.d
    
    # Remove the version(Stub) block and module declarations for combined file
    sed -i '' '/^module /d' combined_${branching}_${depth}.d
    sed -i '' '/^version (Stub)/,/^}/d' combined_${branching}_${depth}.d
    
    echo "Compiling benchmark..."
    ldc2 -O3 -of=bench_${branching}_${depth} combined_${branching}_${depth}.d 2>/dev/null || {
        echo "Compilation failed, trying with less optimization..."
        ldc2 -O2 -of=bench_${branching}_${depth} combined_${branching}_${depth}.d
    }
    
    echo "Running benchmark..."
    ./bench_${branching}_${depth} --iterations 5000000
    
done

echo ""
echo "All benchmarks complete!"
