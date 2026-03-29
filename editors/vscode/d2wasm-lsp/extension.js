const path = require("path");
const fs = require("fs");
const vscode = require("vscode");
const {
  LanguageClient,
  ErrorAction,
  CloseAction,
} = require("vscode-languageclient/node");

/** @type {LanguageClient | undefined} */
let client;

/**
 * Find the d2wasm binary. Search order:
 * 1. d2wasm.compilerPath setting
 * 2. Workspace root (common during development)
 * 3. PATH
 */
function findCompiler() {
  const config = vscode.workspace.getConfiguration("d2wasm");
  const configPath = config.get("compilerPath");
  if (configPath && fs.existsSync(configPath)) {
    return configPath;
  }

  const workspaceFolders = vscode.workspace.workspaceFolders;
  if (workspaceFolders) {
    for (const folder of workspaceFolders) {
      const candidate = path.join(folder.uri.fsPath, "d2wasm");
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }

  return "d2wasm";
}

function activate(context) {
  const compilerPath = findCompiler();

  const config = vscode.workspace.getConfiguration("d2wasm");
  const extraArgs = config.get("extraArgs") || [];

  const outputChannel = vscode.window.createOutputChannel("D2WASM LSP");

  /** @type {import("vscode-languageclient/node").ServerOptions} */
  const serverOptions = {
    run: {
      command: compilerPath,
      args: ["--lsp", ...extraArgs],
    },
    debug: {
      command: compilerPath,
      args: ["--lsp", ...extraArgs],
    },
  };

  /** @type {import("vscode-languageclient/node").LanguageClientOptions} */
  const clientOptions = {
    documentSelector: [
      { scheme: "file", language: "d" },
      { scheme: "untitled", language: "d" },
    ],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.d"),
    },
    outputChannel,
    // Don't kill the server when it writes diagnostics/errors to stderr
    errorHandler: {
      error: (_error, _message, count) => {
        if (count < 5) return ErrorAction.Continue;
        return ErrorAction.Shutdown;
      },
      closed: () => CloseAction.Restart,
    },
  };

  client = new LanguageClient(
    "d2wasm",
    "D2WASM Language Server",
    serverOptions,
    clientOptions,
  );

  client.start();

  // Status bar indicator
  const statusBar = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right,
    100,
  );
  statusBar.text = "$(zap) D2WASM";
  statusBar.tooltip = "D2WASM Language Server active";
  statusBar.command = "d2wasm.restartServer";
  statusBar.show();
  context.subscriptions.push(statusBar);

  // Restart command
  const restartCmd = vscode.commands.registerCommand(
    "d2wasm.restartServer",
    async () => {
      if (client) {
        await client.restart();
        vscode.window.showInformationMessage("D2WASM LSP restarted");
      }
    },
  );
  context.subscriptions.push(restartCmd);
}

function deactivate() {
  if (client) {
    return client.stop();
  }
}

module.exports = { activate, deactivate };
