import Foundation
import ImageIO

/// When a photo was taken, read from its EXIF header (no pixels decoded).
///
/// Android only fills in a copied photo's "date taken" when the photo has a
/// timezone or the file date is near the capture time; otherwise Gallery
/// shows it on the day it was copied. Uploading with this date avoids that.
enum CaptureDate {
    private static let exifFormat = "yyyy:MM:dd HH:mm:ss"
    private static let offsetFormat = "xxx"

    static func read(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let captured = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        return parse(captured, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    /// "2019:03:10 15:30:00" plus an optional "-06:00". Without an offset the
    /// time is the Mac's local time, as cameras record it.
    static func parse(_ captured: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        guard let offset else {
            formatter.dateFormat = exifFormat
            return formatter.date(from: captured)
        }
        formatter.dateFormat = "\(exifFormat) \(offsetFormat)"
        return formatter.date(from: "\(captured) \(offset)")
    }
}
