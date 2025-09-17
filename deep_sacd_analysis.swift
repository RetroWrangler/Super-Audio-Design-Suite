#!/usr/bin/env swift

import Foundation

class DeepSACDAnalysis {
    private let fileHandle: FileHandle
    
    init(url: URL) throws {
        self.fileHandle = try FileHandle(forReadingFrom: url)
    }
    
    deinit {
        fileHandle.closeFile()
    }
    
    func readSector(_ sector: UInt32) throws -> Data {
        let offset = UInt64(sector) * UInt64(2048)
        try fileHandle.seek(toOffset: offset)
        return fileHandle.readData(ofLength: 2048)
    }
    
    func hexDumpRaw(data: Data, maxBytes: Int = 64) {
        let bytes = Array(data.prefix(maxBytes))
        for (i, byte) in bytes.enumerated() {
            if i % 16 == 0 && i > 0 {
                print()
            }
            print(String(format: "%02x ", byte), terminator: "")
        }
        print()
    }
    
    func analyzeInDepth() throws {
        print("=== Deep SACD Analysis ===")
        
        // Check MASTER.TOC sector 510 in detail
        print("\n--- MASTER.TOC Sector 510 Analysis ---")
        let masterTOC = try readSector(510)
        
        // Check for SACDMTOC signature
        let signatureData = "SACDMTOC".data(using: .ascii)!
        if let range = masterTOC.range(of: signatureData) {
            print("✓ SACDMTOC found at offset \(range.lowerBound)")
        } else {
            print("❌ SACDMTOC signature not found")
        }
        
        print("First 64 bytes of MASTER.TOC:")
        hexDumpRaw(data: masterTOC, maxBytes: 64)
        
        // Check for ASCII strings that should be there
        if let albumTitle = String(data: masterTOC[24..<40], encoding: .ascii) {
            print("Album title area: '\(albumTitle.trimmingCharacters(in: .controlCharacters))'")
        }
        
        // Check version bytes
        let major = masterTOC[8]
        let minor = masterTOC[9]
        print("Version: \(major).\(minor)")
        
        // Check Area TOC sector 540
        print("\n--- Area TOC Sector 540 Analysis ---")
        let areaTOC = try readSector(540)
        
        let areaSignature = "SACDSTOC".data(using: .ascii)!
        if let range = areaTOC.range(of: areaSignature) {
            print("✓ SACDSTOC found at offset \(range.lowerBound)")
        } else {
            print("❌ SACDSTOC signature not found")
        }
        
        print("First 64 bytes of Area TOC:")
        hexDumpRaw(data: areaTOC, maxBytes: 64)
        
        // Check track count
        if areaTOC.count >= 18 {
            let trackCount = UInt16(bigEndian: areaTOC.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt16.self) })
            print("Track count: \(trackCount)")
        }
        
        // Check audio data location
        print("\n--- Audio Data Analysis ---")
        let audioSector: UInt32 = 560  // Should start around here
        let audioData = try readSector(audioSector)
        
        // Check if it looks like DSD data
        let uniqueBytes = Set(audioData.prefix(1024))
        print("Audio sector \(audioSector) - unique byte values: \(uniqueBytes.count)")
        
        if uniqueBytes.count < 10 {
            print("❌ Very low diversity - might not be proper audio data")
        } else if uniqueBytes.count > 200 {
            print("✓ High diversity - looks like valid audio data")
        } else {
            print("⚠️ Medium diversity - might be valid but check quality")
        }
        
        print("First 32 bytes of audio data:")
        hexDumpRaw(data: audioData, maxBytes: 32)
        
        // File size validation
        let fileSize = try fileHandle.seekToEnd()
        let sectors = fileSize / 2048
        print("\n--- File Structure Summary ---")
        print("Total file size: \(fileSize) bytes (\(sectors) sectors)")
        print("Expected structure:")
        print("  Sectors 0-509: UDF/Zero padding")
        print("  Sectors 510-512: MASTER.TOC (3 copies)")
        print("  Sectors 513-539: Reserved")
        print("  Sectors 540-541: Area TOC (2 copies)")
        print("  Sectors 542+: Audio data")
        
        if sectors < 542 {
            print("❌ File too small - missing audio data")
        } else {
            print("✓ File size looks reasonable")
        }
    }
}

let isoPath = "/Volumes/cory/Desktop/SACD_R_Generated.iso"
do {
    let analyzer = try DeepSACDAnalysis(url: URL(fileURLWithPath: isoPath))
    try analyzer.analyzeInDepth()
} catch {
    print("Error: \(error)")
}