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
