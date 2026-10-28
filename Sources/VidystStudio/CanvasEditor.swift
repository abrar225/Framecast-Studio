import SwiftUI
import AppKit

struct CanvasEditor:View {
    @ObservedObject var model:StudioModel
    @ObservedObject private var interaction:CanvasInteraction
    let vertical:Bool
    let size:CGSize
    let screenActive:Bool
    let cameraActive:Bool
    init(model:StudioModel,vertical:Bool,size:CGSize,screenActive:Bool,cameraActive:Bool) {
        self.model=model;self.interaction=model.canvasInteraction;self.vertical=vertical;self.size=size;self.screenActive=screenActive;self.cameraActive=cameraActive
    }
    var body:some View {
        ZStack(alignment:.topLeading) {
            ForEach(model.sources(onVerticalCanvas:vertical).filter{$0.visible}) { saved in
                let source=interaction.source(saved,vertical:vertical)
                SourceFrameControl(model:model,interaction:interaction,source:source,vertical:vertical,size:size,inputUnavailable:(source.kind=="screen" && !screenActive) || (source.kind=="camera" && !cameraActive))
            }
        }.frame(width:size.width,height:size.height,alignment:.topLeading)
            .coordinateSpace(name:coordinateName).clipped().focusable().focusEffectDisabled()
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.willResignActiveNotification)){_ in if interaction.session?.vertical==vertical {interaction.cancel()}}
            .onKeyPress(.escape) {guard interaction.session != nil else{return .ignored};interaction.cancel();return .handled}
            .onMoveCommand {direction in
                guard model.vertical==vertical,model.selectedSourceID != nil else{return}
                let step=NSEvent.modifierFlags.contains(.shift) ? 10.0:1.0
                switch direction {case .left:model.nudgeSelectedSource(dx:-step,dy:0);case .right:model.nudgeSelectedSource(dx:step,dy:0);case .up:model.nudgeSelectedSource(dx:0,dy:-step);case .down:model.nudgeSelectedSource(dx:0,dy:step);default:break}
            }.accessibilityLabel(vertical ? "Vertical canvas editor":"Horizontal canvas editor")
    }
    private var coordinateName:String {vertical ? "framecast.canvas.vertical":"framecast.canvas.horizontal"}
}
private struct SourceFrameControl:View {
    @ObservedObject var model:StudioModel
    let interaction:CanvasInteraction
    let source:StudioSource
    let vertical:Bool
    let size:CGSize
    let inputUnavailable:Bool
    private var selected:Bool {model.vertical==vertical && model.selectedSourceID==source.id && model.panel=="Edit"}
    private var coordinateName:String {vertical ? "framecast.canvas.vertical":"framecast.canvas.horizontal"}
    private var locked:Bool {source.locked==true}
    var body:some View {
        let width=max(2,source.width*size.width),height=max(2,source.height*size.height)
        ZStack(alignment:.topLeading) {
            if inputUnavailable {
                let outputWidth=model.canvasSize(vertical:vertical).width
                let radius=source.isCircle(canvas:model.canvasSize(vertical:vertical)) ? min(width,height)/2:min(source.cornerRadius*size.width/outputWidth,min(width,height)/2)
                RoundedRectangle(cornerRadius:radius).fill(Color(hex:source.kind=="camera" ? "#292822":"#202126"))
                    .overlay {
                        VStack(spacing:8) {
                            Image(systemName:source.kind=="camera" ? "video.slash":"display").font(.system(size:min(25,max(12,height/6)),weight:.light))
                            if width>115 && height>65 {Text(source.kind=="camera" ? "Camera is off":"Share your screen to preview").font(.system(size:11,weight:.medium))}
                        }.foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onTapGesture {model.selectSource(source.id,onVerticalCanvas:vertical)}
                .gesture(DragGesture(minimumDistance:2,coordinateSpace:.named(coordinateName)).onChanged {move($0.translation)}.onEnded {value in move(value.translation);interaction.commit()})
            if selected {
                Rectangle().stroke(Color(hex:"#F5C849"),style:StrokeStyle(lineWidth:1.5,dash:locked ? [4,3]:[])).allowsHitTesting(false)
                Label(source.name,systemImage:locked ? "lock.fill":"move.3d")
                    .font(.system(size:10,weight:.semibold)).lineLimit(1).padding(4).foregroundStyle(.black).background(Color(hex:"#F5C849")).allowsHitTesting(false)
                if !locked {
                    ForEach(CanvasHandle.allCases.filter{width>80 && height>80 || ($0.horizontal != 0 && $0.vertical != 0)},id:\.self) {handle in
                        RoundedRectangle(cornerRadius:2).fill(Color(hex:"#F5C849")).frame(width:8,height:8)
                            .frame(width:24,height:24).contentShape(Rectangle())
                            .position(x:(handle.horizontal+1)*width/2,y:(handle.vertical+1)*height/2)
                            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named(coordinateName)).onChanged {resize(handle,$0.translation)}.onEnded {value in resize(handle,value.translation);interaction.commit()})
                            .accessibilityLabel("Resize \(source.name), \(handle.rawValue)")
                    }
                }
            }
        }.frame(width:width,height:height).rotationEffect(.degrees(source.rotation ?? 0))
            .offset(x:source.x*size.width,y:source.y*size.height)
            .contextMenu {
                Button("Center frame"){select();model.centerSelectedSource()}.disabled(locked)
                Button("Fit frame in canvas"){select();model.sizeSelectedSource(1)}.disabled(locked)
                Menu("Frame size") {
                    Button("Small"){select();model.sizeSelectedSource(0.25)}
                    Button("Medium"){select();model.sizeSelectedSource(0.4)}
                    Button("Large"){select();model.sizeSelectedSource(0.6)}
                }.disabled(locked)
                Divider()
                Button(locked ? "Unlock position":"Lock position"){select();model.editSource{$0.locked = !locked};model.save()}
            }
            .accessibilityElement(children:.contain).accessibilityLabel("Edit " + source.name)
            .onDisappear {if interaction.session?.original.id==source.id && interaction.session?.vertical==vertical {interaction.cancel()}}
    }
    private func select(){model.selectSource(source.id,onVerticalCanvas:vertical)}
    private func move(_ translation:CGSize) {
        guard !locked,interaction.begin(sourceID:source.id,vertical:vertical,action:"Move source"),let session=interaction.session else{return}
        interaction.update(CanvasGeometry.moved(CanvasFrame(session.original),dx:translation.width,dy:translation.height,canvas:size,snap:!NSEvent.modifierFlags.contains(.option)))
    }
    private func resize(_ handle:CanvasHandle,_ translation:CGSize) {
        guard !locked,interaction.begin(sourceID:source.id,vertical:vertical,action:"Resize source"),let session=interaction.session else{return}
        let preserve=session.original.aspectLocked==true || session.original.isCircle(canvas:model.canvasSize(vertical:vertical))
        interaction.update(CanvasGeometry.resized(CanvasFrame(session.original),handle:handle,dx:translation.width,dy:translation.height,canvas:size,rotation:session.original.rotation ?? 0,aspectLocked:preserve))
    }
}

