import DeviceKit
import Foundation
import IOKit

/// Reads USB link speed from the Mac's I/O Registry, matched by serial number.
///
///     IOUSBHostDevice "Pixel 11 Pro"
///       "USB Serial Number" = "67260DLKX00GY0"   ◀── adb serial
///       "UsbLinkSpeed"      = 480000000          ──▶ .usb2
enum USBRegistry {
    private static let deviceClass = "IOUSBHostDevice"
    private static let serialKey = "USB Serial Number"
    private static let linkSpeedKey = "UsbLinkSpeed"

    static func speed(serial: String) -> USBSpeed? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(deviceClass), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard property(serialKey, of: entry) as? String == serial else {
                continue
            }
            guard let bits = property(linkSpeedKey, of: entry) as? NSNumber else {
                return nil
            }
            return USBSpeed(bitsPerSecond: bits.uint64Value)
        }
        return nil
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
