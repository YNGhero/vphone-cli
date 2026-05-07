#!/usr/bin/env swift
import Foundation
import Vision
import CoreGraphics
import ImageIO
import CoreImage

// 中文注释：macOS 原生 Vision OCR 小工具。
// 输入一张截图路径，输出 JSON；坐标统一转换成 vphone 截图像素坐标：
// x 从左到右，y 从上到下，和 screen.tap(x, y) 使用同一个坐标系。

struct OCRItem: Codable {
    let text: String
    let confidence: Float
    let frame_pixels: [String: Double]
    let center_pixels: [String: Double]
}

struct OCRResponse: Codable {
    let ok: Bool
    let width: Int
    let height: Int
    let items: [OCRItem]
    let error: String?
}

func writeJSON(_ response: OCRResponse, exitCode: Int32 = 0) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(response)) ?? Data("{}".utf8)
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(exitCode)
}

let args = CommandLine.arguments.dropFirst()
guard let imagePath = args.first else {
    writeJSON(
        OCRResponse(ok: false, width: 0, height: 0, items: [], error: "usage: vision_ocr.swift <image-path>"),
        exitCode: 2
    )
}

let url = URL(fileURLWithPath: imagePath)
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
else {
    writeJSON(OCRResponse(ok: false, width: 0, height: 0, items: [], error: "failed to load image"), exitCode: 1)
}

let width = image.width
let height = image.height

final class OCRRequestState {
    var items: [OCRItem] = []
    var error: Error?
}

func makeRecognizeTextRequest(state: OCRRequestState) -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest { request, error in
        state.error = error
        guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let bb = obs.boundingBox

            // 中文注释：Vision 的 boundingBox 是归一化坐标，origin 在左下；
            // vphone 截图和点击坐标 origin 在左上，所以 y 需要翻转。
            let x = Double(bb.origin.x) * Double(width)
            let y = (1.0 - Double(bb.origin.y) - Double(bb.height)) * Double(height)
            let w = Double(bb.width) * Double(width)
            let h = Double(bb.height) * Double(height)

            state.items.append(
                OCRItem(
                    text: top.string,
                    confidence: top.confidence,
                    frame_pixels: [
                        "x": x,
                        "y": y,
                        "width": w,
                        "height": h,
                        "max_x": x + w,
                        "max_y": y + h,
                    ],
                    center_pixels: [
                        "x": x + w / 2.0,
                        "y": y + h / 2.0,
                    ]
                )
            )
        }
    }

    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    // 中文注释：白字蓝底按钮上的 “Next” 相对整张截图较小，降低最小文字高度避免被 Vision 忽略。
    request.minimumTextHeight = 0.006
    return request
}

func recognize(_ cgImage: CGImage) throws -> [OCRItem] {
    let state = OCRRequestState()
    let request = makeRecognizeTextRequest(state: state)
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    if let requestError = state.error { throw requestError }
    return state.items
}

func colorControls(_ input: CIImage, contrast: Double, brightness: Double = 0.0, saturation: Double = 1.0) -> CIImage? {
    guard let filter = CIFilter(name: "CIColorControls") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(contrast, forKey: kCIInputContrastKey)
    filter.setValue(brightness, forKey: kCIInputBrightnessKey)
    filter.setValue(saturation, forKey: kCIInputSaturationKey)
    return filter.outputImage
}

func invert(_ input: CIImage) -> CIImage? {
    guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    return filter.outputImage
}

func mono(_ input: CIImage) -> CIImage? {
    guard let filter = CIFilter(name: "CIPhotoEffectMono") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    return filter.outputImage
}

func cgImage(from ciImage: CIImage, context: CIContext) -> CGImage? {
    context.createCGImage(ciImage, from: ciImage.extent)
}

func normalizedText(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func isNearDuplicate(_ item: OCRItem, _ existing: OCRItem) -> Bool {
    guard normalizedText(item.text) == normalizedText(existing.text) else { return false }
    let dx = abs((item.center_pixels["x"] ?? 0) - (existing.center_pixels["x"] ?? 0))
    let dy = abs((item.center_pixels["y"] ?? 0) - (existing.center_pixels["y"] ?? 0))
    if dx <= 12 && dy <= 12 { return true }

    let ax1 = item.frame_pixels["x"] ?? 0
    let ay1 = item.frame_pixels["y"] ?? 0
    let ax2 = item.frame_pixels["max_x"] ?? ax1
    let ay2 = item.frame_pixels["max_y"] ?? ay1
    let bx1 = existing.frame_pixels["x"] ?? 0
    let by1 = existing.frame_pixels["y"] ?? 0
    let bx2 = existing.frame_pixels["max_x"] ?? bx1
    let by2 = existing.frame_pixels["max_y"] ?? by1

    let ix = max(0, min(ax2, bx2) - max(ax1, bx1))
    let iy = max(0, min(ay2, by2) - max(ay1, by1))
    let inter = ix * iy
    let areaA = max(1, (ax2 - ax1) * (ay2 - ay1))
    let areaB = max(1, (bx2 - bx1) * (by2 - by1))
    return inter / min(areaA, areaB) >= 0.75
}

func appendDedup(_ newItems: [OCRItem], into items: inout [OCRItem]) {
    for item in newItems {
        if items.contains(where: { isNearDuplicate(item, $0) }) { continue }
        items.append(item)
    }
}

func buildImageVariants(from image: CGImage) -> [CGImage] {
    // 中文注释：Vision 偶尔漏识别蓝色按钮上的白字。这里对同一张截图做多路预处理：
    // 原图、高对比灰度、反色、反色高对比。坐标不变，最后做去重合并。
    let ci = CIImage(cgImage: image)
    let context = CIContext(options: nil)
    var variants: [CGImage] = [image]

    if let monoImage = mono(ci),
       let highContrastMono = colorControls(monoImage, contrast: 2.2),
       let cg = cgImage(from: highContrastMono, context: context) {
        variants.append(cg)
    }

    if let inverted = invert(ci),
       let cg = cgImage(from: inverted, context: context) {
        variants.append(cg)
    }

    if let inverted = invert(ci),
       let highContrastInverted = colorControls(inverted, contrast: 2.4, saturation: 0.3),
       let cg = cgImage(from: highContrastInverted, context: context) {
        variants.append(cg)
    }

    return variants
}

var items: [OCRItem] = []

do {
    for variant in buildImageVariants(from: image) {
        let recognized = try recognize(variant)
        appendDedup(recognized, into: &items)
    }
    writeJSON(OCRResponse(ok: true, width: width, height: height, items: items, error: nil))
} catch {
    writeJSON(
        OCRResponse(ok: false, width: width, height: height, items: items, error: String(describing: error)),
        exitCode: 1
    )
}
