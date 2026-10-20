// CI-only local media fixture. No Photos access, account, network, or private data.
import Foundation
import AVFoundation
import CoreVideo

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 320, AVVideoHeightKey: 240
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240
])
precondition(writer.canAdd(input), "Synthetic video input must be supported")
writer.add(input)
precondition(writer.startWriting(), "Synthetic video writer must start")
writer.startSession(atSourceTime: .zero)
let deadline = Date().addingTimeInterval(30)
for frame in 0..<60 {
    while !input.isReadyForMoreMediaData {
        precondition(Date() < deadline && writer.status == .writing, "Synthetic video encoder timed out")
        Thread.sleep(forTimeInterval: 0.005)
    }
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for y in 0..<240 {
        for x in 0..<320 {
            let offset = y * stride + x * 4
            bytes[offset] = 255
            bytes[offset + 1] = UInt8(40 + (frame * 3) % 180)
            bytes[offset + 2] = UInt8(120 + x % 80)
            bytes[offset + 3] = UInt8(100 + y % 70)
        }
    }
    precondition(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)), "Synthetic frame append failed")
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
}
input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
precondition(finished.wait(timeout: .now() + 30) == .success && writer.status == .completed, "Synthetic video export failed")
print("Generated a 20-second synthetic local video (3 fps); this is not a performance benchmark")
