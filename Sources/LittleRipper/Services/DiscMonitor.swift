import Foundation
import DiskArbitration

/// Watches for optical media appearing/disappearing using DiskArbitration.
/// Callbacks are delivered on the main queue.
final class DiscMonitor {
    var onMediaAppeared: ((_ bsdName: String, _ mediaKind: String) -> Void)?
    var onMediaDisappeared: ((_ bsdName: String) -> Void)?

    private var session: DASession?

    private static let opticalKinds = ["IOCDMedia", "IODVDMedia", "IOBDMedia"]

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        let match: [CFString: Any] = [kDADiskDescriptionMediaWholeKey: true]
        let context = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskAppearedCallback(session, match as CFDictionary, { disk, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<DiscMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleAppeared(disk)
        }, context)

        DARegisterDiskDisappearedCallback(session, match as CFDictionary, { disk, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<DiscMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleDisappeared(disk)
        }, context)

        DASessionSetDispatchQueue(session, .main)
    }

    func stop() {
        if let session {
            DASessionSetDispatchQueue(session, nil)
        }
        session = nil
    }

    private func handleAppeared(_ disk: DADisk) {
        guard let bsdName = bsdName(of: disk),
              let desc = DADiskCopyDescription(disk) as? [String: Any],
              let kind = desc[kDADiskDescriptionMediaKindKey as String] as? String,
              Self.opticalKinds.contains(where: { kind.contains($0.dropFirst(2)) || kind == $0 })
        else { return }
        onMediaAppeared?(bsdName, kind)
    }

    private func handleDisappeared(_ disk: DADisk) {
        guard let bsdName = bsdName(of: disk) else { return }
        onMediaDisappeared?(bsdName)
    }

    private func bsdName(of disk: DADisk) -> String? {
        guard let cName = DADiskGetBSDName(disk) else { return nil }
        return String(cString: cName)
    }
}
