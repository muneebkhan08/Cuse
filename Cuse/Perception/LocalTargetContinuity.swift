import CoreGraphics

/// Matches a previously selected control across small detector geometry changes.
nonisolated enum LocalTargetContinuity {
    static func matches(label: String, source: String, box: [Double], display: [Double],
                        previousLabel: String, previousSource: String,
                        previousBox: [Double], previousDisplay: [Double]) -> Bool {
        guard label == previousLabel, source == previousSource, display == previousDisplay,
              box.count == 4, previousBox.count == 4,
              (box + previousBox).allSatisfy({ $0.isFinite }) else { return false }
        let current = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1])
        let previous = CGRect(x: previousBox[0], y: previousBox[1],
                              width: previousBox[2] - previousBox[0], height: previousBox[3] - previousBox[1])
        guard current.width > 0, current.height > 0, previous.width > 0, previous.height > 0 else { return false }
        let intersection = current.intersection(previous)
        guard !intersection.isNull else { return false }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = current.width * current.height + previous.width * previous.height - intersectionArea
        return intersectionArea / unionArea >= 0.6
    }
}
