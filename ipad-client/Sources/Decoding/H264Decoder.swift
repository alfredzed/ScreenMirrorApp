//
//  H264Decoder.swift
//  ScreenMirrorApp (iPad client)
//
//  README.md 3.2「バイナリ映像フレーム」で送られてくる H.264 Annex-B ストリームを
//  VideoToolbox (VTDecompressionSession) でハードウェアデコードし、CVPixelBuffer を得る。
//
//  サーバー側は各キーフレームの直前に SPS/PPS を再送する設定 (repeat-headers=1) のため、
//  再接続直後や途中からの受信でもキーフレーム到達時点でフォーマットを再構築できる。

import Foundation
import VideoToolbox
import CoreMedia

final class H264Decoder {

    /// デコードが完了するたびに呼ばれる。表示はメインスレッドで行うこと。
    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var frameCount: Int64 = 0

    /// README 3.2 のヘッダー付きバイナリフレーム(1バイト種別 + Annex-Bデータ)を受け取り、デコードする。
    func decode(packet: Data) {
        guard packet.count > 1 else { return }
        let isKeyframe = packet[packet.startIndex] == 0x01
        let payload = packet.subdata(in: (packet.startIndex + 1)..<packet.endIndex)
        decodeAnnexB(payload, isKeyframe: isKeyframe)
    }

    private func decodeAnnexB(_ data: Data, isKeyframe: Bool) {
        let nalUnits = Self.splitAnnexB(data)
        guard !nalUnits.isEmpty else { return }

        var vclUnits: [Data] = []
        var spsUnit: Data?
        var ppsUnit: Data?

        for nal in nalUnits {
            guard let first = nal.first else { continue }
            let nalType = first & 0x1F
            switch nalType {
            case 7: spsUnit = nal
            case 8: ppsUnit = nal
            case 6, 9: break // SEI / AUD は描画に不要のためスキップ
            default: vclUnits.append(nal)
            }
        }

        if let sps = spsUnit, let pps = ppsUnit, sps != lastSPS || pps != lastPPS {
            lastSPS = sps
            lastPPS = pps
            rebuildFormatDescription(sps: sps, pps: pps)
        }

        guard let formatDescription, !vclUnits.isEmpty else { return }
        if session == nil {
            createSession(formatDescription: formatDescription)
        }
        guard let session else { return }

        guard let avccData = Self.annexBUnitsToAVCC(vclUnits) else { return }
        submit(avccData: avccData, formatDescription: formatDescription, session: session)
    }

    // MARK: - フォーマット記述の構築

    private func rebuildFormatDescription(sps: Data, pps: Data) {
        // 既存セッションは新しいSPS/PPSに対して無効になるため破棄し、次のフレームで再生成する。
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil

        var newFormatDescription: CMFormatDescription?
        // The pointers must remain valid for the duration of the VideoToolbox call.
        // Do not build an array of pointers outside these nested Data scopes.
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(kCMFormatDescriptionError_InvalidParameter)
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDescription
                )
            }
        }
        if status == noErr {
            formatDescription = newFormatDescription
        } else {
            print("[H264Decoder] フォーマット記述の作成に失敗: status=\(status)")
        }
    }

    private func createSession(formatDescription: CMVideoFormatDescription) {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let destinationAttributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        if status == noErr {
            session = newSession
        } else {
            print("[H264Decoder] VTDecompressionSessionの作成に失敗: status=\(status)")
        }
    }

    private func submit(avccData: Data, formatDescription: CMVideoFormatDescription, session: VTDecompressionSession) {
        var blockBuffer: CMBlockBuffer?
        let dataLength = avccData.count

        let status = avccData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> OSStatus in
            let baseAddress = UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress!)
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: baseAddress,
                blockLength: dataLength,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard status == noErr, let blockBuffer else { return }

        frameCount += 1
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frameCount, timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sampleSize = dataLength

        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else { return }

        // データ保持のため、コピーをキャプチャして寿命を延ばす（withUnsafeBytesのスコープ対策）。
        withExtendedLifetime(avccData) {
            var flagsOut = VTDecodeInfoFlags()
            VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &flagsOut
            )
        }
    }

    fileprivate func handleDecoded(pixelBuffer: CVPixelBuffer?, presentationTimeStamp: CMTime, status: OSStatus) {
        guard status == noErr, let pixelBuffer else { return }
        onDecodedFrame?(pixelBuffer, presentationTimeStamp)
    }

    func reset() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        lastSPS = nil
        lastPPS = nil
        frameCount = 0
    }

    // MARK: - NALユニット変換ユーティリティ

    /// Annex-B (0x000001 / 0x00000001 スタートコード区切り) を個々のNALユニットに分割する。
    static func splitAnnexB(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        var start: Int? = nil

        func startCodeLength(at index: Int) -> Int {
            if index + 3 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                return 4
            }
            if index + 2 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                return 3
            }
            return 0
        }

        while i < bytes.count {
            let scLen = startCodeLength(at: i)
            if scLen > 0 {
                if let s = start, i > s {
                    units.append(Data(bytes[s..<i]))
                }
                i += scLen
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count {
            units.append(Data(bytes[s..<bytes.count]))
        }
        return units
    }

    /// スタートコード区切りのNALユニット群を、VideoToolbox向けの4バイト長プレフィックス(AVCC)形式へ変換する。
    static func annexBUnitsToAVCC(_ units: [Data]) -> Data? {
        guard !units.isEmpty else { return nil }
        var result = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            result.append(Data(bytes: &length, count: 4))
            result.append(unit)
        }
        return result
    }
}

/// C関数ポインタとして渡すためのグローバル(または static)コールバック。
private func decompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVPixelBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    decoder.handleDecoded(pixelBuffer: imageBuffer, presentationTimeStamp: presentationTimeStamp, status: status)
}
