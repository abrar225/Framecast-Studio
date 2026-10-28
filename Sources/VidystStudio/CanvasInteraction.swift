import Foundation
import Combine

/// A gesture owns a draft. The persisted document changes once, when it commits.
@MainActor final class CanvasInteraction:ObservableObject {
    struct Session {
        let sceneID:UUID
        let vertical:Bool
        let original:StudioSource
        let action:String
        var source:StudioSource
    }
    @Published private(set) var session:Session?
    private weak var model:StudioModel?
    init(model:StudioModel){self.model=model}
    func begin(sourceID:UUID,vertical:Bool,action:String)->Bool {
        guard let model else{return false}
        if let session {
            if session.original.id==sourceID && session.vertical==vertical{return true}
            cancel()
        }
        guard let source=model.sources(onVerticalCanvas:vertical).first(where:{$0.id==sourceID}),source.locked != true else{return false}
        model.selectSource(sourceID,onVerticalCanvas:vertical)
        session=Session(sceneID:model.scene.id,vertical:vertical,original:source,action:action,source:source)
        return true
    }
    func update(_ frame:CanvasFrame) {
        guard var next=session,frame.finite else{return}
        var source=next.original;source.x=frame.x;source.y=frame.y;source.width=frame.width;source.height=frame.height
        if next.original.isCircle(canvas:model?.canvasSize(vertical:next.vertical) ?? .zero) {source.shape = .circle;source.aspectLocked=true}
        guard let accepted=source.acceptingEdit(from:next.original,canvas:model?.canvasSize(vertical:next.vertical)),accepted != next.source else{return}
        next.source=accepted;session=next
        model?.previewSourceTransform(accepted,sceneID:next.sceneID,vertical:next.vertical)
    }
    func commit() {
        guard let current=session else{return}
        session=nil
        model?.commitSourceInteraction(current)
    }
    func cancel() {
        guard let current=session else{return}
        session=nil
        model?.previewSourceTransform(current.original,sceneID:current.sceneID,vertical:current.vertical)
    }
    func source(_ original:StudioSource,vertical:Bool)->StudioSource {
        guard let session,session.original.id==original.id,session.vertical==vertical else{return original}
        return session.source
    }
}
