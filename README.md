# tilt-view.nvim

A Neovim plugin for managing [Tilt](https://tilt.dev) resources directly from your editor.

> **Note:** This is a Neovim port/fork of the excellent [vscode-tilt](https://github.com/JosefBud/vscode-tilt) VS Code extension by JosefBud.

## Important Notes

This plugin uses Tilt's internal HTTP/WebSocket API that is primarily designed for their web UI, not as a public API. As such:

- The implementation relies on reverse-engineered endpoints and message formats
- It may break with Tilt updates if their internal API changes
- Some features might not work with all Tiltfile configurations
- The plugin has been tested primarily with Docker Compose setups

If you encounter issues, please report them through GitHub Issues with reproducible examples. This helps improve compatibility across different Tilt configurations.

## Features
- View all Tilt resources in a floating window
- Categorized tabs
- Resource management: restart, enable, disable resources

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  ;candtechsoftware/tilt-view.nivm',
  config = function()
    require("tilt-view").setup()
  end
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'candtechsoftware/tilt-view.nvim',
  config = function()
    require("tilt-view").setup()
  end
}
```

## Usage

### Commands

- `:Tilt` - Open the Tilt resource viewer
- `:Tilt connect` - Manually connect to Tilt
- `:Tilt disconnect` - Disconnect from Tilt
- `:Tilt restart <resource>` - Restart a specific resource
- `:Tilt enable <resource>` - Enable a specific resource
- `:Tilt disable <resource>` - Disable a specific resource
- `:Tilt logs <resource>` - View resource logs

### Key Mappings (in Tilt window)

- `Tab` / `Shift-Tab` - Navigate between tabs
- `j` / `k` - Move up/down in resource list
- `Enter` - View resource details
- `r` - Restart resource
- `e` - Enable resource
- `d` - Disable resource (no confirmation)
- `l` - View resource logs
- `q` / `Esc` - Close window

## Configuration

```lua
require("tilt-view").setup({
  host = "localhost",  -- Tilt server host
  port = 10350,        -- Tilt server port
})
```

## Requirements

- Neovim 0.7.0 or higher
- [Tilt](https://tilt.dev) installed and running

## Resource Categorization

Resources are automatically categorized into tabs based on their type and name:
- **Services**: Docker Compose services and deployments
- **Libraries**: Resources with "lib" in the name
- **Tests**: Resources with "test" in the name
- **Unlabeled**: Resources that don't fit other categories
- **All**: All resources in one view

## Acknowledgments
This plugin is based on the [vscode-tilt](https://github.com/JosefBud/vscode-tilt) extension. Special thanks to JosefBud for the original implementation and WebSocket API research.
