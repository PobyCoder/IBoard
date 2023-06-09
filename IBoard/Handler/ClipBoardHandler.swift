//
//  ClipBoardHandler.swift
//  ClipBoardManager
//
//  Created by Lennard on 19.08.22.
//  Copyright © 2022 Lennard Kittner. All rights reserved.
//

import Cocoa
import Combine

class ClipBoardHandler :ObservableObject {
    private let historyPath = URL(fileURLWithPath: "\(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)/i-board/history.json")
    private let clipBoard = NSPasteboard.general
    private let configHandler :ConfigHandler
    private var excludedTypes = ["com.apple.finder.noderef"]
    private var extraTypes = [NSPasteboard.PasteboardType("com.apple.icns"), NSPasteboard.PasteboardType("org.nspasteboard.source")]
    private var oldChangeCount :Int!
    private var accessLock :NSLock
    @Published var history :[ClipBoardData]!
    private var timer :Timer!
    private var configSink :Cancellable!
    var historyCapacity :Int
    var firstLaunch: Bool = false
    
    init(configHandler: ConfigHandler) {
        self.configHandler = configHandler
        historyCapacity = configHandler.conf.shortcut
        oldChangeCount = clipBoard.changeCount
        history = []
        accessLock = NSLock()
        if let historyJson = try? String(contentsOfFile: historyPath.path) {
                loadHistoryFromJSON(JSON: historyJson)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            let JSON = self.getHistoryAsJSON()
            try? JSON.write(toFile: self.historyPath.path, atomically: true, encoding: String.Encoding.utf8)
        }
        configSink = configHandler.$conf.sink(receiveValue: { newConf in
            self.historyCapacity = newConf.shortcut
            if self.history.count > self.historyCapacity {
                self.history.removeLast(self.history.count - self.historyCapacity)
            }
            
            if self.timer?.timeInterval ?? -1 != TimeInterval(newConf.refreshIntervall) && newConf.refreshIntervall > 0 {
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(timeInterval: TimeInterval(newConf.refreshIntervall), target: self, selector: #selector(self.refreshClipBoard(_:)), userInfo: nil, repeats: true)
            }
        })
    }
        
    @objc func refreshClipBoard(_ sender: Any?) {
        read()
    }
    
    func read() -> ClipBoardData {
        accessLock.lock()
        if !updateChangeCount() {
            accessLock.unlock()
            return history.first ?? ClipBoardData(string: "", isFile: false, content: [:])
        }
        var content :[NSPasteboard.PasteboardType : Data] = [:]
        var types = clipBoard.types
        types?.append(contentsOf: extraTypes)
        for t in types ?? [] {
            if !excludedTypes.contains(t.rawValue) {
                if let data = clipBoard.data(forType: t) {
                    content[t] = data
                }
            }
        }
        if content[NSPasteboard.PasteboardType("org.nspasteboard.source")] == nil {
            content[NSPasteboard.PasteboardType("org.nspasteboard.source")] = Data(NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.utf8 ?? "".utf8)
        }
        let isFile = content[NSPasteboard.PasteboardType.fileURL] != nil || content[NSPasteboard.PasteboardType.tiff] != nil
        let string = clipBoard.string(forType: NSPasteboard.PasteboardType.string)
        if content[NSPasteboard.PasteboardType.fileURL] != nil && content[NSPasteboard.PasteboardType("com.apple.icns")] == nil {
            var i = 0
            // wait for the icon to be available but atmost 1s
            while clipBoard.data(forType: NSPasteboard.PasteboardType("com.apple.icns")) == nil && i < 200 && !haasChanged() {
                usleep(5000) // wait 0.005s
                i += 1
            }
        }
        content[NSPasteboard.PasteboardType("com.apple.icns")] = clipBoard.data(forType: NSPasteboard.PasteboardType("com.apple.icns"))
        // is compression necessary?
        if content[NSPasteboard.PasteboardType("com.apple.icns")] != nil {
            let image = NSBitmapImageRep(data: NSImage(data: content[NSPasteboard.PasteboardType("com.apple.icns")] ?? Data())?.resizeImage(tamanho: NSSize(width: 15, height: 15)).tiffRepresentation ?? Data())?.representation(using: .png, properties: [:])
            content[NSPasteboard.PasteboardType("com.apple.icns")] = image
        }
        history.insert(ClipBoardData(string: string ?? "No Preview Found", isFile: isFile, content: content), at: 0)
        writeHistory()
        if history.count > historyCapacity {
            history.removeLast(history.count - historyCapacity)
        }
        accessLock.unlock()
        return history.first!
    }
    
    func write(entry: ClipBoardData) {
        accessLock.lock()
        clipBoard.clearContents()
        for (t, d) in entry.content {
            clipBoard.setData(d, forType: t)
        }
        oldChangeCount = clipBoard.changeCount
        accessLock.unlock()
    }
    
    func write(historyIndex: Int) {
        write(entry: history[historyIndex])
    }
        
    func clear() {
        history.removeAll()
        history = []
        writeHistory()
    }
    
    func haasChanged() -> Bool {
        return oldChangeCount != clipBoard.changeCount
    }
    
    func updateChangeCount() -> Bool {
        if haasChanged() {
            oldChangeCount = clipBoard.changeCount
            return true
        }
        return false
    }
    
    func getHistoryAsJSON() -> String {
        let hs = history.map({(e) in e.toMap()})
        if let jsonData = try? JSONSerialization.data(withJSONObject: hs, options: .prettyPrinted) {
            return String(data: jsonData, encoding: String.Encoding.utf8) ?? ""
        }
        return ""
    }

    func loadHistoryFromJSON(JSON: String) {
        let data = JSON.data(using: .utf8)!
        let decoded = try? JSONSerialization.jsonObject(with: data, options: [])
        if let arr = decoded as? [[String : String]] {
            for dict in arr {
                self.history.append(ClipBoardData(from: dict))
            }
        }
    }
    
    func writeHistory() {
        let data = getHistoryAsJSON().data(using: .utf8)!
        try? data.write(to: historyPath)
    }
}
