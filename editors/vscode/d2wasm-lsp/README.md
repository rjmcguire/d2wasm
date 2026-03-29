# D2WASM VS Code Extension

D language support for VS Code powered by the d2wasm compiler's built-in LSP server.

## Features

- **Syntax highlighting** — D language TextMate grammar
- **Go to Definition** — jump to function/variable declarations
- **Hover** — see types on hover
- **Completion** — identifier and member completion (triggered by `.`)
- **Signature Help** — parameter hints (triggered by `(` and `,`)
- **Find References** — all usages of a symbol
- **Document Symbols** — outline view of functions, structs, classes
- **Rename** — rename symbols across the file
- **Code Lens** — reference counts on declarations
- **Semantic Tokens** — rich semantic highlighting
- **Call Hierarchy** — incoming/outgoing call navigation
- **Type Hierarchy** — super/sub type navigation
- **Code Actions** — quick fixes for diagnostics
- **Diagnostics** — compile errors shown inline on save

## Setup

### 1. Install dependencies

```bash
cd editors/vscode/d2wasm-lsp
npm install
```

### 2. Install the extension in VS Code

The easiest way during development is to symlink the extension into your VS Code extensions directory:

```bash
ln -s "$(pwd)/editors/vscode/d2wasm-lsp" ~/.vscode/extensions/d2wasm-lsp
```

Then **restart VS Code** (or run `Developer: Reload Window` from the command palette).

### 3. Open a `.d` file

The extension activates automatically when you open a `.d` file. It will look for the `d2wasm` binary in:

1. The `d2wasm.compilerPath` setting (if configured)
2. The workspace root directory
3. Your system `PATH`

## Configuration

| Setting | Default | Description |
|---|---|---|
| `d2wasm.compilerPath` | `""` | Absolute path to the `d2wasm` binary |
| `d2wasm.extraArgs` | `[]` | Extra CLI arguments for the LSP server |

## Commands

- **D2WASM: Restart Language Server** — restart the LSP (also available by clicking the ⚡ D2WASM status bar item)
