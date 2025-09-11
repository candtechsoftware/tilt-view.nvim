// The module 'vscode' contains the VS Code extensibility API
// Import the module and reference it with the alias vscode in your code below
import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import { TiltViewItem, TiltViewProvider } from './tilt-view';

export function activate(context: vscode.ExtensionContext) {
  console.log('vscode-tilt-view activated');

  const tiltViewProvider = new TiltViewProvider(context);
  vscode.window.registerTreeDataProvider('tiltViewServices', tiltViewProvider);
}

export function deactivate() {}
