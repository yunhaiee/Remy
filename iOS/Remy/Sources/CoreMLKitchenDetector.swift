import Foundation
import UIKit
import CoreML
import CoreImage

/// Official Apache-2.0 YOLOX-M, converted locally to Core ML. A single synchronous request
/// uses the shared detector queue; Core ML schedules supported operations on the Neural Engine.
final class CoreMLKitchenDetector {
    let model: MLModel
    let configuration: MLModelConfiguration
    private let ci = CIContext(options: [.cacheIntermediates:false, .useSoftwareRenderer:true])
    private let labels: [String]
    private let side: Int
    private let inputBuffer: CVPixelBuffer
    init(compiledModel: URL) throws {
        self.labels = Self.cocoLabels
        configuration = MLModelConfiguration();configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              constraint.pixelsWide == 640, constraint.pixelsHigh == 640 else { throw CocoaError(.coderInvalidValue) }
        side = constraint.pixelsWide
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,side,side,kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer)
        guard status == kCVReturnSuccess, let buffer else { throw CocoaError(.coderInvalidValue) }
        inputBuffer = buffer
    }
    func detect(_ image: UIImage) throws -> [KitchenDetection] {
        let side = Double(self.side)
        guard image.size.width > 0, image.size.height > 0 else { throw CocoaError(.coderInvalidValue) }
        let scale = min(side/image.size.width, side/image.size.height)
        let format = UIGraphicsImageRendererFormat();format.scale = 1;format.opaque = true
        let input = UIGraphicsImageRenderer(size: CGSize(width:side,height:side), format:format).image { c in
            UIColor(white:114.0/255,alpha:1).setFill();c.fill(CGRect(x:0,y:0,width:side,height:side))
            image.draw(in:CGRect(x:0,y:0,width:image.size.width*scale,height:image.size.height*scale))
        }
        // Prediction is synchronous and the owning queue allows one request at a time.
        let buffer = inputBuffer
        guard let cg = input.cgImage else { throw CocoaError(.coderInvalidValue) }
        ci.render(CIImage(cgImage:cg), to:buffer)
        let provider = try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(pixelBuffer:buffer)])
        let result = try model.prediction(from:provider)
        guard let array = result.featureValue(for:"detections")?.multiArrayValue, array.shape.count == 3, array.shape[0].intValue == 1, array.shape[1].intValue == 8400, array.shape[2].intValue == 85 else { throw CocoaError(.coderInvalidValue) }
        let n = array.shape[array.shape.count-2].intValue
        let rowStride = array.strides[array.strides.count-2].intValue
        let colStride = array.strides.last!.intValue
        func value(_ row: Int, _ col: Int) -> Float {
            let index = row*rowStride+col*colStride
            switch array.dataType {
            case .float16: return Float(array.dataPointer.assumingMemoryBound(to:Float16.self)[index])
            case .float32: return array.dataPointer.assumingMemoryBound(to:Float.self)[index]
            default: return array[index].floatValue
            }
        }
        var found: [KitchenDetection] = []
        for row in 0..<n where value(row,4) >= 0.25 {
            var best: Float = 0;var label = 0
            for k in 0..<80 { let score = value(row,k+5)*value(row,4);if score > best { best = score;label = k } }
            guard best >= 0.5, label < labels.count else { continue }
            let cx=Double(value(row,0)),cy=Double(value(row,1)),w=Double(value(row,2)),h=Double(value(row,3))
            guard cx.isFinite, cy.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 else { continue }
            let rect = CGRect(x:(cx-w/2)/scale,y:(cy-h/2)/scale,width:w/scale,height:h/scale)
                .intersection(CGRect(origin:.zero,size:image.size))
            if !rect.isNull && rect.width > 0 && rect.height > 0 { found.append(.init(label:labels[label],rect:rect,score:best)) }
        }
        var kept: [KitchenDetection] = []
        for item in found.sorted(by:{$0.score > $1.score}) {
            if !kept.contains(where:{$0.label == item.label && Self.iou($0.rect,item.rect)>0.45}) { kept.append(item) }
            if kept.count == 8 { break }
        }
        return kept
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let common = intersection.width * intersection.height
        let union = a.width*a.height + b.width*b.height - common
        return union > 0 ? common/union : 0
    }
    private static let cocoLabels: [String] = ["person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"]
}

struct KitchenDetection {
    let label: String
    let rect: CGRect
    let score: Float
}
