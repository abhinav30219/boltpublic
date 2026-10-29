import SceneKit
import UIKit

/// Cel shading (three bands from a fixed light plus a soft rim) and the inverted-hull ink outline.
enum ToonShading {
    static var outlineInk: UIColor { UIColor(companionHex: ThemeStore.current.pick(0x3D2A24, 0x3A2763, 0x1E1630)) }
    /// Light direction in view space (toward the light): upper left, in front.
    static let lightDirection = SCNVector3(-0.45, 0.65, 0.62)
    static let outlineNodeName = "outline_hull"

    private static let fragment = """
    #pragma arguments
    float3 lightDir;
    #pragma body
    float3 n = normalize(_surface.normal);
    float3 v = normalize(_surface.view);
    float d = dot(n, normalize(lightDir));
    float band = d > 0.55 ? 1.0 : (d > 0.15 ? 0.86 : 0.66);
    float rim = smoothstep(0.65, 1.0, 1.0 - clamp(dot(n, v), 0.0, 1.0)) * 0.15;
    _output.color.rgb = _output.color.rgb * band + rim;
    """

    private static let outlineGeometry = """
    #pragma arguments
    float outlineWidth;
    #pragma body
    _geometry.position.xyz += _geometry.normal * outlineWidth;
    """

    static func color(for materialName: String?, palette: BodyPalette) -> UIColor? {
        switch materialName {
        case "mat_shell": return palette.shell
        case "mat_joint": return palette.joint
        case "mat_limb": return palette.limb
        case "mat_foot": return palette.foot
        case "mat_accent": return palette.joint
        default: return nil
        }
    }

    /// Replaces each named material on every mesh under `root` with a toon material in the palette colour.
    /// Safe to call again when the palette changes.
    static func apply(to root: SCNNode, appearance: Appearance) {
        root.enumerateHierarchy { node, _ in
            guard node.name != outlineNodeName, let geometry = node.geometry else { return }
            geometry.materials = geometry.materials.map { old in
                guard let color = color(for: old.name, palette: appearance.palette) else { return old }
                return toonMaterial(name: old.name, color: color)
            }
        }
    }

    private static func toonMaterial(name: String?, color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.isDoubleSided = false
        m.shaderModifiers = [.fragment: fragment]
        m.setValue(lightDirection, forKey: "lightDir")
        return m
    }

    /// Adds an ink hull as a child of every mesh node so it inherits the pose. Call once after loading.
    static func addOutline(to root: SCNNode, width: Double) {
        let ink = SCNMaterial()
        ink.name = "ink"
        ink.lightingModel = .constant
        ink.diffuse.contents = outlineInk
        ink.cullMode = .front
        ink.shaderModifiers = [.geometry: outlineGeometry]
        ink.setValue(width, forKey: "outlineWidth")

        var meshes: [SCNNode] = []
        root.enumerateHierarchy { node, _ in
            if node.geometry != nil, node.name != outlineNodeName { meshes.append(node) }
        }
        for mesh in meshes {
            guard let geometry = mesh.geometry?.copy() as? SCNGeometry else { continue }
            geometry.materials = [ink]
            let hull = SCNNode(geometry: geometry)
            hull.name = outlineNodeName
            mesh.addChildNode(hull)
        }
    }
}
