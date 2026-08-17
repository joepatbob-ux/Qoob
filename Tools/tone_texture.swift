#!/usr/bin/env swift
//
//  tone_texture.swift
//  Qoob
//
//  Desaturates and lightens a texture, then writes it out at a given size.
//
//  Exists because photographic material libraries are shot for realism, not for a
//  game with a readable palette. The industrial carpets came in at full saturation —
//  acid yellow-green, deep purple — and on the floor of a room that also holds a cyan
//  sofa and a white cat, the floor won. Qoob has to be the most legible thing on
//  screen; a floor is a background. Pulling the saturation back keeps the weave, which
//  is the part worth having, and gives up the part that was fighting.
//
//  Usage: swift Tools/tone_texture.swift <in> <out.png> <size> <saturation> <brightness>
//
import CoreImage
import Foundation
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3,
      let input = CIImage(contentsOf: URL(fileURLWithPath: args[0])) else {
    FileHandle.standardError.write(Data(
        "usage: tone_texture <in> <out.png> <size> [saturation=0.45] [brightness=0.06]\n".utf8))
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])
let size = args.count > 2 ? (Double(args[2]) ?? 512) : 512
let saturation = args.count > 3 ? (Double(args[3]) ?? 0.45) : 0.45
let brightness = args.count > 4 ? (Double(args[4]) ?? 0.06) : 0.06

var image = input.applyingFilter("CIColorControls", parameters: [
    kCIInputSaturationKey: saturation,
    kCIInputBrightnessKey: brightness,
    kCIInputContrastKey: 1.0,
])
// Resize last, so the filter runs on the full-resolution source.
let scale = size / Double(input.extent.width)
image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

let context = CIContext()
guard let cg = context.createCGImage(image, from: image.extent) else {
    FileHandle.standardError.write(Data("failed to render\n".utf8)); exit(1)
}
let rep = NSBitmapImageRep(cgImage: cg)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode\n".utf8)); exit(1)
}
try data.write(to: outURL)
let px = Int(image.extent.width)
print("ok    \(outURL.lastPathComponent)  \(px)×\(px)  saturation \(saturation)  "
      + "\(data.count / 1024)KB")
