// Usage: xcrun swift tools/robot-rig/scenekit_check.swift App/Resources/Robot.usdz   (macOS)
// Loads the asset the way the app will (SCNScene) and checks every contract name is found exactly once.
import Foundation
import SceneKit

guard CommandLine.arguments.count > 1 else { print("usage: scenekit_check.swift <Robot.usdz>"); exit(2) }
let scene: SCNScene
do { scene = try SCNScene(url: URL(fileURLWithPath: CommandLine.arguments[1]), options: nil) }
catch { print("FAIL: cannot load: \(error)"); exit(1) }

let legs = ["FL", "FR", "BL", "BR"]
let joints = legs.flatMap { l in ["hip", "knee", "ankle"].map { "\($0)_\(l)" } }
let parts = ["body"] + legs.flatMap { l in ["upperLeg", "lowerLeg", "foot"].map { "\($0)_\(l)" } } + ["kneeSleeve_FL", "kneeSleeve_FR"]
let contract = ["robot"] + joints + ["face_anchor"] + parts

var failures: [String] = []
func count(_ name: String) -> Int {
    var n = 0
    scene.rootNode.enumerateHierarchy { node, _ in if node.name == name { n += 1 } }
    return n
}
for name in contract where count(name) != 1 { failures.append("\(name): found \(count(name)) times (want 1)") }

print("top-level nodes: \(scene.rootNode.childNodes.map { $0.name ?? "?" })")
for j in joints {
    guard let n = scene.rootNode.childNode(withName: j, recursively: true) else { continue }
    let e = n.eulerAngles, w = n.simdWorldPosition
    print(String(format: "%@ euler=(%.4f, %.4f, %.4f) worldPos=(%.3f, %.3f, %.3f)", j, e.x, e.y, e.z, w.x, w.y, w.z))
    if abs(e.x) > 1e-4 || abs(e.y) > 1e-4 || abs(e.z) > 1e-4 { failures.append("\(j): rest eulerAngles not zero") }
}
if let fa = scene.rootNode.childNode(withName: "face_anchor", recursively: true) {
    print("face_anchor worldPos=\(fa.simdWorldPosition) (Y-up world; face is local -Y of body)")
}
// Which material names does SceneKit see on each part's geometry?
let want: [String: String] = ["body": "mat_shell", "kneeSleeve_FL": "mat_joint", "kneeSleeve_FR": "mat_joint"]
for p in parts {
    var geoms: [SCNGeometry] = []
    scene.rootNode.childNode(withName: p, recursively: true)?.enumerateHierarchy { n, _ in if let g = n.geometry { geoms.append(g) } }
    let mats = geoms.flatMap { $0.materials.map { $0.name ?? "nil" } }
    print("\(p) geometry nodes=\(geoms.count) materials=\(mats)")
    let expected = want[p] ?? (p.hasPrefix("upperLeg") ? "mat_limb" : p.hasPrefix("lowerLeg") ? "mat_joint" : p.hasPrefix("foot") ? "mat_foot" : nil)
    if let e = expected, !mats.contains(e) { failures.append("\(p): SceneKit materials \(mats), want \(e)") }
}
if let m = scene.rootNode.childNode(withName: "upperLeg_FL_mesh", recursively: true) {
    print("upperLeg_FL_mesh materials=\(m.geometry?.materials.map { $0.name ?? "nil" } ?? [])")
}
if failures.isEmpty { print("SCENEKIT OK") } else { print("SCENEKIT FAIL"); failures.forEach { print(" - \($0)") }; exit(1) }
