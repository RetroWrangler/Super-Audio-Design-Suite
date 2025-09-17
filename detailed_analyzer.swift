#!/usr/bin/env swift

import Foundation

class DetailedSACDAnalyzer {
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
        print("=== Detailed SACD Analysis ===\n")
        
        // Examine sector 275 (where MASTER.TOC and 2CH were found)
        print("SECTOR 275 (MASTER.TOC/2CH location):")
        let sector275 = try readSector(275)
        hexDump(data: sector275, length: 512)
        
        print("\n" + String(repeating: "=", count: 60) + "\n")
        
        // Check around sector 275 for directory structure
        print("SECTORS AROUND 275:")
        for s in 273...279 {
            print("\nSector \(s):")
            let data = try readSector(UInt32(s))
            if let ascii = String(data: data.prefix(128), encoding: .ascii) {
                let readable = ascii.replacingOccurrences(of: "\0", with: "·")
                print("ASCII: \(readable)")
            }
            
            // Look for file patterns
            if data.range(of: "TRACK".data(using: .ascii)!) != nil ||
               data.range(of: "MASTER.TOC".data(using: .ascii)!) != nil ||
               data.range(of: "2CH".data(using: .ascii)!) != nil {
                print("HEX DUMP:")
                hexDump(data: data, length: 256)
            }
        }
        
        // Check UDF root directory (typically around sector 20-30)
        print("\n" + String(repeating: "=", count: 60) + "\n")
        print("UDF ROOT DIRECTORY CHECK:")
        for s in 20...25 {
            print("\nSector \(s):")
            let data = try readSector(UInt32(s))
            hexDump(data: data, length: 256)
        }
    }
}

// Run analysis
let isoPath = "/Users/cory/Desktop/SACD_R.iso"
do {
    let analyzer = try DetailedSACDAnalyzer(url: URL(fileURLWithPath: isoPath))
    try analyzer.analyze()
} catch {
    print("Error: \(error)")
}