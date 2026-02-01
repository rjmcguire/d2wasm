const fs = require('fs');
const wasmBuffer = fs.readFileSync('examples/fibonacci.wasm');

WebAssembly.instantiate(wasmBuffer).then(wasmModule => {
    const { fibonacci, main } = wasmModule.instance.exports;
    
    console.log('Testing fibonacci(10)...');
    const result = fibonacci(10);
    console.log('Result:', result);
    
    if (result === 55) {
        console.log('SUCCESS: fibonacci(10) is 55');
    } else {
        console.log('FAILURE: expected 55, got', result);
    }
    
    console.log('Testing main()...');
    const mainResult = main();
    console.log('Main Result:', mainResult);
    
    if (mainResult === 55) {
        console.log('SUCCESS: main() returned 55');
    } else {
        console.log('FAILURE: main() expected 55, got', mainResult);
    }
}).catch(err => {
    console.error('Error instantiating WASM:', err);
});
