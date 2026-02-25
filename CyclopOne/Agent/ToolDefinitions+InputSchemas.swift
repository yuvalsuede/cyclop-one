import Foundation

// MARK: - ToolDefinitions + Input & Action Schemas

extension ToolDefinitions {

    // MARK: CGEvent / UI Input Schemas

    /// Tool schemas for CGEvent-based input: click, right_click, type_text,
    /// press_key, move_mouse, drag, scroll.
    static let inputSchemas: [ToolSchema] = [

        ToolSchema(
            name: "click",
            description: "Click at a position in the screenshot. Simulates a real human mouse click. The coordinates are automatically mapped to actual screen position. Always estimate the CENTER of the target element.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "X coordinate in the screenshot image (pixels from left)"
                    ],
                    "y": [
                        "type": "number",
                        "description": "Y coordinate in the screenshot image (pixels from top)"
                    ],
                    "double_click": [
                        "type": "boolean",
                        "description": "Double-click instead of single-click. Default false."
                    ],
                    "element_description": [
                        "type": "string",
                        "description": "Brief description of what you are clicking (e.g. 'Send button', 'Compose button', 'Delete icon'). Required."
                    ]
                ],
                "required": ["x", "y", "element_description"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "right_click",
            description: "Right-click (context menu) at a position in the screenshot.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "X coordinate in the screenshot"
                    ],
                    "y": [
                        "type": "number",
                        "description": "Y coordinate in the screenshot"
                    ]
                ],
                "required": ["x", "y"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "type_text",
            description: "Type text using keyboard events, exactly like a human typing. The text goes to whichever app/field is currently focused. Click the target field first to focus it.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The text to type"
                    ]
                ],
                "required": ["text"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "press_key",
            description: "Press a keyboard key or shortcut, like a human pressing keys. Use for Enter, Escape, Tab, arrow keys, or shortcuts like Cmd+S.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "key": [
                        "type": "string",
                        "description": "Key name: 'return', 'escape', 'tab', 'space', 'delete', 'up', 'down', 'left', 'right', 'f1'-'f8', or a single letter 'a'-'z'"
                    ],
                    "command": [
                        "type": "boolean",
                        "description": "Hold Command (\u{2318}). Default false."
                    ],
                    "shift": [
                        "type": "boolean",
                        "description": "Hold Shift. Default false."
                    ],
                    "option": [
                        "type": "boolean",
                        "description": "Hold Option (\u{2325}). Default false."
                    ],
                    "control": [
                        "type": "boolean",
                        "description": "Hold Control (\u{2303}). Default false."
                    ]
                ],
                "required": ["key"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "move_mouse",
            description: "Move the mouse cursor without clicking. Useful for hovering to reveal tooltips or dropdown menus.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "X coordinate in the screenshot"
                    ],
                    "y": [
                        "type": "number",
                        "description": "Y coordinate in the screenshot"
                    ]
                ],
                "required": ["x", "y"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "drag",
            description: "Click and drag from one point to another. Useful for moving windows, selecting text, resizing, slider controls, etc.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "from_x": [
                        "type": "number",
                        "description": "Start X in the screenshot"
                    ],
                    "from_y": [
                        "type": "number",
                        "description": "Start Y in the screenshot"
                    ],
                    "to_x": [
                        "type": "number",
                        "description": "End X in the screenshot"
                    ],
                    "to_y": [
                        "type": "number",
                        "description": "End Y in the screenshot"
                    ]
                ],
                "required": ["from_x", "from_y", "to_x", "to_y"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "scroll",
            description: "Scroll at a position. Positive delta_y scrolls up, negative scrolls down.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "X coordinate in the screenshot to scroll at"
                    ],
                    "y": [
                        "type": "number",
                        "description": "Y coordinate in the screenshot to scroll at"
                    ],
                    "delta_y": [
                        "type": "integer",
                        "description": "Scroll amount. Positive = up, negative = down. Default: -3 (scroll down 3 clicks)"
                    ]
                ],
                "required": ["x", "y"]
            ] as [String: Any]
        ),
    ]

    // MARK: Action Schemas

    /// Tool schemas for system actions: take_screenshot, run_applescript,
    /// open_application, run_shell_command, open_url.
    static let actionSchemas: [ToolSchema] = [

        ToolSchema(
            name: "take_screenshot",
            description: "Capture a fresh screenshot of the current screen. Call this after performing actions to see the updated state. The Cyclop One panel hides automatically so it won't appear in the screenshot.",
            inputSchema: [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "run_applescript",
            description: "Execute an AppleScript. Best for app-level control: opening apps, activating windows, clicking menus, getting/setting app properties.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "script": [
                        "type": "string",
                        "description": "The AppleScript source code to execute"
                    ]
                ],
                "required": ["script"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "open_application",
            description: "Open and activate a macOS application by name. This launches the app if it is not running, or brings it to the front if it is already open. Does not require a screenshot.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Application name (e.g., 'Google Chrome', 'Terminal', 'Safari', 'Finder', 'Visual Studio Code', 'Notes')"
                    ]
                ],
                "required": ["name"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "run_shell_command",
            description: "Execute a shell command in /bin/bash and return stdout, stderr, and exit code.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The shell command to execute"
                    ]
                ],
                "required": ["command"]
            ] as [String: Any]
        ),

        ToolSchema(
            name: "open_url",
            description: "Open a URL in the default web browser. This is the FASTEST and most reliable way to navigate to a website. The URL opens directly — no clicking the address bar or typing needed. Use this whenever the task involves going to a website. A screenshot is automatically taken after the page loads.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The full URL to open (e.g., 'https://apple.com', 'https://google.com/search?q=test'). Must include the protocol (https:// or http://)."
                    ],
                    "browser": [
                        "type": "string",
                        "description": "Optional: specific browser to use (e.g., 'Safari', 'Google Chrome'). If omitted, uses the system default browser."
                    ]
                ],
                "required": ["url"]
            ] as [String: Any]
        ),
    ]
}
