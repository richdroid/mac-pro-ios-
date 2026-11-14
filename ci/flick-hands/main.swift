// The flick's scripted hands (TVApp/Sources/TVFlickHand.swift), run on a Mac without the app:
//   swiftc TVApp/Sources/TVFlickHand.swift ci/flick-hands/main.swift -o /tmp/flick-hands && /tmp/flick-hands
import Foundation
let lines = FlickHand.runScripts() + FlickSpring.runChecks()
lines.forEach { print($0) }
let failed = lines.filter { $0.hasSuffix("\"pass\":false}") }.count
print(failed == 0 ? "all \(lines.count) pass" : "\(failed) of \(lines.count) FAIL")
exit(failed == 0 ? 0 : 1)
