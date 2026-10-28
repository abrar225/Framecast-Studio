import Foundation

/// Layout geometry belongs here. Horizontal and vertical are separate compositions.
enum StudioLayouts {
    static let names = ["Just me", "Screen + cam", "Screen + cam inverted", "Screen + tile", "Screen + tile inverted", "Side by side", "Side by side inverted", "Screen focus", "Framed"]
    static func scene(_ name:String) -> StudioScene {
        var result=StudioScene(name:name,sources:[StudioSource(name:"Screen",kind:"screen",fit:"fit"),StudioSource(name:"Camera",kind:"camera",fit:"fill")],layout:name)
        apply(name,to:&result,vertical:false)
        var portrait=result
        apply(name,to:&portrait,vertical:true)
        result.verticalSources=portrait.sources;result.verticalLayout=name;result.templateName=name
        return result
    }
    /// Upgrade only untouched v1 presets; customized layouts must remain intact.
    static func upgradedLegacy(_ scene:StudioScene)->StudioScene? {
        guard let name=scene.templateName,names.contains(name) else{return nil}
        var legacy=[StudioSource(name:"Screen",kind:"screen"),StudioSource(name:"Camera",kind:"camera")]
        legacy[0].visible=name != "Just me"
        legacy[1].visible=name != "Screen focus"
        if name != "Just me" {
            let inverted=name.contains("inverted")
            if name.contains("Side by side") {legacy[0].x=inverted ? 0.5:0;legacy[0].width=0.5;legacy[1].x=inverted ? 0:0.5;legacy[1].width=0.5}
            else if name=="Framed" {legacy[1].x=0.08;legacy[1].y=0.08;legacy[1].width=0.84;legacy[1].height=0.84;legacy[1].cornerRadius=24}
            else {legacy[1].x=inverted ? 0.04:0.74;legacy[1].y=0.67;legacy[1].width=0.22;legacy[1].height=0.28;legacy[1].cornerRadius=name.contains("tile") ? 18:500}
        }
        func matches(_ sources:[StudioSource],_ expected:[StudioSource])->Bool {
            guard sources.count==expected.count else{return false}
            return zip(sources,expected).allSatisfy {actual,expected in var compare=expected;compare.id=actual.id;return actual==compare}
        }
        let oldPreset=matches(scene.sources,legacy) && matches(scene.verticalSources ?? scene.sources,legacy)
        // An early 1.1 preview used a 1080p-sized radius. Upgrade only its exact
        // untouched geometry as well, retaining edits made in the installed app.
        var interim=Self.scene(name)
        if name=="Screen + cam" || name=="Screen + cam inverted" {
            for i in interim.sources.indices where interim.sources[i].kind=="camera" {interim.sources[i].cornerRadius=154}
        }
        let interimPreset=(name=="Screen + cam" || name=="Screen + cam inverted") && matches(scene.sources,interim.sources) && matches(scene.verticalSources ?? scene.sources,interim.verticalSources ?? [])
        guard oldPreset || interimPreset else{return nil}
        var updated=Self.scene(name)
        updated.id=scene.id;updated.name=scene.name;updated.background=scene.background
        for i in updated.sources.indices {updated.sources[i].id=scene.sources[i].id;updated.verticalSources?[i].id=(scene.verticalSources ?? scene.sources)[i].id}
        return updated
    }
    static func apply(_ name:String,to scene:inout StudioScene,vertical:Bool) {
        scene.layout=name
        let inverted=name.contains("inverted")
        for i in scene.sources.indices {
            let kind=scene.sources[i].kind
            guard kind=="screen" || kind=="camera" else {continue}
            scene.sources[i].x=0;scene.sources[i].y=0;scene.sources[i].width=1;scene.sources[i].height=1;scene.sources[i].cornerRadius=0
            scene.sources[i].fit=kind=="screen" ? "fit":"fill"
            scene.sources[i].visible=kind=="screen" ? !["Just me","Framed"].contains(name):name != "Screen focus"
            func place(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ radius:Double=0) {
                scene.sources[i].x=x;scene.sources[i].y=y;scene.sources[i].width=w;scene.sources[i].height=h;scene.sources[i].cornerRadius=radius
            }
            if name=="Just me" {continue}
            if name=="Framed" {if kind=="camera" {vertical ? place(0.035,0.15,0.93,0.7,24):place(0.025,0.045,0.95,0.91,24)};continue}
            if name=="Screen focus" {continue}
            if name.contains("Side by side") {
                if vertical {place(0.03,kind=="screen" ? (inverted ? 0.51:0.17):(inverted ? 0.17:0.51),0.94,0.30,16)}
                else if kind=="screen" {place(inverted ? 0.3:0.015,0.025,0.685,0.95,16)}
                else {place(inverted ? 0.015:0.715,0.025,0.27,0.95,16)}
            } else if name.contains("tile") {
                if vertical {
                    if kind=="screen" {place(0.03,inverted ? 0.52:0.20,0.94,0.30,12)}
                    else {place(0.15,inverted ? 0.10:0.57,0.70,0.30,18)}
                } else if kind=="camera" {place(inverted ? 0.025:0.725,0.71,0.25,0.25,18)}
            } else if vertical {
                if kind=="screen" {place(0,inverted ? 0.68359375:0,1,0.31640625)}
                else {place(0,inverted ? 0:0.31640625,1,0.68359375)}
            } else if kind=="camera" {
                // Equal physical dimensions on a 16:9 output, rather than an oval.
                place(inverted ? 0.025:0.815,0.67,0.16,0.16*16/9,500)
            }
        }
        scene.sources=scene.sources.filter{$0.kind=="screen"}+scene.sources.filter{$0.kind=="camera"}+scene.sources.filter{$0.kind != "screen" && $0.kind != "camera"}
    }
}
