#!/usr/bin/env swift
import Foundation
import Vision
import CoreGraphics
import ImageIO

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
var items: [OCRItem] = []
var requestError: Error?

let request = VNRecognizeTextRequest { request, error in
    requestError = error
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

        items.append(
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

do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    if let requestError { throw requestError }
    writeJSON(OCRResponse(ok: true, width: width, height: height, items: items, error: nil))
} catch {
    writeJSON(
        OCRResponse(ok: false, width: width, height: height, items: items, error: String(describing: error)),
        exitCode: 1
    )
}
