// Standalone parity checker: verifies RSVPTiming.swift reproduces every case
// in parity-vectors.json (generated from the canonical JS twin).
//
//   swiftc -O RSVPTiming.swift check-parity.swift -o /tmp/check-parity && /tmp/check-parity
//
// Also runs as an XCTest in consumers; kept standalone so CI can gate without
// an Xcode project.
import Foundation

let vectorsURL = URL(fileURLWithPath: "parity-vectors.json")
guard let data = try? Data(contentsOf: vectorsURL),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    FileHandle.standardError.write("cannot read parity-vectors.json\n".data(using: .utf8)!)
    exit(2)
}

var failures: [String] = []
func check(_ label: String, _ actual: Any, _ expected: Any) {
    if "\(actual)" != "\(expected)" {
        failures.append("  \(label): swift=\(actual) js=\(expected)")
    }
}

// ORP
for c in root["orp"] as? [[String: Any]] ?? [] {
    let w = c["word"] as! String
    check("orpIndex(\(w.debugDescription))", RSVPTiming.getORPIndex(for: w), c["orpIndex"] as! Int)
    check("actualOrpIndex(\(w.debugDescription))", RSVPTiming.getActualORPIndex(for: w), c["actualOrpIndex"] as! Int)
    let parts = RSVPTiming.splitWordForDisplay(w)
    check("split.before(\(w.debugDescription))", parts.before, c["before"] as! String)
    check("split.orp(\(w.debugDescription))", parts.orp, c["orp"] as! String)
    check("split.after(\(w.debugDescription))", parts.after, c["after"] as! String)
    check("isRenderable(\(w.debugDescription))", RSVPTiming.isRenderable(w), c["renderable"] as! Bool)
}

// Delays — compare at 6dp, matching the generator's rounding
for c in root["delays"] as? [[String: Any]] ?? [] {
    let w = c["word"] as! String
    let got = RSVPTiming.getWordDelay(
        for: w,
        wpm: c["wpm"] as! Int,
        pauseOnPunctuation: c["pauseOnPunctuation"] as! Bool,
        punctuationMultiplier: (c["punctuationMultiplier"] as! NSNumber).doubleValue,
        wordLengthMultiplier: (c["wordLengthMultiplier"] as! NSNumber).doubleValue,
        lineBreakMultiplier: (c["lineBreakMultiplier"] as! NSNumber).doubleValue)
    let want = (c["delayMs"] as! NSNumber).doubleValue
    if abs(got - want) > 1e-6 {
        failures.append("  delay(\(w.debugDescription), wpm=\(c["wpm"]!)): swift=\(got) js=\(want)")
    }
}

// Time remaining
for c in root["timeRemaining"] as? [[String: Any]] ?? [] {
    check("formatTimeRemaining(\(c["remainingWords"]!), \(c["wpm"]!))",
          RSVPTiming.formatTimeRemaining(wordsRemaining: c["remainingWords"] as! Int, wpm: c["wpm"] as! Int),
          c["formatted"] as! String)
}

// Nearest renderable
if let nr = root["nearestRenderable"] as? [String: Any] {
    let tokens = nr["tokens"] as! [String]
    for c in nr["cases"] as! [[String: Any]] {
        let got = RSVPTiming.findNearestRenderableIndex(in: tokens, from: c["startIndex"] as! Int) ?? -1
        check("findNearestRenderable(from: \(c["startIndex"]!))", got, c["index"] as! Int)
    }
}

if failures.isEmpty {
    print("PARITY OK — all vectors reproduced")
} else {
    print("PARITY FAILED — \(failures.count) mismatch(es):")
    failures.prefix(40).forEach { print($0) }
    exit(1)
}
