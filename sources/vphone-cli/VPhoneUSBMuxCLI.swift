import ArgumentParser
import Foundation

struct USBMuxListCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usbmux-list",
        abstract: "List devices visible through Apple's usbmuxd"
    )

    mutating func run() throws {
        let devices = try USBMuxClient.listDevices()
        for device in devices {
            let product = device.productID.map(String.init) ?? "-"
            let location = device.locationID.map(String.init) ?? "-"
            let connection = device.connectionType ?? "-"
            print("\(device.serialNumber)\tdevice_id=\(device.deviceID)\tproduct=\(product)\tlocation=\(location)\tconnection=\(connection)")
        }
    }
}

struct USBMuxForwardCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usbmux-forward",
        abstract: "Forward a local TCP port to a device port through usbmuxd"
    )

    @Option(help: "Local TCP port")
    var localPort: Int

    @Option(help: "Device serial/UDID to match")
    var serial: String

    @Option(help: "Remote device port")
    var remotePort: Int = 22

    mutating func run() throws {
        guard let local = UInt16(exactly: localPort), let remote = UInt16(exactly: remotePort) else {
            throw ValidationError("Ports must be in 1...65535")
        }
        print("[*] Forwarding 127.0.0.1:\(local) -> \(serial):\(remote)")
        try USBMuxForwarder.run(localPort: local, serial: serial, remotePort: remote)
    }
}
