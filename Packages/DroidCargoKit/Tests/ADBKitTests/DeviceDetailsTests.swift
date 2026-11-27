@testable import ADBKit
import DeviceKit
import Testing

struct DeviceDetailsTests {
    @Test func prefersMarketName() {
        let details = DeviceDetails(getpropOutput: "Galaxy S23\nSM-S911B\n14\n", fallbackName: "SM_S911B")
        #expect(details == DeviceDetails(name: "Galaxy S23", androidVersion: "14"))
    }

    @Test func fallsBackToModelWhenMarketNameUnset() {
        let details = DeviceDetails(getpropOutput: "\nPixel 11 Pro\n17\n", fallbackName: "Pixel_11_Pro")
        #expect(details == DeviceDetails(name: "Pixel 11 Pro", androidVersion: "17"))
    }

    @Test func emptyOutputUsesFallback() {
        let details = DeviceDetails(getpropOutput: "", fallbackName: "Pixel_11_Pro")
        #expect(details == DeviceDetails(name: "Pixel_11_Pro", androidVersion: nil))
    }

    @Test func usbSpeedFromLinkRate() {
        #expect(USBSpeed(bitsPerSecond: 12_000_000) == .usb1)
        #expect(USBSpeed(bitsPerSecond: 480_000_000) == .usb2)
        #expect(USBSpeed(bitsPerSecond: 5_000_000_000) == .usb3)
        #expect(USBSpeed(bitsPerSecond: 10_000_000_000) == .usb3Fast)
    }
}
