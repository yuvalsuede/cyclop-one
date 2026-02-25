import Foundation

// MARK: - SkillRegistryBuiltIn

/// Provides hardcoded built-in skill packages (same as legacy SkillLoader.builtInSkills()
/// plus 3 new social/communication skills).
enum SkillRegistryBuiltIn {

    // MARK: - Built-in Packages

    static func builtInPackages() -> [SkillPackage] {
        return [
            makePackage(
                name: "web-search",
                version: "1.0.0",
                description: "Open Safari, perform a web search, and return the results.",
                triggers: [
                    #"(?i)\b(search|google|look\s*up|find\s+online|web\s+search)\b"#,
                    #"(?i)\bsearch\s+(for|the\s+web)\b"#
                ],
                steps: [
                    "Open Safari using the open_application tool",
                    "Click the address/search bar (usually top center of the browser window)",
                    "Type the search query using type_text",
                    "Press Return to execute the search",
                    "Take a screenshot to see the results",
                    "Read and summarize the top results visible on screen"
                ],
                permissions: ["network"],
                maxIterations: 15
            ),
            makePackage(
                name: "file-organizer",
                version: "1.0.0",
                description: "Organize the Downloads folder by sorting files into subfolders by type.",
                triggers: [
                    #"(?i)\b(organize|clean\s*up|sort|tidy)\s+(downloads|my\s+downloads)\b"#,
                    #"(?i)\bdownloads?\s+(folder|directory)\s+(organiz|clean|sort|tidy)"#
                ],
                steps: [
                    "List the contents of ~/Downloads using run_shell_command: ls -la ~/Downloads",
                    "Identify file types present (images, documents, archives, videos, etc.)",
                    "Create category subdirectories if they don't exist: Images, Documents, Archives, Videos, Audio, Other",
                    "Move files into the appropriate category folders using mv commands",
                    "List the organized structure to confirm",
                    "Report a summary of what was moved"
                ],
                permissions: ["filesystem", "shell"],
                maxIterations: 15
            ),
            makePackage(
                name: "app-launcher",
                version: "1.0.0",
                description: "Open and configure applications by name with optional setup steps.",
                triggers: [
                    #"(?i)\b(open|launch|start)\s+(\w+)\s+(and|then|with)\s+"#,
                    #"(?i)\b(set\s*up|configure|prepare)\s+(\w+)\s+(for|to)\b"#
                ],
                steps: [
                    "Open the requested application using open_application or run_applescript",
                    "Wait for the application to finish launching (take a screenshot to verify)",
                    "If configuration was requested, navigate to the appropriate settings or interface",
                    "Apply the requested configuration changes using click, type_text, or keyboard shortcuts",
                    "Take a final screenshot to confirm the app is open and configured as requested"
                ],
                permissions: [],
                maxIterations: 15
            ),
            makePackage(
                name: "gmail-compose",
                version: "1.0.0",
                description: "Compose and send an email via Gmail in Chrome or Safari.",
                triggers: [
                    #"(?i)\b(send|compose|write)\s+(an?\s+)?email\b"#,
                    #"(?i)\bemail\s+to\b"#,
                    #"(?i)\bdraft\s+(an?\s+)?email\b"#
                ],
                steps: [
                    "Open Chrome or the default browser using open_application",
                    "Navigate to https://mail.google.com — type it in the address bar and press Return",
                    "Wait for Gmail to load, then click the 'Compose' button (pencil icon, top-left area)",
                    "In the 'To' field, type the recipient email address",
                    "Press Tab to move to the Subject field; take a screenshot between each Tab press to verify focus",
                    "Type the email subject",
                    "Press Tab again to move to the message body; take a screenshot to verify focus",
                    "Type the email body content",
                    "Review the email by taking a screenshot, then click the 'Send' button (bottom-left of compose window)",
                    "Take a final screenshot to confirm the email was sent (look for 'Message sent' banner)"
                ],
                permissions: ["network"],
                maxIterations: 20
            ),
            makePackage(
                name: "whatsapp-send",
                version: "1.0.0",
                description: "Send a WhatsApp message to a contact or group via WhatsApp Web.",
                triggers: [
                    #"(?i)\bwhatsapp\b"#,
                    #"(?i)\bsend\s+(a\s+)?whatsapp\b"#,
                    #"(?i)\bmessage\s+on\s+whatsapp\b"#
                ],
                steps: [
                    "Open Chrome or the default browser using open_application",
                    "Navigate to https://web.whatsapp.com — type it in the address bar and press Return",
                    "Wait for WhatsApp Web to load (may take 5–10 seconds); take a screenshot to confirm",
                    "In the search bar (top-left, looks like a magnifying glass or chat icon), click and type the contact or group name",
                    "Take a screenshot to see the search results, then click the correct contact/group",
                    "Click the message input box at the bottom of the chat",
                    "Type the message content",
                    "Press Return or click the send button (paper plane icon) to send the message",
                    "Take a final screenshot to confirm the message appears in the chat"
                ],
                permissions: ["network"],
                maxIterations: 20
            ),
            makePackage(
                name: "twitter-post",
                version: "1.0.0",
                description: "Post a tweet or thread on X (formerly Twitter) via the web.",
                triggers: [
                    #"(?i)\b(post|tweet)\s+(on\s+)?(x|twitter)\b"#,
                    #"(?i)\bpost\s+to\s+x\b"#,
                    #"(?i)\btweet\b"#
                ],
                steps: [
                    "Open Chrome or the default browser using open_application",
                    "Navigate to https://x.com — type it in the address bar and press Return",
                    "Wait for X to load; take a screenshot to confirm you are logged in",
                    "Click the 'Post' button (blue button, usually labelled 'Post' or showing a feather icon)",
                    "In the compose box that opens, type the tweet content (keep under 280 characters)",
                    "If posting a thread, click '+ Add another post' after each tweet and continue typing",
                    "Review the content in a screenshot, then click the 'Post all' or 'Post' button to publish",
                    "Take a final screenshot to confirm the tweet is live on your profile"
                ],
                permissions: ["network"],
                maxIterations: 20
            ),
            makePackage(
                name: "calendar-add-event",
                version: "1.0.0",
                description: "Add an event to macOS Calendar app.",
                triggers: [
                    #"(?i)\b(add|create|schedule|set\s+up)\s+(an?\s+)?(event|meeting|appointment|call)\b"#,
                    #"(?i)\b(calendar|remind)\s+(me\s+)?(about|to|that)\b"#,
                    #"(?i)\bschedule\s+(a\s+)?(meeting|call|appointment)\b"#
                ],
                steps: [
                    "Open Calendar app using open_application with name 'Calendar'",
                    "Take a screenshot to confirm Calendar is open",
                    "Press Cmd+N to create a new event, or click the '+' button",
                    "Type the event title in the title field that appears",
                    "If a date/time was specified, click on the date field and enter it (e.g. 'tomorrow at 3pm')",
                    "If a location was specified, click the location field and type it",
                    "If attendees were specified, click the 'Add Invitees' field and type their emails",
                    "Press Return or click 'OK' / 'Add' to save the event",
                    "Take a final screenshot to confirm the event appears in the calendar"
                ],
                permissions: [],
                maxIterations: 15
            ),
            makePackage(
                name: "notes-create",
                version: "1.0.0",
                description: "Create a new note in macOS Notes app.",
                triggers: [
                    #"(?i)\b(create|add|write|make|new)\s+(a\s+)?note\b"#,
                    #"(?i)\bnote\s+(down|this|that)\b"#,
                    #"(?i)\bjot\s+(down|this)\b"#,
                    #"(?i)\bwrite\s+(this\s+)?(down|in\s+notes)\b"#
                ],
                steps: [
                    "Open Notes app using open_application with name 'Notes'",
                    "Take a screenshot to confirm Notes is open",
                    "Press Cmd+N to create a new note",
                    "The cursor should be in the title area — type the note title if one was specified",
                    "Press Return to move to the body area",
                    "Type the note content",
                    "Take a final screenshot to confirm the note was created with the correct content"
                ],
                permissions: [],
                maxIterations: 12
            ),
            makePackage(
                name: "reminders-add",
                version: "1.0.0",
                description: "Add a reminder to macOS Reminders app.",
                triggers: [
                    #"(?i)\b(add|set|create)\s+(a\s+)?reminder\b"#,
                    #"(?i)\bremind\s+me\s+to\b"#,
                    #"(?i)\bremind\s+me\s+(about|at|on|tomorrow)\b"#,
                    #"(?i)\bdon'?t\s+let\s+me\s+forget\b"#
                ],
                steps: [
                    "Open Reminders app using open_application with name 'Reminders'",
                    "Take a screenshot to confirm Reminders is open",
                    "Click the '+' button or press Cmd+N to add a new reminder",
                    "Type the reminder text",
                    "If a date/time was specified, click the info button (ⓘ) next to the reminder and set the date/time",
                    "Press Return to save the reminder",
                    "Take a final screenshot to confirm the reminder appears in the list"
                ],
                permissions: [],
                maxIterations: 12
            ),
            makePackage(
                name: "spotify-play",
                version: "1.0.0",
                description: "Play music, a playlist, or a specific artist on Spotify.",
                triggers: [
                    #"(?i)\b(play|put\s+on|start)\s+.{1,50}\s+on\s+spotify\b"#,
                    #"(?i)\bspotify\s+(play|open|start)\b"#,
                    #"(?i)\bplay\s+(some\s+)?(music|songs?|tracks?|playlist|album)\b"#,
                    #"(?i)\bplay\s+.{1,50}\s+(by|from)\s+\w+"#
                ],
                steps: [
                    "Open Spotify using open_application with name 'Spotify'",
                    "Take a screenshot to confirm Spotify is open and you are logged in",
                    "Click the search bar (magnifying glass icon in the left sidebar)",
                    "Type the song, artist, album, or playlist name to search for",
                    "Take a screenshot to see the search results",
                    "Click on the most relevant result (song, album, or artist)",
                    "If an artist page opened, click the 'Play' button or the first track",
                    "If a playlist or album opened, click the green 'Play' button",
                    "Take a final screenshot to confirm music is playing (look for the playback bar at the bottom)"
                ],
                permissions: [],
                maxIterations: 15
            ),
            makePackage(
                name: "slack-send",
                version: "1.0.0",
                description: "Send a message to a Slack channel or person via Slack desktop app.",
                triggers: [
                    #"(?i)\bslack\b"#,
                    #"(?i)\bsend\s+(a\s+)?slack\s+(message|msg|dm)\b"#,
                    #"(?i)\bmessage\s+.{1,40}\s+on\s+slack\b"#,
                    #"(?i)\bpost\s+(to|in)\s+#?\w+\s+(slack|channel)\b"#
                ],
                steps: [
                    "Open Slack using open_application with name 'Slack'",
                    "Take a screenshot to confirm Slack is open and you are logged in",
                    "Press Cmd+K to open the quick switcher, or click the search bar at the top",
                    "Type the channel name (e.g. #general) or person's name to find the conversation",
                    "Take a screenshot to see the results, then click the correct channel or person",
                    "Click the message input box at the bottom of the screen",
                    "Type the message content",
                    "Press Return to send the message",
                    "Take a final screenshot to confirm the message was sent and appears in the conversation"
                ],
                permissions: [],
                maxIterations: 15
            ),
            makePackage(
                name: "notion-create-page",
                version: "1.0.0",
                description: "Create a new page in Notion via the web app.",
                triggers: [
                    #"(?i)\bnotion\b"#,
                    #"(?i)\b(create|add|write|make|new)\s+(a\s+)?notion\s+page\b"#,
                    #"(?i)\badd\s+(this\s+)?to\s+notion\b"#,
                    #"(?i)\bnotion\s+(page|doc|note)\b"#
                ],
                steps: [
                    "Open Chrome or the default browser using open_application",
                    "Navigate to https://notion.so — type it in the address bar and press Return",
                    "Wait for Notion to load; take a screenshot to confirm you are logged in",
                    "Click the '+ New page' button in the left sidebar, or press Cmd+N if available",
                    "Type the page title in the large title area at the top",
                    "Press Return or click below the title to start typing the page content",
                    "Type or paste the page content",
                    "Notion auto-saves; take a final screenshot to confirm the page was created"
                ],
                permissions: ["network"],
                maxIterations: 20
            )
        ]
    }

    // MARK: - Factory

    private static func makePackage(
        name: String,
        version: String,
        description: String,
        triggers: [String],
        steps: [String],
        permissions: [String],
        maxIterations: Int
    ) -> SkillPackage {
        let manifest = SkillPackageManifest(
            name: name,
            version: version,
            description: description,
            author: nil,
            triggers: triggers,
            steps: steps,
            tools: nil,
            permissions: permissions,
            maxIterations: maxIterations,
            marketplace: nil
        )
        var pkg = SkillPackage(manifest: manifest, source: .builtIn)
        pkg.isEnabled = true
        pkg.requiresApproval = false
        return pkg
    }
}
