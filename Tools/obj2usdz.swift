//
//  obj2usdz.swift
//  Qoob — build-time art tool (not part of the app target)
//
//  Converts Wavefront OBJ (+ its .mtl and any referenced textures) into USDZ,
//  which is the only mesh format RealityKit's `Entity.load` accepts.
//
//  Model I/O cannot write USDZ on current macOS (`MDLAsset.canExportFileExtension("usdz")`
//  returns false), so this goes through SceneKit, which can. Materials survive as
//  UsdPreviewSurface and referenced textures are embedded in the archive.
//
//  Usage:
//      swift Tools/obj2usdz.swift <out-dir> <spec>...
//
//  where each <spec> is either
//      /path/to/Model.obj              → <out-dir>/Model.usdz
//      /path/to/Model.obj=newname      → <out-dir>/newname.usdz
//
//  The rename form is what maps a pack's naming onto the names the renderer
//  looks for (e.g. `Couch_Large1.obj=sofa` → `sofa.usdz`, found by
//  `FurnitureKind.modelBaseName`).
//
//  No normalising happens here on purpose: the renderer scales and seats every
//  model against the cell footprint at load time, so the converter stays a
//  format shim and nothing else.
//

import Foundation
import SceneKit
import AppKit

/// SceneKit's OBJ reader mishandles an explicit `Ke 0 0 0` in a `.mtl`: it reports
/// the material's `emission` as **white**, so the exported USDZ carries
/// `emissiveColor = (1, 1, 1)` and every surface self-illuminates to flat white in
/// RealityKit — base colour, lighting and shading all invisible. (A `.mtl` with no
/// `Ke` line at all reads correctly as black, which is why texture-only packs are
/// unaffected and colour-only ones are ruined.)
///
/// So the `.mtl` is parsed here for the real `Ke` values and they're reapplied to
/// the loaded materials before export. Genuine emissive materials still survive.
func emissionByMaterialName(forOBJ obj: URL) -> [String: NSColor] {
    // Resolve the .mtl the OBJ actually references, falling back to <name>.mtl.
    let objText = (try? String(contentsOf: obj, encoding: .utf8)) ?? ""
    var mtlName = obj.deletingPathExtension().lastPathComponent + ".mtl"
    for line in objText.split(separator: "\n") where line.hasPrefix("mtllib ") {
        mtlName = line.dropFirst("mtllib ".count).trimmingCharacters(in: .whitespaces)
        break
    }
    let mtlURL = obj.deletingLastPathComponent().appendingPathComponent(mtlName)
    guard let text = try? String(contentsOf: mtlURL, encoding: .utf8) else { return [:] }

    var out: [String: NSColor] = [:]
    var current: String?
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let parts = line.split(separator: " ").filter { !$0.isEmpty }
        if parts.first == "newmtl", parts.count >= 2 {
            current = parts.dropFirst().joined(separator: " ")
            // Absent `Ke` means no emission; seed black so it's corrected either way.
            out[current!] = .black
        } else if parts.first == "Ke", parts.count >= 4, let name = current {
            let c = parts.dropFirst().compactMap { Double($0) }
            if c.count >= 3 {
                out[name] = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
            }
        }
    }
    return out
}

var args = Array(CommandLine.arguments.dropFirst())

// `--dataset` wraps each result in an asset-catalogue Data Set instead of writing
// a bare .usdz, so models can ship inside Assets.xcassets. That matters because
// the catalogue is already a folder reference in the project: anything added
// inside it is compiled in without touching project.pbxproj.
var datasetPrefix: String?
args.removeAll { arg in
    guard arg == "--dataset" || arg.hasPrefix("--dataset=") else { return false }
    datasetPrefix = arg.hasPrefix("--dataset=") ? String(arg.dropFirst("--dataset=".count)) : "Model_"
    return true
}

guard args.count >= 2 else {
    FileHandle.standardError.write(Data(
        "usage: obj2usdz [--dataset[=PREFIX]] <out-dir> <in.obj[=outname]>...\n".utf8))
    exit(2)
}

let outDir = URL(fileURLWithPath: args[0], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var failures = 0

/// Wraps an already-written .usdz in a `<prefix><name>.dataset` directory,
/// matching the layout Xcode writes for a Data Set.
func wrapInDataSet(_ usdz: URL, named name: String, prefix: String) throws -> URL {
    let setDir = outDir.appendingPathComponent("\(prefix)\(name).dataset", isDirectory: true)
    try FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)
    let moved = setDir.appendingPathComponent(usdz.lastPathComponent)
    if FileManager.default.fileExists(atPath: moved.path) {
        try FileManager.default.removeItem(at: moved)
    }
    try FileManager.default.moveItem(at: usdz, to: moved)
    let contents = """
    {
      "data" : [
        {
          "filename" : "\(moved.lastPathComponent)",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try Data(contents.utf8).write(to: setDir.appendingPathComponent("Contents.json"))
    return moved
}

for spec in args.dropFirst() {
    // Split on the last "=" so paths containing "=" still work.
    let src: String
    var outName: String
    if let eq = spec.lastIndex(of: "=") {
        src = String(spec[spec.startIndex..<eq])
        outName = String(spec[spec.index(after: eq)...])
    } else {
        src = spec
        outName = (spec as NSString).lastPathComponent
    }
    if outName.lowercased().hasSuffix(".obj") { outName = String(outName.dropLast(4)) }

    let srcURL = URL(fileURLWithPath: src)
    let dstURL = outDir.appendingPathComponent(outName).appendingPathExtension("usdz")

    do {
        // SceneKit finds the .mtl next to the .obj, but resolves the *texture* paths
        // the .mtl names (e.g. `map_Kd Textures/colormap.png`) against the process
        // working directory — not the model's folder. Loading by absolute path from
        // elsewhere therefore drops the texture silently: you get a valid USDZ with
        // an untextured material and no error. So run each load from the model's own
        // directory.
        let previousCWD = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(srcURL.deletingLastPathComponent().path)
        defer { FileManager.default.changeCurrentDirectoryPath(previousCWD) }

        let scene = try SCNScene(url: srcURL, options: [.checkConsistency: true])

        // Undo the reader's bogus white emission before export (see above).
        let emission = emissionByMaterialName(forOBJ: srcURL)
        var corrected = 0
        func fixMaterials(_ node: SCNNode) {
            for material in node.geometry?.materials ?? [] {
                guard let name = material.name, let want = emission[name] else { continue }
                material.emission.contents = want
                corrected += 1
            }
            node.childNodes.forEach(fixMaterials)
        }
        fixMaterials(scene.rootNode)

        guard scene.write(to: dstURL, options: nil, delegate: nil, progressHandler: nil) else {
            print("FAIL  \(outName): SceneKit declined to write USDZ")
            failures += 1
            continue
        }
        let (min, max) = scene.rootNode.boundingBox
        let size = Int((try? Data(contentsOf: dstURL).count) ?? 0)
        if let prefix = datasetPrefix {
            _ = try wrapInDataSet(dstURL, named: outName, prefix: prefix)
        }
        print(String(format: "ok    %-24s %5.2f x %5.2f x %5.2f  minY %6.2f  %4dKB",
                     (outName as NSString).utf8String!,
                     max.x - min.x, max.y - min.y, max.z - min.z, min.y, size / 1024))
    } catch {
        print("FAIL  \(outName): \(error.localizedDescription)")
        failures += 1
    }
}

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) conversion(s) failed\n".utf8))
    exit(1)
}
