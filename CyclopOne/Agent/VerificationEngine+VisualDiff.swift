import Foundation
import AppKit

// MARK: - Visual Diff Scoring

extension VerificationEngine {

    // MARK: - Visual Diff Scoring

    /// Compare pre and post screenshots byte-by-byte.
    ///
    /// Strategy: Calculate the fraction of bytes that differ between the two images.
    /// If the command implies a visible change (navigation, opening apps, typing, etc.)
    /// then pixel changes are a positive signal. If no change is expected, stable pixels
    /// are positive.
    ///
    /// Returns a score 0-100.
    func computeVisualScore(
        preScreenshot: ScreenCapture?,
        postScreenshot: ScreenCapture?,
        command: String
    ) -> Int {
        guard let preData = preScreenshot?.imageData,
              let postData = postScreenshot?.imageData else {
            // If either screenshot is missing, return a neutral score
            return neutralScore
        }

        let changeRatio = pixelChangeRatio(preData: preData, postData: postData)

        // Determine if we expect a visible change based on command keywords
        let expectsChange = commandExpectsVisibleChange(command)

        if expectsChange {
            // The command should produce visible changes.
            // More change = higher score, but cap it.
            // changeRatio 0.0 (no change) -> low score
            // changeRatio 0.01-0.05 -> moderate (some change)
            // changeRatio > 0.05 -> good (significant change)
            if changeRatio < 0.001 {
                return 10  // Almost no change when change was expected
            } else if changeRatio < 0.01 {
                return 40  // Minor change
            } else if changeRatio < 0.05 {
                return 70  // Moderate change
            } else if changeRatio < 0.15 {
                return 90  // Significant change
            } else {
                return 100 // Major visual difference
            }
        } else {
            // The command does not necessarily produce visible changes
            // (e.g., shell commands, background tasks).
            // Some change is fine, no change is also fine.
            if changeRatio < 0.001 {
                return 60  // Stable screen is acceptable
            } else if changeRatio < 0.05 {
                return 70  // Minor change is fine
            } else {
                return 80  // Change happened, probably good
            }
        }
    }

    /// Calculate the ratio of pixels that differ between pre and post screenshot data.
    /// Decodes JPEG/PNG data to raw pixel buffers via CGImage to avoid false positives
    /// from lossy JPEG compression artifacts.
    /// Returns 0.0 (identical) to 1.0 (completely different).
    func pixelChangeRatio(preData: Data, postData: Data) -> Double {
        // Decode both images to CGImage pixel buffers for accurate comparison.
        // Comparing raw JPEG bytes directly produces false positives because lossy
        // compression introduces non-deterministic byte variations.
        guard let preImage = NSBitmapImageRep(data: preData)?.cgImage,
              let postImage = NSBitmapImageRep(data: postData)?.cgImage else {
            // Fallback: if we cannot decode, use data size difference as a rough signal
            guard preData.count > 0, postData.count > 0 else { return 0.0 }
            return Double(abs(preData.count - postData.count)) / Double(max(preData.count, postData.count))
        }

        // Render both images into identical RGBA bitmap contexts for fair comparison
        let width = min(preImage.width, postImage.width)
        let height = min(preImage.height, postImage.height)
        guard width > 0, height > 0 else { return 0.0 }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        var prePixels = [UInt8](repeating: 0, count: totalBytes)
        var postPixels = [UInt8](repeating: 0, count: totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let preCtx = CGContext(data: &prePixels, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                     space: colorSpace, bitmapInfo: bitmapInfo),
              let postCtx = CGContext(data: &postPixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            return 0.0
        }

        preCtx.draw(preImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        postCtx.draw(postImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample pixels for performance (compare every Nth pixel)
        let totalPixels = width * height
        let sampleStride = max(1, totalPixels / 10_000)
        var differentCount = 0
        var sampleCount = 0

        var pixelIndex = 0
        while pixelIndex < totalPixels {
            sampleCount += 1
            let byteOffset = pixelIndex * bytesPerPixel
            // Compare RGB channels (skip alpha). Use a per-channel threshold
            // to account for minor rendering differences.
            let rDiff = abs(Int(prePixels[byteOffset]) - Int(postPixels[byteOffset]))
            let gDiff = abs(Int(prePixels[byteOffset + 1]) - Int(postPixels[byteOffset + 1]))
            let bDiff = abs(Int(prePixels[byteOffset + 2]) - Int(postPixels[byteOffset + 2]))
            // Threshold of 8 per channel to ignore sub-pixel rendering noise
            if rDiff > 8 || gDiff > 8 || bDiff > 8 {
                differentCount += 1
            }
            pixelIndex += sampleStride
        }

        guard sampleCount > 0 else { return 0.0 }

        // Also account for resolution difference as a signal
        let sizeDiffRatio: Double
        if preImage.width == postImage.width && preImage.height == postImage.height {
            sizeDiffRatio = 0.0
        } else {
            let preTotal = Double(preImage.width * preImage.height)
            let postTotal = Double(postImage.width * postImage.height)
            sizeDiffRatio = abs(preTotal - postTotal) / max(preTotal, postTotal)
        }

        let pixelDiffRatio = Double(differentCount) / Double(sampleCount)
        return min(1.0, pixelDiffRatio + sizeDiffRatio * 0.5)
    }

    /// Heuristic: does this command imply a visible change on screen?
    func commandExpectsVisibleChange(_ command: String) -> Bool {
        let lower = command.lowercased()
        let visibleChangeKeywords = [
            "open", "go to", "navigate", "click", "type", "write",
            "create", "new", "launch", "start", "show", "display",
            "switch", "move", "drag", "scroll", "resize", "close",
            "delete", "remove", "safari", "chrome", "finder", "browser",
            "website", "url", "page", "app", "window", "tab", "file",
            "folder", "document"
        ]
        return visibleChangeKeywords.contains { lower.contains($0) }
    }
}
