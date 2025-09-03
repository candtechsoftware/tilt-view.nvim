// The module 'vscode' contains the VS Code extensibility API
// Import the module and reference it with the alias vscode in your code below
import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import { TiltViewItem, TiltViewProvider } from './tilt-view';

// This method is called when your extension is activated
// Your extension is activated the very first time the command is executed
export function activate(context: vscode.ExtensionContext) {
  // Use the console to output diagnostic information (console.log) and errors (console.error)
  // This line of code will only be executed once when your extension is activated
  console.log('Congratulations, your extension "vscode-tilt" is now active!');

  // Samples of `window.registerTreeDataProvider`
  const tiltViewProvider = new TiltViewProvider(context);
  vscode.window.registerTreeDataProvider('tiltViewServices', tiltViewProvider);
  // vscode.commands.registerCommand(
  //   'vscode-tilt.restartResource',
  //   (resource: TiltViewItem) => {
  //     console.log('resource restarted', resource);
  //   },
  // );
  // vscode.commands.registerCommand('nodeDependencies.refreshEntry', () =>
  //   nodeDependenciesProvider.refresh()
  // );
  // vscode.commands.registerCommand('extension.openPackageOnNpm', (moduleName) =>
  //   vscode.commands.executeCommand(
  //     'vscode.open',
  //     vscode.Uri.parse(`https://www.npmjs.com/package/${moduleName}`)
  //   )
  // );
  // vscode.commands.registerCommand('nodeDependencies.addEntry', () =>
  //   vscode.window.showInformationMessage(`Successfully called add entry.`)
  // );
  // vscode.commands.registerCommand('nodeDependencies.editEntry', (node: Dependency) =>
  //   vscode.window.showInformationMessage(`Successfully called edit entry on ${node.label}.`)
  // );
  // vscode.commands.registerCommand('nodeDependencies.deleteEntry', (node: Dependency) =>
  //   vscode.window.showInformationMessage(`Successfully called delete entry on ${node.label}.`)
  // );
}

// This method is called when your extension is deactivated
export function deactivate() {}
