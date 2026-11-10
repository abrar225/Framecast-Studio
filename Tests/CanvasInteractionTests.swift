import Testing
import Foundation
import Combine
@testable import VidystStudio

@MainActor @Suite struct CanvasInteractionTests {
    private struct Failure: LocalizedError { let errorDescription: String? }
    private func require(_ ok: @autoclosure () -> Bool, _ message: String) throws { if !ok() { throw Failure(errorDescription: message) } }
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00001 }

    @Test func geometryDraftingUndoAndDocumentSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canvas = CGSize(width: 1000, height: 500), frame = CanvasFrame(x: 0.2, y: 0.2, width: 0.2, height: 0.4)
        let moved = CanvasGeometry.moved(frame, dx: 100, dy: 50, canvas: canvas, snap: false)
        try require(near(moved.x, 0.3) && near(moved.y, 0.3), "Stable-canvas move drifted")
        try require(CanvasGeometry.moved(frame, dx: 100, dy: 50, canvas: canvas, snap: false) == moved, "Move accumulated prior deltas")
        let snapped = CanvasGeometry.moved(frame, dx: -197, dy: -98, canvas: canvas, snap: true)
        try require(snapped.x == 0 && snapped.y == 0, "Canvas edge snapping failed")
        let circle = CanvasGeometry.resized(frame, handle: .bottomRight, dx: 50, dy: 0, canvas: canvas, aspectLocked: true)
        try require(near(circle.width * canvas.width, circle.height * canvas.height) && near(circle.x, frame.x) && near(circle.y, frame.y), "Circle resizing lost aspect/opposite anchor")
        let topLeft = CanvasGeometry.resized(frame, handle: .topLeft, dx: -50, dy: -30, canvas: canvas, aspectLocked: false)
        try require(near(topLeft.x + topLeft.width, frame.x + frame.width) && near(topLeft.y + topLeft.height, frame.y + frame.height), "Top-left resize moved opposite corner")
        func point(_ rect: CanvasFrame, x: Double, y: Double, rotation: Double) -> CGPoint {
            let angle = rotation * Double.pi / 180, c = cos(angle), s = sin(angle)
            let px = rect.width * canvas.width * x / 2, py = rect.height * canvas.height * y / 2
            return CGPoint(x: (rect.x + rect.width / 2) * canvas.width + px * c - py * s, y: (rect.y + rect.height / 2) * canvas.height + px * s + py * c)
        }
        for handle in CanvasHandle.allCases {
            let resized = CanvasGeometry.resized(frame, handle: handle, dx: 37, dy: -19, canvas: canvas, rotation: 32, aspectLocked: false)
            let before = point(frame, x: -handle.horizontal, y: -handle.vertical, rotation: 32)
            let after = point(resized, x: -handle.horizontal, y: -handle.vertical, rotation: 32)
            try require(near(before.x, after.x) && near(before.y, after.y), "Rotated \(handle) resize moved its opposite anchor")
        }
        let extreme = CanvasGeometry.resized(frame, handle: .bottomRight, dx: -1e8, dy: -1e8, canvas: canvas, aspectLocked: true)
        try require(extreme.width >= 0.02 && extreme.height >= 0.02, "Resize crossed minimum size")
        print("PASS stable coordinates, snapping, eight rotated edge/corner anchors, circle aspect and minimum size")

        let model = StudioModel(projectURL: root.appendingPathComponent("studio.json")); defer { model.shutdown() }
        model.project.microphoneMuted = true; model.engine.microphoneEnabled = false; model.canvasMode = "both"
        model.selectTemplate("Screen + cam")
        let id = model.scene.sources.first { $0.kind == "camera" }!.id
        model.selectSource(id, onVerticalCanvas: false)
        model.editSource { $0.kind = "color"; $0.text = "FF0000" }
        model.editUndoManager.removeAllActions(); model.save()
        let original = model.source!, opposite = model.scene.verticalSources
        let beforeDocument = try Data(contentsOf: model.projectURL)
        var notifications = 0
        let subscription = model.objectWillChange.sink { notifications += 1 }
        try require(model.canvasInteraction.begin(sourceID: id, vertical: false, action: "Move source"), "Gesture did not begin")
        for i in 0..<240 {
            model.canvasInteraction.update(CanvasGeometry.moved(CanvasFrame(original), dx: -Double(i) / 2, dy: -Double(i) / 4, canvas: model.canvasSize(vertical: false), snap: false))
        }
        try require(notifications == 0, "Transient updates republished the global model: \(notifications)")
        try require(model.source == original, "Draft leaked into the persisted model")
        model.save(); let duringDocument = try Data(contentsOf: model.projectURL)
        try require(beforeDocument == duringDocument, "Autosave persisted a draft")
        model.canvasInteraction.commit()
        let committed = model.source!
        try require(committed.x != original.x && notifications <= 3, "Commit did not batch document publications")
        try require(model.scene.verticalSources == opposite, "Drag changed the opposite canvas")
        try require(model.editUndoManager.canUndo, "Gesture has no undo")
        model.editUndoManager.undo(); try require(model.source == original, "Undo did not restore the whole gesture")
        model.editUndoManager.redo(); try require(model.source == committed, "Redo did not restore the gesture")
        try require(model.canvasInteraction.begin(sourceID: id, vertical: false, action: "Move source"), "Cancel test did not begin")
        model.canvasInteraction.update(CanvasFrame(x: 0, y: 0, width: 0.4, height: 0.7)); model.canvasInteraction.cancel()
        try require(model.source == committed && model.canvasInteraction.session == nil, "Cancel mutated document")
        withExtendedLifetime(subscription) {}
        print("PASS 240 draft updates publish zero global model events; one committed gesture, undo/redo/cancel, no draft autosave, opposite-canvas isolation")

        model.editSource { $0.brightness = 9; $0.contrast = -3; $0.saturation = 10; $0.opacity = 3; $0.cropLeft = 1.5; $0.cropRight = 0.5 }
        try require(model.source?.brightness == 1 && model.source?.contrast == 0 && model.source?.saturation == 2 && model.source?.opacity == 1, "Inspector values escaped owner bounds")
        try require((model.source?.cropLeft ?? 0) + (model.source?.cropRight ?? 0) < 1, "Crop consumed the whole source")
        let valid = model.source!
        model.editSource { $0.x = .nan }; try require(model.source == valid, "Nonfinite edit changed source")
        model.editSource { $0.locked = true }
        let locked = model.source!
        try require(!model.canvasInteraction.begin(sourceID: id, vertical: false, action: "Move source"), "Locked frame accepted a drag")
        model.nudgeSelectedSource(dx: 100, dy: 100); try require(model.source == locked, "Locked frame moved")
        model.editSource { $0.name = "Renamed locked frame" }; try require(model.source?.name == "Renamed locked frame", "Position lock prevented naming")
        model.editSource { $0.locked = false }
        model.setSourceShape("Circle")
        let oldHeight = model.source!.height
        model.editSource { $0.width *= 1.2 }
        let sized = model.source!
        try require(sized.height > oldHeight && near(sized.width * Double(model.outputWidth), sized.height * Double(model.outputHeight)), "Numeric resize distorted a circle")
        model.setSourceShape("Rounded"); model.editSource { $0.aspectLocked = true }
        let aspect = model.source!.width / model.source!.height
        model.editSource { $0.width *= 0.8 }
        try require(near(model.source!.width / model.source!.height, aspect), "Numeric aspect lock distorted rectangle")
        model.setSourceShape("Circle")
        model.sizeSelectedSource(1)
        try require(model.source!.width <= 1 && model.source!.height <= 1 && model.source!.x >= 0 && model.source!.y >= 0, "Fit frame escaped canvas")
        model.save()
        _ = try ProjectDocument.decode(Data(contentsOf: model.projectURL))
        print("PASS inspector bounds/crop/nonfinite rejection, position lock, numeric circle aspect, fit sizing and valid persisted document")

        model.editUndoManager.removeAllActions()
        let beforeRemoval = model.selectedSources
        model.duplicateSource(); let afterDuplicate = model.selectedSources
        try require(afterDuplicate.count == beforeRemoval.count + 1, "Duplicate failed")
        model.editUndoManager.undo(); try require(model.selectedSources == beforeRemoval, "Undo duplicate failed")
        model.editUndoManager.redo(); try require(model.selectedSources == afterDuplicate, "Redo duplicate failed")
        model.selectedSourceID = afterDuplicate.last!.id; model.removeSource()
        model.editUndoManager.undo(); try require(model.selectedSources == afterDuplicate, "Undo deletion lost source identity")
        model.selectedSourceID = afterDuplicate.last!.id; model.moveSource(-1)
        model.editUndoManager.undo(); try require(model.selectedSources == afterDuplicate, "Undo layer order failed")
        model.selectedSourceID = id
        let beforeLayout = model.scene
        model.editUndoManager.removeAllActions(); model.applyLayout("Side by side")
        let afterLayout = model.scene
        model.editUndoManager.undo()
        try require(model.scene.sources == beforeLayout.sources && model.scene.verticalSources == beforeLayout.verticalSources, "Linked layout undo did not restore both canvases in one step")
        try require(!model.editUndoManager.canUndo, "Linked layout consumed more than one undo step")
        model.editUndoManager.redo(); try require(model.scene == afterLayout, "Linked layout redo failed")
        model.resetSelectedLayout(); model.editUndoManager.undo()
        try require(model.scene == afterLayout, "Layout reset could not be undone")
        model.selectSource(id, onVerticalCanvas: false); model.setSourceShape("Circle")
        print("PASS source duplicate/delete/reorder and linked layout/reset undo retain identity and independent canvas arrays")

        // Explicit circle intent remains a circle after output resolution changes.
        model.project.width = 3840; model.project.height = 2160; model.refreshComposition()
        try require(model.source!.shape == .circle, "Circle intent was lost on output change")
        let other = StudioScene(name: "Other", sources: []); model.project.scenes.append(other)
        try require(model.canvasInteraction.begin(sourceID: id, vertical: false, action: "Move source"), "Scene switch test did not begin")
        model.canvasInteraction.update(CanvasFrame(x: 0.1, y: 0.1, width: 0.2, height: 0.3))
        model.selectScene(other.id)
        try require(model.canvasInteraction.session == nil, "Scene switch retained a stale gesture")
        print("PASS circle intent survives resolution changes; scene switch cancels transient state")
        let horizontalBefore = model.canvasOutput(vertical: false)
        let editingBefore = model.vertical
        model.setCanvasResolution(width: 2160, height: 3840, vertical: true)
        model.setCanvasFrameRate(50, vertical: true)
        let verticalAfter = model.canvasOutput(vertical: true)
        let horizontalAfter = model.canvasOutput(vertical: false)
        try require(verticalAfter.width == 2160 && verticalAfter.height == 3840 && verticalAfter.fps == 50,
                    "Vertical settings did not update their canvas")
        try require(horizontalAfter.width == horizontalBefore.width && horizontalAfter.height == horizontalBefore.height && horizontalAfter.fps == horizontalBefore.fps,
                    "Editing vertical settings changed horizontal output")
        try require(model.vertical == editingBefore, "Editing the other canvas switched the active editor")
        model.setCanvasResolution(width: 1920, height: 1080, vertical: false)
        model.setCanvasFrameRate(30, vertical: false)
        try require(model.canvasOutput(vertical: true).width == 2160 && model.canvasOutput(vertical: true).height == 3840 && model.canvasOutput(vertical: true).fps == 50,
                    "Editing horizontal settings changed vertical output")
        model.save()
        let settingsRestored = try ProjectDocument.decode(Data(contentsOf: model.projectURL))
        try require(settingsRestored.verticalWidth == 2160 && settingsRestored.verticalHeight == 3840 && settingsRestored.verticalFPS == 50 && settingsRestored.width == 1920 && settingsRestored.height == 1080 && settingsRestored.fps == 30,
                    "Independent canvas settings were not persisted")
        print("PASS independent horizontal and vertical resolution/FPS setters preserve editor selection and persisted outputs")
        var preferences = MediaPreferences(); preferences.vertical.codec = .hevc; preferences.vertical.container = .mov
        preferences.horizontal.quality = .custom; preferences.horizontal.bitrateMbps = 32
        model.project.mediaPreferences = preferences; model.project.verticalFPS = 24; model.save()
        let restored = try ProjectDocument.decode(Data(contentsOf: model.projectURL))
        try require(restored.mediaPreferences == preferences && restored.verticalFPS == 24, "Independent media settings did not persist")
        var invalid = restored; invalid.mediaPreferences?.horizontal.bitrateMbps = 0
        do { _ = try ProjectDocument.decode(JSONEncoder().encode(invalid)); throw Failure(errorDescription: "Invalid bitrate was accepted") }
        catch is Failure { throw Failure(errorDescription: "Invalid bitrate was accepted") } catch {}
        invalid = restored; invalid.verticalFPS = 61
        do { _ = try ProjectDocument.decode(JSONEncoder().encode(invalid)); throw Failure(errorDescription: "Invalid per-canvas FPS was accepted") }
        catch is Failure { throw Failure(errorDescription: "Invalid per-canvas FPS was accepted") } catch {}
        var legacy = restored; legacy.mediaPreferences = nil; legacy.verticalFPS = nil
        let legacyRestored = try ProjectDocument.decode(JSONEncoder().encode(legacy))
        try require(legacyRestored.mediaPreferences == nil && legacyRestored.verticalFPS == nil, "Old project fields did not load")
        print("PASS independent codec/container/bitrate/FPS persistence; legacy projects and invalid settings boundaries")
    }
}
