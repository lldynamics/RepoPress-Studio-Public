#!/usr/bin/env swift

import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count >= 3 else {
  fputs("usage: render_text_png.swift OUTPUT TEXT\n", stderr)
  exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let text = CommandLine.arguments.dropFirst(2).joined(separator: " ")
let size = NSSize(width: 1800, height: 280)
let image = NSImage(size: size)
image.lockFocus()
NSColor.white.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
(text as NSString).draw(
  in: NSRect(x: 32, y: 92, width: 1736, height: 120),
  withAttributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 38, weight: .regular),
    .foregroundColor: NSColor.black,
  ]
)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
  fputs("render_text_png: failed to encode PNG\n", stderr)
  exit(1)
}
try png.write(to: outputURL, options: .atomic)
