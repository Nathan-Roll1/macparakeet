import CoreAudio
import XCTest
@testable import MacParakeetCore

final class AudioDeviceManagerTransportTests: XCTestCase {
    func testBluetoothTransportTypesClassifyAsBluetooth() {
        XCTAssertTrue(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeBluetooth)
        )
        XCTAssertTrue(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeBluetoothLE)
        )
    }

    func testNonBluetoothTransportTypesDoNotClassifyAsBluetooth() {
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeBuiltIn)
        )
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeUSB)
        )
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeAggregate)
        )
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeVirtual)
        )
        XCTAssertFalse(AudioDeviceManager.isBluetoothTransportType(0))
    }
}
