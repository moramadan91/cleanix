import Foundation
import Vision

/// Groups visually similar images with Apple's on-device Vision feature prints. Nothing leaves the Mac.
public struct SimilarImagesScanner: Sendable {
    private let roots: [URL]
    private let maxDistance: Float

    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "gif"]

    public init(roots: [URL], maxDistance: Float = 0.5) {
        self.roots = roots
        self.maxDistance = maxDistance
    }

    public func groups() async throws -> [DuplicateGroup] {
        var prints: [(item: ScanItem, print: VNFeaturePrintObservation)] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = walker.nextObject() as? URL {
                try Task.checkCancellation()
                guard Self.extensions.contains(url.pathExtension.lowercased()),
                      let observation = Self.featurePrint(of: url) else { continue }
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                prints.append((ScanItem(url: url, bytes: bytes, reason: "Looks like another image", safety: .review,
                                        group: url.lastPathComponent), observation))
            }
        }

        var clusters: [[(item: ScanItem, print: VNFeaturePrintObservation)]] = []
        for entry in prints {
            try Task.checkCancellation()
            let home = clusters.firstIndex { cluster in
                var distance: Float = .greatestFiniteMagnitude
                return (try? cluster[0].print.computeDistance(&distance, to: entry.print)) != nil && distance <= maxDistance
            }
            if let home { clusters[home].append(entry) } else { clusters.append([entry]) }
        }
        return clusters.filter { $0.count > 1 }.map { cluster in
            let sorted = cluster.map(\.item).sorted { $0.bytes > $1.bytes }
            return DuplicateGroup(keep: sorted[0], extras: Array(sorted.dropFirst()))
        }
    }

    private static func featurePrint(of url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url)
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.first
    }
}
