import Foundation
import IOKit

private let wacomVendorID = 0x056a
private let driverClaimMarker = "WacomTabletDrive"
private let wacomLaunchdLabels = [
    "com.wacom.wacomtablet",
    "com.wacom.DataStoreMgr",
    "Wacom_IOManager",
]

private struct Configuration {
    var productName = "Cintiq Pro 16"
    var graceSeconds = 3.0
    var cooldownSeconds = 120.0

    static func parse(_ arguments: [String]) throws -> Configuration {
        var configuration = Configuration()
        var index = 1

        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                throw ConfigurationError.missingValue(flag)
            }
            let value = arguments[index + 1]

            switch flag {
            case "--product-name":
                guard !value.isEmpty else { throw ConfigurationError.invalidValue(flag, value) }
                configuration.productName = value
            case "--grace":
                guard let seconds = Double(value), seconds >= 0 else {
                    throw ConfigurationError.invalidValue(flag, value)
                }
                configuration.graceSeconds = seconds
            case "--cooldown":
                guard let seconds = Double(value), seconds >= 0 else {
                    throw ConfigurationError.invalidValue(flag, value)
                }
                configuration.cooldownSeconds = seconds
            default:
                throw ConfigurationError.unknownFlag(flag)
            }

            index += 2
        }

        return configuration
    }
}

private enum ConfigurationError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String, String)
    case unknownFlag(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .invalidValue(let flag, let value):
            return "invalid value for \(flag): \(value)"
        case .unknownFlag(let flag):
            return "unknown option: \(flag)"
        }
    }
}

private enum MonitorError: Error, CustomStringConvertible {
    case notificationPortCreationFailed
    case registrationFailed(String, kern_return_t)

    var description: String {
        switch self {
        case .notificationPortCreationFailed:
            return "could not create an IOKit notification port"
        case .registrationFailed(let type, let result):
            return "could not register \(type) notification (IOKit error \(result))"
        }
    }
}

private final class DeviceMonitor {
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.local.wacom-recovery.events")
    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var targetRegistryIDs = Set<UInt64>()
    private var pendingCheck: DispatchWorkItem?
    private var lastRestart: Date?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        pendingCheck?.cancel()
        if matchedIterator != 0 { IOObjectRelease(matchedIterator) }
        if terminatedIterator != 0 { IOObjectRelease(terminatedIterator) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    func start() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw MonitorError.notificationPortCreationFailed
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let reference = Unmanaged.passUnretained(self).toOpaque()
        let matchedResult = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"),
            { reference, iterator in
                guard let reference else { return }
                Unmanaged<DeviceMonitor>.fromOpaque(reference)
                    .takeUnretainedValue()
                    .handleMatched(iterator)
            },
            reference,
            &matchedIterator
        )
        guard matchedResult == KERN_SUCCESS else {
            throw MonitorError.registrationFailed("device arrival", matchedResult)
        }

