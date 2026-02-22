import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import Combine

/// Captures the screen using ScreenCaptureKit and returns compressed image data.
actor ScreenCaptureService {

    static let shared = ScreenCaptureService()

    // MARK: - Recording Indicator (Sprint 17)

    /// Published flag indicating whether a screen capture is currently in progress.
    /// Observed by DotStatusView to show amber recording border.
    private(set) var isCapturing = false

    /// Callback invoked on the main thread when capture state changes.
    /// DotStatusView sets this to update its recording indicator.
    /// Marked @MainActor @Sendable for proper actor isolation.
    private var captureStateDidChange: (@MainActor @Sendable (Bool) -> Void)?

    /// Set a callback to be notified when capture state changes.
    func setCaptureStateHandler(_ handler: @MainActor @Sendable @escaping (Bool) -> Void) {
        captureStateDidChange = handler
    }

    private func setCaptureActive(_ active: Bool) {
        isCapturing = active
        let handler = captureStateDidChange
        Task { @MainActor in
            handler?(active)
        }
    }

    // MARK: - Performance Tracking (Sprint 19)

    /// Last capture duration in milliseconds, for performance monitoring.
    private(set) var lastCaptureDurationMs: Double = 0

    /// Cumulative capture count for averaging.
    private var captureCount: Int = 0

    /// Cumulative capture duration for averaging.
    private var totalCaptureDurationMs: Double = 0

    /// Average capture duration across all captures in this session.
    var averageCaptureDurationMs: Double {
        guard captureCount > 0 else { return 0 }
        return totalCaptureDurationMs / Double(captureCount)
    }

    // MARK: - Screenshot Quality Presets (Sprint 19)

    /// Quality presets for different use cases. Lower quality = smaller payloads = faster API calls.
    enum CaptureQuality {
        /// Full quality for verification screenshots (PNG, max 2048px)
        case verification
        /// Standard quality for routine screenshots (PNG, max 1568px)
        case standard
        /// Low quality for thumbnails/previews (JPEG 0.4, max 800px)
        case preview

        var maxDimension: Int {
            switch self {
            case .verification: return 2048
            case .standard: return 1568
            case .preview: return 800
            }
        }

        var jpegQuality: Double {
            switch self {
            case .verification: return 0.8
            case .standard: return 0.6
            case .preview: return 0.4
            }
        }
    }

    private init() {}

    /// Check if the main display is currently asleep.
    /// Uses CoreGraphics — safe to call from any context.
    nonisolated static func isDisplayAsleep() -> Bool {
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Capture the full display and return JPEG data + base64 string.
    /// Coordinates are always stored in logical points (CG-space, top-left origin)
    /// for correct mapping to CGEvent positions.
    ///
    /// Sprint 17: Now includes password field redaction and recording indicator signaling.
    /// Sprint 19: Added performance timing and capture metrics.
    func captureScreen(maxDimension: Int = 1568, quality: Double = 0.8) async throws -> ScreenCapture {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            lastCaptureDurationMs = elapsed
            captureCount += 1
            totalCaptureDurationMs += elapsed
            if elapsed > 50 {
                print("[ScreenCapture] Warning: capture took \(String(format: "%.1f", elapsed))ms (target: <50ms)")
            }
        }

        // Signal recording indicator ON
        setCaptureActive(true)
        defer { setCaptureActive(false) }

        // Check screen recording permission FIRST.
        // CGWindowList returns an image even without permission, but window content
        // areas are blacked out. CGPreflightScreenCaptureAccess() is the reliable check.
        // NOTE: Must check permission before display sleep, because CGDisplayIsAsleep()
        // can return false positives when TCC screen capture permission is not yet granted.
        if !CGPreflightScreenCaptureAccess() {
            NSLog("CyclopOne [ScreenCapture]: Screen Recording permission NOT granted. Requesting access.")
            CGRequestScreenCaptureAccess()
            throw CaptureError.permissionDenied
        }

        // Check if display is asleep (prevents wasting API tokens on empty captures).
        // Must come AFTER the permission check — CGDisplayIsAsleep() returns false
        // positives when TCC screen capture permission hasn't been granted yet.
        if ScreenCaptureService.isDisplayAsleep() {
            NSLog("CyclopOne [ScreenCapture]: Display is asleep — cannot capture.")
            throw CaptureError.displayAsleep
        }

        // Try ScreenCaptureKit first — it properly fails without permission
        do {
            var capture = try await captureWithSCKit(maxDimension: maxDimension, quality: quality)
            capture = await redactPasswordFields(in: capture)
            return capture
        } catch {
            NSLog("CyclopOne [ScreenCapture]: SCKit failed (%@), trying CGWindowList fallback",
                  error.localizedDescription)
        }

        // Fallback to CGWindowList
        if var fallback = captureWithCGWindowList(maxDimension: maxDimension, quality: quality) {
            fallback = await redactPasswordFields(in: fallback)
            return fallback
        }

        CGRequestScreenCaptureAccess()
        throw CaptureError.permissionDenied
    }

    /// Sprint 19: Capture with a preset quality level for different use cases.
    ///
    /// Uses predefined quality/resolution combinations to optimize for:
    /// - `.verification`: Full quality for verification scoring (largest payload)
    /// - `.standard`: Balanced quality for routine agent screenshots
    /// - `.preview`: Minimal quality for thumbnails and previews
    func captureScreen(quality preset: CaptureQuality) async throws -> ScreenCapture {
        return try await captureScreen(
            maxDimension: preset.maxDimension,
            quality: preset.jpegQuality
        )
    }

    /// Sprint 19: Reset performance counters. Useful at the start of a new run.
    func resetPerformanceCounters() {
        lastCaptureDurationMs = 0
        captureCount = 0
        totalCaptureDurationMs = 0
    }

    /// Sprint 19: Get a performance summary string for diagnostics.
    func performanceSummary() -> String {
        return "Captures: \(captureCount), Avg: \(String(format: "%.1f", averageCaptureDurationMs))ms, Last: \(String(format: "%.1f", lastCaptureDurationMs))ms"
    }

    // MARK: - ScreenCaptureKit Path

    /// Sprint 7: Window IDs to exclude from SCKit captures (Cyclop One's own windows).
    private var excludedWindowIDs: Set<CGWindowID> = []

    /// Sprint 7: Register window IDs that should be excluded from screenshots.
    /// Call this with the dot panel and chat panel window numbers.
    func setExcludedWindowIDs(_ ids: Set<CGWindowID>) {
        excludedWindowIDs = ids
    }

    private func captureWithSCKit(maxDimension: Int, quality: Double) async throws -> ScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let mainDisplay = content.displays.first else {
            throw CaptureError.noDisplay
        }

        // GFX-1 FIX: Use NSScreen logical points, NOT display.width/height
        // which returns physical pixels on Retina displays.
        let screenFrame = Self.screenFrameForDisplay(mainDisplay)

        // SCKit config still needs the capture resolution — use display's actual
        // pixel dimensions for best quality capture
        let captureWidth = mainDisplay.width
        let captureHeight = mainDisplay.height

        NSLog("CyclopOne [ScreenCapture SCKit]: Raw display %dx%d px, logical frame=%.0fx%.0f pts, maxDimension=%d",
              captureWidth, captureHeight, screenFrame.width, screenFrame.height, maxDimension)

        // Sprint 7: Exclude Cyclop One windows from the capture
        let excludedWindows = content.windows.filter { window in
            excludedWindowIDs.contains(CGWindowID(window.windowID))
        }
        let filter = SCContentFilter(display: mainDisplay, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()

        // Scale the CAPTURE (physical) resolution down to maxDimension
        let scale = min(
            Double(maxDimension) / Double(captureWidth),
            Double(maxDimension) / Double(captureHeight),
            1.0
        )
        config.width = Int(Double(captureWidth) * scale)
        config.height = Int(Double(captureHeight) * scale)

        NSLog("CyclopOne [ScreenCapture SCKit]: Scale factor=%.3f, output %dx%d px", scale, config.width, config.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        // GFX-1 FIX: Store LOGICAL point dimensions for coordinate mapping
        return try compressCGImage(
            image,
            width: config.width,
            height: config.height,
            screenFrame: screenFrame,
            quality: quality
        )
    }

    /// Find the NSScreen that corresponds to a SCDisplay.
    private static func screenFrameForDisplay(_ display: SCDisplay) -> CGRect {
        // Match by displayID
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if screenNumber == display.displayID {
                    return screen.frame
                }
            }
        }
        // Fallback: use main screen
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    // MARK: - CGWindowList Fallback

    private func captureWithCGWindowList(maxDimension: Int, quality: Double) -> ScreenCapture? {
        // GFX-2 FIX: Compute the union of all screen frames for full-desktop capture
        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else { return nil }

        // Union of all screens in CG-space (top-left origin)
        // NSScreen uses bottom-left origin, so we need the union in CG coordinates
        let unionFrame = Self.cgSpaceUnionFrame(screens: allScreens)

        // Build a CGImage excluding Cyclop One's own windows.
        // If we have excluded window IDs, filter them out by capturing
        // all on-screen windows below each excluded window. If no exclusions
        // or the filtered capture fails, fall back to the full capture.
        let image: CGImage
        if !excludedWindowIDs.isEmpty,
           let filtered = captureExcludingOwnWindows() {
            image = filtered
        } else if let fallback = CGWindowListCreateImage(
            CGRect.null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) {
            image = fallback
        } else {
            return nil
        }

        let width = image.width
        let height = image.height

        NSLog("CyclopOne [ScreenCapture CGWindowList]: Raw capture %dx%d px, maxDimension=%d", width, height, maxDimension)

        // Scale to maxDimension
        let scale = min(
            Double(maxDimension) / Double(width),
            Double(maxDimension) / Double(height),
            1.0
        )
        let targetW = Int(Double(width) * scale)
        let targetH = Int(Double(height) * scale)

        NSLog("CyclopOne [ScreenCapture CGWindowList]: Scale factor=%.3f, target %dx%d px", scale, targetW, targetH)

        // If we need to scale, create a scaled version
        let finalImage: CGImage
        if scale < 1.0, let scaled = resizeCGImage(image, to: CGSize(width: targetW, height: targetH)) {
            finalImage = scaled
        } else {
            finalImage = image
        }

        // Use the union frame for coordinate mapping
        return try? compressCGImage(
            finalImage,
            width: targetW,
            height: targetH,
            screenFrame: unionFrame,
            quality: quality
        )
    }

    /// Compute the bounding rect of all screens in CG-space (top-left origin).
    /// CGEvent uses CG-space coordinates where (0,0) is top-left of the primary display.
    private static func cgSpaceUnionFrame(screens: [NSScreen]) -> CGRect {
        guard let primaryScreen = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }

        let primaryHeight = primaryScreen.frame.height

        // Convert all NSScreen frames (bottom-left origin) to CG-space (top-left origin)
        var unionRect = CGRect.null
        for screen in screens {
            let cgFrame = CGRect(
                x: screen.frame.origin.x,
                // GFX-3 FIX: Y-axis inversion — AppKit bottom-left → CG top-left
                y: primaryHeight - screen.frame.origin.y - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height
            )
            unionRect = unionRect.union(cgFrame)
        }
        return unionRect
    }

    // MARK: - CGWindowList Exclusion

    /// Capture the screen using CGWindowList while excluding Cyclop One's own windows.
    ///
    /// Uses the Cyclop One process ID to identify and exclude all windows belonging
    /// to this app from the capture. Builds an explicit array of non-Cyclop One window
    /// IDs and uses CGWindowListCreateImageFromArray to composite only those windows.
    private func captureExcludingOwnWindows() -> CGImage? {
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Get all on-screen windows (including desktop elements for the background)
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            NSLog("CyclopOne [captureExcludingOwnWindows]: CGWindowListCopyWindowInfo returned nil")
            return nil
        }

        let totalWindows = windowInfoList.count

        // Collect window IDs that do NOT belong to Cyclop One
        var otherWindowIDs: [CGWindowID] = []
        var excludedCount = 0
        for info in windowInfoList {
            guard let windowPID = info[kCGWindowOwnerPID as String] as? Int32,
                  let windowNumber = info[kCGWindowNumber as String] as? Int else {
                continue
            }
            let windowID = CGWindowID(windowNumber)
            // Skip our own windows (by PID) and also by explicit exclusion set
            if windowPID == myPID || excludedWindowIDs.contains(windowID) {
                excludedCount += 1
                continue
            }
            otherWindowIDs.append(windowID)
        }

        NSLog("CyclopOne [captureExcludingOwnWindows]: Total windows: %d, Excluded (PID %d): %d, Remaining for capture: %d",
              totalWindows, myPID, excludedCount, otherWindowIDs.count)

        guard !otherWindowIDs.isEmpty else {
            NSLog("CyclopOne [captureExcludingOwnWindows]: No non-Cyclop-One windows found — skipping filtered capture")
            return nil
        }

        // Create a composite image of just the non-Cyclop One windows.
        // CGWindowListCreateImageFromArray needs a CFArray of CGWindowID (UInt32) values.
        let nsArray = otherWindowIDs.map { NSNumber(value: $0) } as CFArray
        let image = CGImage(
            windowListFromArrayScreenBounds: CGRect.null,
            windowArray: nsArray,
            imageOption: [.bestResolution]
        )

        if image == nil {
            NSLog("CyclopOne [captureExcludingOwnWindows]: CGWindowListCreateImageFromArray returned nil for %d windows", otherWindowIDs.count)
        }

        return image
    }

    // MARK: - Helpers

    private func compressCGImage(
        _ image: CGImage,
        width: Int,
        height: Int,
        screenFrame: CGRect,
        quality: Double
    ) throws -> ScreenCapture {
        let bitmapRep = NSBitmapImageRep(cgImage: image)

        // Use PNG for text-heavy screens (lossless, no JPEG artifacts).
        // PNG produces sharper text that Claude's vision can read reliably.
        // Fall back to JPEG only if PNG encoding fails.
        let imageData: Data
        let mediaType: String

        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            imageData = pngData
            mediaType = "image/png"
        } else if let jpegData = bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality]
        ) {
            imageData = jpegData
            mediaType = "image/jpeg"
        } else {
            throw CaptureError.compressionFailed
        }

        let base64 = imageData.base64EncodedString()

        // Debug: save screenshot to /tmp so we can inspect what Claude receives
        let debugPath = "/tmp/omniagent_debug_screenshot.\(mediaType == "image/png" ? "png" : "jpg")"
        try? imageData.write(to: URL(fileURLWithPath: debugPath))

        NSLog("CyclopOne [ScreenCapture]: Captured %dx%d screenshot (%@), screen frame=%.0fx%.0f, data=%d bytes, base64=%d chars, saved to %@",
              width, height, mediaType,
              screenFrame.width, screenFrame.height,
              imageData.count, base64.count, debugPath)

        return ScreenCapture(
            imageData: imageData,
            base64: base64,
            width: width,
            height: height,
            mediaType: mediaType,
            screenFrame: screenFrame
        )
    }

    private func resizeCGImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    /// Check if screen recording permission is granted.
    func checkPermission() async -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    // MARK: - Password Field Redaction (Sprint 17)

    /// Redact password fields in a captured screenshot by drawing black rectangles
    /// over detected AXSecureTextField positions.
    ///
    /// Sprint 17: Removed `nonisolated` — this method accesses @MainActor AccessibilityService
    /// and must properly dispatch to the main thread via await.
    private func redactPasswordFields(in capture: ScreenCapture) async -> ScreenCapture {
        let passwordFields = await AccessibilityService.shared.detectAllPasswordFields()
        guard !passwordFields.isEmpty else { return capture }

        // Create a CGImage from the capture data (format-agnostic: handles both PNG and JPEG)
        guard let sourceImage = NSBitmapImageRep(data: capture.imageData)?.cgImage else {
            return capture
        }

        let imgWidth = sourceImage.width
        let imgHeight = sourceImage.height

        // Create a drawing context matching the source image
        guard let context = CGContext(
            data: nil,
            width: imgWidth,
            height: imgHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return capture
        }

        // Draw the original image
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))

        // Calculate scale factors: screen coordinates to image pixel coordinates
        let scaleX = Double(imgWidth) / capture.screenFrame.width
        let scaleY = Double(imgHeight) / capture.screenFrame.height

        // Draw black rectangles over each password field
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        for field in passwordFields {
            // Convert screen-space frame to image-space coordinates
            // Screen coordinates are CG-space (top-left origin)
            // CGContext coordinates are bottom-left origin
            let fieldX = (field.frame.origin.x - capture.screenFrame.origin.x) * scaleX
            let fieldY = (field.frame.origin.y - capture.screenFrame.origin.y) * scaleY

            let fieldW = field.frame.width * scaleX
            let fieldH = field.frame.height * scaleY

            // CGContext has bottom-left origin, flip Y
            let flippedY = Double(imgHeight) - fieldY - fieldH

            // Add some padding around the field
            let padding: Double = 4.0
            let redactRect = CGRect(
                x: fieldX - padding,
                y: flippedY - padding,
                width: fieldW + padding * 2,
                height: fieldH + padding * 2
            )

            context.fill(redactRect)
        }

        // Create the redacted image
        guard let redactedImage = context.makeImage() else { return capture }

        // Re-encode in the same format as the original capture
        let bitmapRep = NSBitmapImageRep(cgImage: redactedImage)
        let redactedData: Data
        if capture.mediaType == "image/png" {
            guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                return capture
            }
            redactedData = pngData
        } else {
            guard let jpegData = bitmapRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.8]
            ) else {
                return capture
            }
            redactedData = jpegData
        }

        let base64 = redactedData.base64EncodedString()

        return ScreenCapture(
            imageData: redactedData,
            base64: base64,
            width: capture.width,
            height: capture.height,
            mediaType: capture.mediaType,
            screenFrame: capture.screenFrame
        )
    }

    // MARK: - Multi-Monitor Targeted Capture (Sprint 7)

    /// Capture the specific screen that contains the given CG-space point.
    /// Falls back to the primary screen if the point doesn't land on any screen.
    ///
    /// Sprint 17: Includes password redaction and recording indicator.
    func captureScreen(containing point: CGPoint, maxDimension: Int = 1568, quality: Double = 0.8) async throws -> ScreenCapture {
        // Signal recording indicator ON
        setCaptureActive(true)
        defer { setCaptureActive(false) }

        // Find which NSScreen contains this point (convert CG top-left to AppKit bottom-left)
        let targetScreen = Self.screenContaining(cgPoint: point) ?? NSScreen.main

        guard let screen = targetScreen else {
            throw CaptureError.noDisplay
        }

        // Try SCKit path for the target display
        do {
            var capture = try await captureSpecificScreen(screen, maxDimension: maxDimension, quality: quality)
            capture = await redactPasswordFields(in: capture)
            return capture
        } catch {
            // Fallback to CGWindowList for that screen's rect
            if var fallback = captureScreenRectWithCGWindowList(screen: screen, maxDimension: maxDimension, quality: quality) {
                fallback = await redactPasswordFields(in: fallback)
                return fallback
            }
            throw error
        }
    }

    /// Capture a specific NSScreen using SCKit.
    private func captureSpecificScreen(_ screen: NSScreen, maxDimension: Int, quality: Double) async throws -> ScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the SCDisplay matching this NSScreen
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let scDisplay = content.displays.first(where: { $0.displayID == screenNumber }) else {
            throw CaptureError.noDisplay
        }

        // Convert NSScreen frame (AppKit bottom-left origin) to CG-space (top-left origin)
        // so that toScreenCoords() produces correct CGEvent coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenFrame = CGRect(
            x: screen.frame.origin.x,
            y: primaryHeight - screen.frame.origin.y - screen.frame.height,
            width: screen.frame.width,
            height: screen.frame.height
        )
        let captureWidth = scDisplay.width
        let captureHeight = scDisplay.height

        // Exclude Cyclop One windows
        let excludedWindows = content.windows.filter { window in
            excludedWindowIDs.contains(CGWindowID(window.windowID))
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()

        let scale = min(
            Double(maxDimension) / Double(captureWidth),
            Double(maxDimension) / Double(captureHeight),
            1.0
        )
        config.width = Int(Double(captureWidth) * scale)
        config.height = Int(Double(captureHeight) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        return try compressCGImage(
            image,
            width: config.width,
            height: config.height,
            screenFrame: screenFrame,
            quality: quality
        )
    }

    /// Capture a specific screen's rect using CGWindowList (fallback).
    /// Excludes Cyclop One windows by PID when possible.
    private func captureScreenRectWithCGWindowList(screen: NSScreen, maxDimension: Int, quality: Double) -> ScreenCapture? {
        // Convert NSScreen frame (bottom-left origin) to CG frame (top-left origin)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgRect = CGRect(
            x: screen.frame.origin.x,
            y: primaryHeight - screen.frame.origin.y - screen.frame.height,
            width: screen.frame.width,
            height: screen.frame.height
        )

        // Capture only the target screen rect. Cyclop One windows are excluded by PID
        // in the filtered path. Note: we no longer call captureExcludingOwnWindows()
        // here because it captures the full desktop (CGRect.null) which doesn't match
        // the single-screen frame we need.
        let image: CGImage
        if let captured = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) {
            image = captured
        } else {
            return nil
        }

        let scale = min(
            Double(maxDimension) / Double(image.width),
            Double(maxDimension) / Double(image.height),
            1.0
        )
        let targetW = Int(Double(image.width) * scale)
        let targetH = Int(Double(image.height) * scale)

        let finalImage: CGImage
        if scale < 1.0, let scaled = resizeCGImage(image, to: CGSize(width: targetW, height: targetH)) {
            finalImage = scaled
        } else {
            finalImage = image
        }

        // Convert NSScreen frame (AppKit bottom-left origin) to CG-space (top-left origin)
        // so that toScreenCoords() produces correct CGEvent coordinates.
        let cgScreenFrame = CGRect(
            x: screen.frame.origin.x,
            y: primaryHeight - screen.frame.origin.y - screen.frame.height,
            width: screen.frame.width,
            height: screen.frame.height
        )

        return try? compressCGImage(
            finalImage,
            width: targetW,
            height: targetH,
            screenFrame: cgScreenFrame,
            quality: quality
        )
    }

    /// Find the NSScreen containing a CG-space point (top-left origin).
    private static func screenContaining(cgPoint: CGPoint) -> NSScreen? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let primaryHeight = primaryScreen.frame.height

        for screen in NSScreen.screens {
            // Convert NSScreen frame to CG-space
            let cgFrame = CGRect(
                x: screen.frame.origin.x,
                y: primaryHeight - screen.frame.origin.y - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height
            )
            if cgFrame.contains(cgPoint) {
                return screen
            }
        }
        return nil
    }
}

