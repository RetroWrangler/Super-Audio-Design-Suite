#!/usr/bin/env swift

import Foundation

// Copy the structures from ContentView.swift for testing
enum DSDFormat {
    case dsf, dff
    
    var fileExtension: String {
        switch self {
        case .dsf: return "dsf"
        case .dff: return "dff"
        }
    }
}

struct DSDFileInfo {
    let url: URL
    let format: DSDFormat
    let sampleRate: UInt32
    let channels: UInt16
    let bitsPerSample: UInt16
    let sampleCount: UInt64
    let duration: Double
    let fileSize: UInt64
    
    var trackLengthSectors: UInt32 {
        return UInt32((fileSize + 2047) / 2048)
    }
}

struct SACDMasterTOC {
    let signature: String = "SACDMTOC"
    let versionMajor: UInt8 = 1
    let versionMinor: UInt8 = 20
    let albumSetSize: UInt16
    let albumSequenceNumber: UInt16
    let albumCatalogNumber: String
    let albumGenre: [UInt8]
    let area1TOC1Start: UInt32
    let area1TOC2Start: UInt32
    let area1TOCSize: UInt16
    let area2TOC1Start: UInt32
    let area2TOC2Start: UInt32
    let area2TOCSize: UInt16
    let discDateYear: UInt16
    let discDateMonth: UInt8
    let discDateDay: UInt8
    
    init(tracks: [DSDFileInfo], albumTitle: String = "Generated Album", isMultichannel: Bool = false) {
        self.albumSetSize = 1
        self.albumSequenceNumber = 1
        self.albumCatalogNumber = albumTitle.padding(toLength: 16, withPad: " ", startingAt: 0)
        self.albumGenre = [0, 0, 0, 0]
        
        let masterTOCEnd: UInt32 = 540
        
        if isMultichannel {
            self.area1TOC1Start = 0
            self.area1TOC2Start = 0
            self.area1TOCSize = 0
            self.area2TOC1Start = masterTOCEnd
            self.area2TOC2Start = masterTOCEnd + 10
            self.area2TOCSize = 10
        } else {
            self.area1TOC1Start = masterTOCEnd
            self.area1TOC2Start = masterTOCEnd + 10
            self.area1TOCSize = 10
            self.area2TOC1Start = 0
            self.area2TOC2Start = 0
            self.area2TOCSize = 0
        }
        
        let date = Date()
        let calendar = Calendar.current
        self.discDateYear = UInt16(calendar.component(.year, from: date))
        self.discDateMonth = UInt8(calendar.component(.month, from: date))
        self.discDateDay = UInt8(calendar.component(.day, from: date))
    }
    
    func generateBinaryData() -> Data {
        var data = Data()
        
        print("Generating MASTER.TOC binary data...")
        
        // Signature (8 bytes)
        let sigData = signature.data(using: .ascii)!
        print("Signature: \(signature) -> \(sigData.map { String(format: "%02x", $0) }.joined(separator: " "))")
        data.append(sigData)
        
        // Version (2 bytes)
        data.append(contentsOf: [versionMajor, versionMinor])
        print("Version: \(versionMajor).\(versionMinor)")
        
        // Reserved (6 bytes)
        data.append(Data(count: 6))
        
        // Album set size (2 bytes, big-endian)
        data.append(contentsOf: withUnsafeBytes(of: albumSetSize.bigEndian) { Array($0) })
        
        // Album sequence number (2 bytes, big-endian)
        data.append(contentsOf: withUnsafeBytes(of: albumSequenceNumber.bigEndian) { Array($0) })
        
        // Reserved (4 bytes)
        data.append(Data(count: 4))
        
        // Album catalog number (16 bytes)
        let catalogData = albumCatalogNumber.data(using: .ascii) ?? Data()
        data.append(catalogData.prefix(16))
        if catalogData.count < 16 {
            data.append(Data(count: 16 - catalogData.count))
        }
        
        // Album genre (4 bytes)
        data.append(contentsOf: albumGenre)
        
        // Reserved (4 bytes)
        data.append(Data(count: 4))
        
        // Area 1 (2CH) information
        data.append(contentsOf: withUnsafeBytes(of: area1TOC1Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area1TOC2Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area1TOCSize.bigEndian) { Array($0) })
        
        // Reserved (2 bytes)
        data.append(Data(count: 2))
        
        // Area 2 (MCH) information
        data.append(contentsOf: withUnsafeBytes(of: area2TOC1Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area2TOC2Start.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: area2TOCSize.bigEndian) { Array($0) })
        
        // Reserved (2 bytes)
        data.append(Data(count: 2))
        
        // Disc date
        data.append(contentsOf: withUnsafeBytes(of: discDateYear.bigEndian) { Array($0) })
        data.append(contentsOf: [discDateMonth, discDateDay])
        
        // Reserved (4 bytes)
        data.append(Data(count: 4))
        
        print("Current data size: \(data.count) bytes")
        
        // Pad to sector size (2048 bytes)
        let remainingBytes = 2048 - data.count
        if remainingBytes > 0 {
            data.append(Data(count: remainingBytes))
        }
        
        print("Final data size: \(data.count) bytes")
        print("First 64 bytes: \(data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " "))")
        
        return data
    }
}

// Test the generation
print("=== Testing MASTER.TOC Generation ===")

// Create a fake DSD file info
let testTrack = DSDFileInfo(
    url: URL(fileURLWithPath: "/fake/test.dsf"),
    format: .dsf,
    sampleRate: 2822400,
    channels: 2,
    bitsPerSample: 1,
    sampleCount: 0,
    duration: 180.0,
    fileSize: 1024 * 1024
)

let masterTOC = SACDMasterTOC(tracks: [testTrack], albumTitle: "Test Album", isMultichannel: false)
let tocData = masterTOC.generateBinaryData()

print("\n=== Generated TOC Analysis ===")
print("Data contains SACDMTOC signature: \(tocData.range(of: "SACDMTOC".data(using: .ascii)!) != nil)")

// Check if it's all the same pattern
let firstByte = tocData[0]
let allSame = tocData.allSatisfy { $0 == firstByte }
print("All bytes are the same (\(String(format: "%02x", firstByte))): \(allSame)")

if allSame {
    print("❌ MAJOR PROBLEM: All bytes are identical - generation is completely broken!")
} else {
    print("✅ Data looks varied - generation appears to be working")
}