struct SourceFrameTools:View {
    @ObservedObject var model:StudioModel
    var body:some View {
        if let source=model.source {
            VStack(alignment:.leading,spacing:9) {
                HStack {
                    Text("Frame").font(.system(size:11,weight:.semibold))
                    Spacer()
                    Button {model.editSource{$0.locked = !(source.locked ?? false)};model.save()} label:{Label(source.locked==true ? "Unlock":"Lock",systemImage:source.locked==true ? "lock.fill":"lock.open")}.buttonStyle(.borderless).help("Lock or unlock frame position and size")
                }
                HStack(spacing:5) {
                    size("Small",0.25);size("Medium",0.4);size("Large",0.6);size("Fit",1)
                }.disabled(source.locked==true)
                HStack {
                    Button("Center",action:model.centerSelectedSource).disabled(source.locked==true)
                    Spacer()
                    Toggle("Keep aspect",isOn:Binding(get:{source.aspectLocked==true || source.isCircle(canvas:model.canvasSize(vertical:model.vertical))},set:{value in model.editSource{$0.aspectLocked=value};model.save()}))
                        .toggleStyle(.checkbox).disabled(source.isCircle(canvas:model.canvasSize(vertical:model.vertical)))
                }
                Text(source.locked==true ? "Unlock to move or resize this frame.":"Drag to move. Use the edge handles to resize. Hold Option to bypass snapping; Escape cancels.").font(.system(size:10)).foregroundStyle(.secondary)
            }.font(.system(size:11)).padding(11).background(Color(hex:"#24221E")).clipShape(RoundedRectangle(cornerRadius:8))
        }
    }
    private func size(_ title:String,_ fraction:Double)->some View {
        Button(title){model.sizeSelectedSource(fraction)}.buttonStyle(StudioButtonStyle(horizontalPadding: 5)).controlSize(.small).frame(maxWidth:.infinity).accessibilityLabel("Set frame size " + title)
    }
}
