import Cocoa

/// Disposable browser smoke-test project. Never reads user media or Keychain.
@main struct ShareBrowserFixture {
    static func main() {
        let authority = SharePairingAuthority(store: ShareMemoryDeviceStore(), codeLifetime: 600, codeGenerator: { "123456" })
        let sceneID = UUID()
        var project = ShareCollaborationProject(projectID: UUID(), title: "Disposable collaboration demo",
            clips: [.init(id: UUID(), name: "Colour test card", duration: 5)],
            scenes: [.init(id: sceneID, name: "3D test scene", objects: [.init(id: UUID(), name: "Cube", kind: "cube")])])
        let host = ShareCollaborationHost(provider: { project }, applyColour: { _, value in project.clips[0].values = value; return true },
            applyTransform: { _, id, value in guard let i = project.scenes[0].objects.firstIndex(where: { $0.id == id }) else { return false }; project.scenes[0].objects[i].transform = value; return true },
            applyAddObject: { _, id, kind in project.scenes[0].objects.append(.init(id: id, name: kind.capitalized, kind: kind)); return true },
            applyDeleteObject: { _, id in project.scenes[0].objects.removeAll { $0.id == id }; return true })
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = image.bitmapData!
        for y in 0..<180 { for x in 0..<320 {
            let i = y * image.bytesPerRow + x * 3
            pixels[i] = UInt8(x * 255 / 320); pixels[i + 1] = UInt8(y * 255 / 180); pixels[i + 2] = 115
        } }
        let jpeg = image.representation(using: .jpeg, properties: [:])!
        let server = LocalShareServer(authority: authority, preferredPorts: [8897, 8898, 8899],
            collaborationSnapshot: { DispatchQueue.main.sync { host.snapshot() } },
            collaborationCommand: { command, device, name in DispatchQueue.main.sync { host.process(command, deviceID: device, deviceName: name) } },
            previewProvider: { _, _, _, done in done(jpeg) }
        ) { ShareProjectSnapshot(title: project.title, mediaCount: 0, clipCount: 1, sceneCount: 1, timelineDuration: 5, manifestData: Data("{}".utf8), manifestFilename: "test.json", media: []) }
        server.onStateChange = { state in if state.phase == .ready { FileHandle.standardOutput.write(Data("FIXTURE: \(state.primaryURL!.absoluteString) CODE: \(state.pairingCode ?? "paired")\n".utf8)) } }
        server.startWithNewCode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { server.stop(); exit(0) }
        RunLoop.main.run()
    }
}
