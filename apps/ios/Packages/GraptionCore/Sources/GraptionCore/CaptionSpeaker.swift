public func captionSpeaker(
    from samples: [(time: Double, faceID: String, score: Double)],
    during window: ClosedRange<Double>
) -> String {
    let faces = Dictionary(
        grouping: samples.filter { window.contains($0.time) },
        by: { $0.faceID }
    )
    let ranked = faces.map { faceID, samples in
        (faceID: faceID,
         score: samples.reduce(0.0) { $0 + $1.score } / Double(samples.count))
    }.sorted { $0.score > $1.score }

    guard let best = ranked.first else { return "unknown" }
    let second = ranked.dropFirst().first?.score ?? 0
    return best.score >= 0.5 && best.score - second >= 0.15
        ? best.faceID : "unknown"
}
