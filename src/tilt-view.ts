import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import z from 'zod';
import {
  $initialEvent,
  $logList,
  $uiResourceMetadata,
  $span,
  $uiResourceStatus,
  $uiResource,
  $uiButton,
  $restartPayload,
} from './types/tilt-websocket';
import { spawn } from 'child_process';

type Resource = z.infer<typeof $uiResource>;
type Button = z.infer<typeof $uiButton>;
type InitialEvent = z.infer<typeof $initialEvent>;

const ItemType = z.enum(['label', 'resource']);
type ItemType = z.infer<typeof ItemType>;
const $itemContext = z.discriminatedUnion('type', [
  z.object({
    type: z.literal(ItemType.enum.label),
    name: z.string(),
  }),
  z.object({
    type: z.literal(ItemType.enum.resource),
    name: z.string(),
    metadata: $uiResourceMetadata,
    status: $uiResourceStatus,
  }),
]);
type ItemContext = z.infer<typeof $itemContext>;

/**
 * @example
 * {
 *  "someLabel": {
 *   "someResource": { ...resourceData },
 *   "anotherResource": { ...resourceData },
 *  },
 *  "anotherLabel": {
 *   "yetAnotherResource": { ...resourceData },
 *   "itsAnotherResource": { ...resourceData },
 *  }
 * }
 */
type LabeledResources = Map<string, Map<string, Resource>>;
type Buttons = Map<string, z.infer<typeof $uiButton>>;

const UNLABELED = 'unlabeled' as const;

export class TiltViewProvider implements vscode.TreeDataProvider<TiltViewItem> {
  private _onDidChangeTreeData: vscode.EventEmitter<
    TiltViewItem | undefined | void
  > = new vscode.EventEmitter<TiltViewItem | undefined | void>();
  readonly onDidChangeTreeData: vscode.Event<TiltViewItem | undefined | void> =
    this._onDidChangeTreeData.event;

  private readonly socket: WebSocket;
  private readonly hostname: string;
  private readonly port: string | number;
  private isInitialized = false;
  private resources: Resource[] = [];
  private labeledResources: LabeledResources = new Map([
    [UNLABELED, new Map()],
  ]);
  private manifests: string[] = [];
  private buttons: Buttons = new Map();

  private get labels() {
    return [...this.labeledResources.keys()];
  }

  constructor(private readonly context: vscode.ExtensionContext) {
    console.log('Constructing TiltViewProvider');
    this.hostname = 'localhost';
    this.port = '10350';
    if (this.hostname.includes(':')) {
      const [hostname, port] = this.hostname.split(':');
      this.port = port ?? '10350';
      this.hostname = hostname;
    }
    this.restartResourceCommand = this.restartResourceCommand.bind(this);
    vscode.commands.registerCommand(
      'vscode-tilt.restartResource',
      this.restartResourceCommand,
    );
    this.socket = new WebSocket(`ws://${this.hostname}:${this.port}/ws/view`);
    this.socket.addEventListener('error', (...args) => {
      console.error('error', ...args);
    });
    this.socket.addEventListener('message', (event) => {
      const parsedData = JSON.parse(
        typeof event.data === 'string' ? event.data : '{}',
      );
      // 'isComplete' seems to only show up in the first websocket message, which is also
      // a full payload of all of the Tilt data, so it can be used to initialize everything.
      if ('isComplete' in parsedData) {
        const parsedEvent = $initialEvent.safeParse(parsedData);
        if (parsedEvent.success) {
          this.initialize(parsedEvent.data);
        } else {
          console.error('Unable to parse initial event', parsedEvent.error);
        }
      } else if ('uiResources' in parsedData) {
        const uiResources = z
          .array($uiResource)
          .safeParse(parsedData.uiResources);
        if (uiResources.success) {
          this.updateResources(uiResources.data);
        } else {
          console.error('Error while parsing uiResources:', uiResources.error);
        }
      }
      if ('uiButtons' in parsedData) {
        const uiButtons = z.array($uiButton).safeParse(parsedData.uiButtons);
        if (uiButtons.success) {
          this.updateButtons(uiButtons.data);
        } else {
          console.error('Error while parsing uiButtons:', uiButtons.error);
        }
      }
      this.refresh();
    });
  }

  refresh(): void {
    this._onDidChangeTreeData.fire();
  }

