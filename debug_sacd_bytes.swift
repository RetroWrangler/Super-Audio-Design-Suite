#!/usr/bin/env swift

import Foundation

class SACDByteAnalyzer {
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
    
    func analyzeBytesRaw() throws {
        print("=== Raw Byte Analysis ===")
        
        // Check sector 510 raw bytes
        let sector510 = try readSector(510)
        print("Sector 510 first 16 bytes:")
        let first16 = Array(sector510.prefix(16))
        for (i, byte) in first16.enumerated() {
            print("Byte \(i): 0x\(String(format: "%02x", byte)) (\(byte)) '\(Character(UnicodeScalar(byte) ?? UnicodeScalar(46)!))'")
        }
        
        // Check what the repeating pattern actually is
        let allSame = sector510.allSatisfy { $0 == sector510[0] }
        print("All bytes identical: \(allSame)")
        if allSame {
            let repeatingByte = sector510[0]
            print("Repeating byte: 0x\(String(format: "%02x", repeatingByte)) (\(repeatingByte))")
            
            // This might be a specific fill pattern
            if repeatingByte == 0x00 {
                print("Pattern is all zeros")
            } else if repeatingByte == 0xFF {
                print("Pattern is all 0xFF")
            } else {
                print("Pattern is unknown byte value: \(repeatingByte)")
            }
        }
        
        // Check if it's the DSD audio data bleeding through
        print("\nChecking for audio data patterns...")
        let uniqueBytes = Set(sector510)
        print("Unique byte values in sector: \(uniqueBytes.sorted().map { String(format: "0x%02x", $0) })")
        
        if uniqueBytes.count <= 3 {
            print("Very low diversity - likely not proper MASTER.TOC data")
        } else {
            print("Good diversity - might be valid data")
        }
    }
}

let isoPath = "/Users/cory/Desktop/SACD_R.iso"
do {
    let analyzer = try SACDByteAnalyzer(url: URL(fileURLWithPath: isoPath))
    try analyzer.analyzeBytesRaw()
} catch {
    print("Error: \(error)")
}