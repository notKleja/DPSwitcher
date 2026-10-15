import Foundation
import IOKit

/// Minimal Apple Silicon DDC writer derived from MonitorControl's Arm64DDC.
/// It intentionally controls every external DCPAVServiceProxy, matching the
/// linked app's "all displays" shortcut behavior without importing its UI.
final class MonitorControlDDC {
    enum Error: LocalizedError {
        case noExternalDisplay
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noExternalDisplay:
                return "No external DDC display was found."
            case .writeFailed:
                return "The display rejected the DDC brightness command."
            }
        }
    }

    private let queue = DispatchQueue(label: "MonitorBrightnessHotkeys.DDC", qos: .userInitiated)

    func setBrightness(_ percent: UInt16, completion: @escaping (Result<Int, Swift.Error>) -> Void) {
        let clamped = min(percent, 100)
        queue.async {
            let result: Result<Int, Swift.Error>
            let services = Self.externalServices()
            guard !services.isEmpty else {
                DispatchQueue.main.async { completion(.failure(Error.noExternalDisplay)) }
                return
            }

            var successfulWrites = 0
            for service in services {
                if Self.writeBrightness(clamped, to: service) {
                    successfulWrites += 1
                }
            }

            result = successfulWrites > 0 ? .success(successfulWrites) : .failure(Error.writeFailed)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func externalServices() -> [IOAVService] {
        guard let matching = IOServiceMatching("DCPAVServiceProxy") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [IOAVService] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }

            guard
                let rawLocation = IORegistryEntryCreateCFProperty(
                    entry,
                    "Location" as CFString,
                    kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively)
                )?.takeRetainedValue(),
                let location = rawLocation as? String,
                location == "External",
                let unmanaged = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)
            else { continue }

            services.append(unmanaged.takeRetainedValue() as IOAVService)
        }
        return services
    }

    private static func writeBrightness(_ value: UInt16, to service: IOAVService) -> Bool {
        var packet = DDCPacket.setVCP(command: DDCPacket.brightnessCommand, value: value)
        var succeeded = false

        // MonitorControl writes twice with a short delay to accommodate panels
        // that miss the first DDC frame after idle.
        for _ in 0..<2 {
            usleep(10_000)
            let status = IOAVServiceWriteI2C(
                service,
                UInt32(DDCPacket.chipAddress),
                UInt32(DDCPacket.dataAddress),
                &packet,
                UInt32(packet.count)
            )
            succeeded = succeeded || status == KERN_SUCCESS
        }
        return succeeded
    }
}
