#!/usr/bin/env swift

import Foundation

class GeneratedSACDAnalyzer {
    private let fileHandle: FileHandle
    private let sectorSize: Int = 2048
    
    init(url: URL) throws {
        self.fileHandle = try FileHandle(forReadingFrom: url)
    }
    
    deinit {
        fileHandle.closeFile()
    }
    
    func readSector(_ sector: UInt32) throws -> Data {
        let offset = UInt64(sector) * UInt64(sectorSize)
        try fileHandle.seek(toOffset: offset)
        return fileHandle.readData(ofLength: sectorSize)
    }
    
    func hexDump(data: Data, offset: Int = 0, length: Int = 256) {
        let endIndex = min(offset + length, data.count)
        for i in stride(from: offset, to: endIndex, by: 16) {
            let lineEnd = min(i + 16, endIndex)
            let lineData = data.subdata(in: i..<lineEnd)
            
            let hex = lineData.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii = lineData.map { (32...126).contains($0) ? String(Character(UnicodeScalar($0) ?? UnicodeScalar(46)!)) : "." }.joined()
            
            print(String(format: "%08x: %-48s |%s|", i, hex, ascii))
        }
    }
    
    func analyze() throws {
        print("=== Generated SACD Structure Analysis ===\n")
        
        // Check our MASTER.TOC location (sectors 510-512)
        print("MASTER.TOC at sectors 510-512:")
        for sector in 510...512 {
            print("\nSector \(sector):")
            let data = try readSector(UInt32(sector))
            
            // Look for SACDMTOC signature
            if let range = data.range(of: "SACDMTOC".data(using: .ascii)!) {
                print("✓ Found SACDMTOC signature at offset \(range.lowerBound)")
                hexDump(data: data, length: 512)
            } else {
                print("❌ No SACDMTOC signature found")
                if !data.allSatisfy({ $0 == 0 }) {
                    print("Non-zero data present:")
                    hexDump(data: data, length: 256)
                } else {
                    print("Sector contains all zeros")
                }
            }
        }
        
        // Check Area TOC location (around sector 540)
        print("\n" + String(repeating: "=", count: 60))
        print("AREA TOC at sectors 540-560:")
        for sector in 540...560 {
            let data = try readSector(UInt32(sector))
            
            if data.range(of: "SACDSTOC".data(using: .ascii)!) != nil {
                print("\nSector \(sector): ✓ Found SACDSTOC signature")
                hexDump(data: data, length: 256)
            } else if !data.allSatisfy({ $0 == 0 }) {
                print("\nSector \(sector): Non-zero data (no SACDSTOC)")
                hexDump(data: data, length: 128)
            }
        }
        
        // Check UDF filesystem (sectors 0-20)
        print("\n" + String(repeating: "=", count: 60))
        print("UDF FILESYSTEM CHECK (sectors 0-20):")
        for sector in 0...20 {
            let data = try readSector(UInt32(sector))
            if !data.allSatisfy({ $0 == 0 }) {
                print("\nSector \(sector): Non-zero data found")
                hexDump(data: data, length: 128)
            }
        }
        
        // File size info
        let fileSize = try fileHandle.seekToEnd()
        print("\n" + String(repeating: "=", count: 60))
        print("FILE INFO:")
        print("Total file size: \(fileSize) bytes (\(fileSize / UInt64(sectorSize)) sectors)")
    }
}

// Run analysis
let isoPath = "/Volumes/cory/Desktop/SACD_R_Generated.iso"
do {
    let analyzer = try GeneratedSACDAnalyzer(url: URL(fileURLWithPath: isoPath))
    try analyzer.analyze()
} catch {
    print("Error: \(error)")
}