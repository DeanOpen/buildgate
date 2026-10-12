// Helper for screenshots.sh.
//   swift shot-helper.swift wid "BuildGate Logs"   -> CGWindow id of that window
//   swift shot-helper.swift rect x y w h pad        -> screencapture -R rect for an AppKit frame
import AppKit

let a = CommandLine.arguments
if a[1] == "wid" {
    let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as! [[String: Any]]
    if let w = list.first(where: { ($0["kCGWindowName"] as? String) == a[2] }) { print(w["kCGWindowNumber"]!) }
} else {
    let v = a[2...6].map { Double($0)! }
    let mainH = NSScreen.screens[0].frame.height  // AppKit y is bottom-up from the main screen
    let pad = v[4]
    print("\(Int(v[0] - pad * 4)),\(Int(mainH - v[1] - v[3])),\(Int(v[2] + pad * 5)),\(Int(v[3]))")
}