        let terminatedResult = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"),
            { reference, iterator in
                guard let reference else { return }
                Unmanaged<DeviceMonitor>.fromOpaque(reference)
                    .takeUnretainedValue()
                    .handleTerminated(iterator)
            },
            reference,
            &terminatedIterator
        )
        guard terminatedResult == KERN_SUCCESS else {
            throw MonitorError.registrationFailed("device removal", terminatedResult)
        }

        // Draining each iterator both handles already-connected hardware and arms
        // the corresponding IOKit notification for future events.
        handleMatched(matchedIterator)
        handleTerminated(terminatedIterator)
        log("listening for \(configuration.productName) USB events (no polling)")
    }

    private func handleMatched(_ iterator: io_iterator_t) {
        var foundTarget = false

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard isTarget(service) else { continue }
            foundTarget = true
            if let identifier = registryID(service) {
                targetRegistryIDs.insert(identifier)
            }
        }

        guard foundTarget else { return }
        log("USB device attached; checking driver claim in \(format(configuration.graceSeconds))s")
        scheduleRecoveryCheck()
    }

    private func handleTerminated(_ iterator: io_iterator_t) {
        var removedTarget = false

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            if let identifier = registryID(service), targetRegistryIDs.remove(identifier) != nil {
                removedTarget = true
            } else if isTarget(service) {
                removedTarget = true
            }
        }

        guard removedTarget else { return }
        if targetRegistryIDs.isEmpty {
            pendingCheck?.cancel()
            pendingCheck = nil
        }
        log("USB device detached")
    }

    private func scheduleRecoveryCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recoverIfNeeded()
        }
        pendingCheck = work
        queue.asyncAfter(deadline: .now() + configuration.graceSeconds, execute: work)
    }

    private func recoverIfNeeded() {
        pendingCheck = nil
        let devices = currentTargetDevices()
        guard !devices.isEmpty else {
            log("check skipped; device is no longer connected")
            return
        }
        defer { devices.forEach { IOObjectRelease($0) } }

        if devices.contains(where: driverClaimed) {
            log("driver claim is healthy; no action needed")
            return
        }

        if let lastRestart {
            let elapsed = Date().timeIntervalSince(lastRestart)
            if elapsed < configuration.cooldownSeconds {
                log("device is unclaimed, but restart is cooling down for \(format(configuration.cooldownSeconds - elapsed))s")
                return
            }
        }

        lastRestart = Date()
        log("device is present but unclaimed; restarting Wacom user services")
        restartWacomStack()
    }

    private func currentTargetDevices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOUSBHostDevice"),
            &iterator
        )
        guard result == KERN_SUCCESS, iterator != 0 else { return [] }
        defer { IOObjectRelease(iterator) }

        var devices: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if isTarget(service) {
                devices.append(service)
            } else {
                IOObjectRelease(service)
            }
        }
        return devices
    }

    private func isTarget(_ service: io_service_t) -> Bool {
        guard propertyNumber(service, key: "idVendor")?.intValue == wacomVendorID else {
            return false
        }
        return propertyString(service, key: "USB Product Name") == configuration.productName
    }

    private func driverClaimed(_ device: io_service_t) -> Bool {
        if propertyDescription(device, key: "IOUserClientCreator").contains(driverClaimMarker) {
            return true
        }

        var iterator: io_iterator_t = 0
        let result = IORegistryEntryCreateIterator(
            device,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard result == KERN_SUCCESS, iterator != 0 else { return false }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            if propertyDescription(entry, key: "IOUserClientCreator").contains(driverClaimMarker) {
                return true
            }
        }
        return false
    }

    private func restartWacomStack() {
        let userID = getuid()
        for label in wacomLaunchdLabels {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(userID)/\(label)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    log("restarted \(label)")
                } else {
                    log("failed to restart \(label) (exit \(process.terminationStatus))", error: true)
                }
            } catch {
                log("failed to restart \(label): \(error)", error: true)
            }
        }
    }

    private func registryID(_ service: io_service_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else {
            return nil
        }
        return identifier
    }

    private func propertyString(_ entry: io_registry_entry_t, key: String) -> String? {
        property(entry, key: key) as? String
    }

    private func propertyNumber(_ entry: io_registry_entry_t, key: String) -> NSNumber? {
        property(entry, key: key) as? NSNumber
    }

    private func propertyDescription(_ entry: io_registry_entry_t, key: String) -> String {
        guard let value = property(entry, key: key) else { return "" }
        return String(describing: value)
    }

    private func property(_ entry: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }
}

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    return formatter
}()

private func format(_ seconds: Double) -> String {
    String(format: seconds.rounded() == seconds ? "%.0f" : "%.1f", seconds)
}

private func log(_ message: String, error: Bool = false) {
    let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
    let handle = error ? FileHandle.standardError : FileHandle.standardOutput
    if let data = line.data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
}

do {
    let configuration = try Configuration.parse(CommandLine.arguments)
    let monitor = DeviceMonitor(configuration: configuration)
    try monitor.start()
    dispatchMain()
} catch {
    log("fatal: \(error)", error: true)
    exit(EXIT_FAILURE)
}
