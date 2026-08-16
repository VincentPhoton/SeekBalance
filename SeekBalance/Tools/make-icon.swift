// 生成 SeekBalance 应用图标（1024x1024 PNG）
// 用法: swift make-icon.swift <输出.png>
// 设计: DeepSeek 蓝色渐变圆角方块（macOS app 图标风格）+ 白色 ¥
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 圆角背景（macOS 图标圆角比例 ~22.37%）
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
let gradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.33, green: 0.47, blue: 1.00, alpha: 1.0), // 亮蓝
  NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.72, alpha: 1.0), // 深蓝
])!
gradient.draw(in: path, angle: -90)

// 中央白色 ¥ 符号
let text = "¥" as NSString
let font = NSFont.systemFont(ofSize: 540, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
  .font: font,
  .foregroundColor: NSColor.white,
]
let tsize = text.size(withAttributes: attrs)
text.draw(
  at: NSPoint(x: (size - tsize.width) / 2, y: (size - tsize.height) / 2 - 20),
  withAttributes: attrs
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
  let rep = NSBitmapImageRep(data: tiff),
  let png = rep.representation(using: .png, properties: [:])
else {
  fatalError("生成 PNG 失败")
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/seekbalance-icon-1024.png")
try! png.write(to: out)
print("已生成: \(out.path)")