// MARK: - Models

struct ScreenCapture {
    let imageData: Data
    let base64: String
    let width: Int        // Screenshot pixel dimensions (after scaling)
    let height: Int
    let mediaType: String

    /// The screen frame in CG-space (top-left origin, logical points).
    /// For single-monitor: matches primary screen frame.
    /// For multi-monitor: the union bounding rect of all displays.
    let screenFrame: CGRect

    /// Logical screen width in points (for coordinate mapping).
    var screenWidth: Int { Int(screenFrame.width) }

    /// Logical screen height in points (for coordinate mapping).
    var screenHeight: Int { Int(screenFrame.height) }

    /// Convert screenshot coordinates to CG-space screen coordinates.
    /// Screenshot coords: (0,0) = top-left of captured image.
    /// Screen coords: CG-space (top-left origin, logical points) — matches CGEvent.
    func toScreenCoords(x: Double, y: Double) -> (x: Double, y: Double) {
        let scaleX = screenFrame.width / Double(width)
        let scaleY = screenFrame.height / Double(height)
        // Offset by screenFrame.origin to handle multi-monitor layouts
        // where the union frame doesn't start at (0,0)
        return (
            x * scaleX + screenFrame.origin.x,
            y * scaleY + screenFrame.origin.y
        )
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case compressionFailed
    case permissionDenied
    case displayAsleep

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for screen capture."
        case .compressionFailed: return "Failed to compress screenshot (PNG/JPEG encoding failed)."
        case .permissionDenied: return "Screen Recording permission not granted. Open System Settings → Privacy & Security → Screen Recording, enable Cyclop One, then quit and relaunch the app. (Rebuilding the app in Xcode resets this permission.)"
        case .displayAsleep: return "Display is asleep — screen capture unavailable."
        }
    }
}