  async restartResourceCommand(resourceView: TiltViewItem): Promise<void> {
    // Need to start storing and managing `uiButtons` in websocket messages
    // uiButtons[n].metadata.resourceVersion seems to be an important thing
    if (!resourceView.resource) {
      console.error(
        "Resource tree item doesn't have a public 'resource' property for some reason. Resource tree item is:",
        resourceView,
      );
      return;
    }
    const name = resourceView.resource.metadata.name;
    try {
      const res = await fetch(
        `http://${this.hostname}:${this.port}/api/trigger`,
        {
          method: 'POST',
          body: JSON.stringify({
            manifest_names: [name],
            build_reason: 16,
          } satisfies z.infer<typeof $restartPayload>),
        },
      );
      if (!res.ok) {
        let body;
        try {
          body = await res.json();
        } catch {}
        console.error(
          'Tilt server responded with a non-OK status',
          res.status,
          body,
        );
      }
      console.log('Successfully restarted', name);
    } catch (error) {
      console.error(
        'Error thrown while sending a request to the /api/trigger endpoint',
        error,
      );
    }
  }

  getTreeItem(element: TiltViewItem): vscode.TreeItem {
    return element;
  }

  getChildren(element?: TiltViewItem): Thenable<TiltViewItem[]> {
    const DEFAULT = Promise.resolve([]);
    if (!element && !this.isInitialized) return DEFAULT;
    if (!element) return Promise.resolve(this.generateLabelParents());

    switch (element.contextValue) {
      case ItemType.enum.label: {
        const resources = this.labeledResources.get(element.itemContext.name);
        if (!resources) return DEFAULT;
        return Promise.resolve(
          [...resources.values()].map((resource) => {
            const itemContext: ItemContext = {
              type: 'resource',
              name: resource.metadata.name,
              metadata: resource.metadata,
              status: resource.status,
            };
            return new TiltViewItem(
              this.context.extensionUri,
              itemContext,
              vscode.TreeItemCollapsibleState.Collapsed,
              resource,
            );
          }),
        );
      }
      default:
        return DEFAULT;
    }
  }

  // region FOLLOWUP
  // When Tilt starts, the initial message is missing a lot of spans/manifests. Need to
  // test this and adjust.
  private initialize(initialEvent: InitialEvent): void {
    this.manifests = Object.values(initialEvent.logList.spans).reduce<string[]>(
      (acc, curr) => {
        const parsed = $span.safeParse(curr).data;
        if (parsed && parsed.manifestName) {
          return [...acc, parsed.manifestName];
        }
        return acc;
      },
      [] as string[],
    );
    this.resources = [...initialEvent.uiResources];
    this.updateResources(this.resources);
    this.updateButtons([...initialEvent.uiButtons]);
    this.isInitialized = true;
  }
  // endregion

  private updateResources(resources: Resource[]) {
    for (const resource of resources) {
      if (!resource.metadata.labels) {
        const unlabeled = this.labeledResources.get(UNLABELED)!;
        unlabeled.set(resource.metadata.uid, resource);
        continue;
      }
      for (const label of Object.keys(resource.metadata.labels)) {
        let labeled = this.labeledResources.get(label);
        if (!labeled) {
          labeled = new Map();
          this.labeledResources.set(label, labeled);
        }
        labeled.set(resource.metadata.uid, resource);
      }
    }
  }

  private updateButtons(buttons: Button[]) {
    for (const button of buttons) {
      this.buttons.set(button.metadata.name, button);
    }
  }

  private generateLabelParents(): TiltViewItem[] {
    try {
      return this.labels.map((name) => {
        const itemContext: ItemContext = { type: ItemType.enum.label, name };
        return new TiltViewItem(
          this.context.extensionUri,
          itemContext,
          vscode.TreeItemCollapsibleState.Expanded,
        );
      });
    } catch (error) {
      console.error(error);
      // vscode.env.clipboard.writeText(this.dataString || '');
      return [];
    }
  }
}

export class TiltViewItem extends vscode.TreeItem {
  constructor(
    public extensionRoot: vscode.Uri,
    public itemContext: ItemContext,
    public readonly collapsibleState: vscode.TreeItemCollapsibleState,
    public readonly resource?: Resource,
    public readonly command?: vscode.Command,
  ) {
    super(itemContext.name ?? '(No name)', collapsibleState);
    this.contextValue = itemContext.type;
    // this.tooltip = '';
    // this.description = '';
    if (itemContext.type === 'resource') {
      switch (itemContext.status.runtimeStatus) {
        case 'ok': {
          this.iconPath = new vscode.ThemeIcon('testing-passed-icon');
          break;
        }
        case 'error': {
          this.iconPath = new vscode.ThemeIcon('testing-failed-icon');
          break;
        }
        case 'pending': {
          this.iconPath = new vscode.ThemeIcon('testing-queued-icon');
          break;
        }
        default: {
          break;
        }
      }
    }
  }
}
