import SwiftUI

@MainActor private final class ElementEditorState:ObservableObject {
    @Published var filter="all"
    @Published var editing:UUID?
}
struct ElementsView:View {
    @ObservedObject var model:StudioModel
    @StateObject private var state=ElementEditorState()
    private func binding<T>(_ id:UUID,_ path:WritableKeyPath<StudioElement,T>,_ fallback:T)->Binding<T> {
        Binding(get:{model.elements.first(where:{$0.id==id})?[keyPath:path] ?? fallback},set:{value in model.editElement(id){$0[keyPath:path]=value}})
    }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Text("Overlays").font(.headline)
                Spacer()
                Menu {Button("Title card"){add("text")};Button("Lower third"){add("lower")};Button("Thanks card"){add("thanks")};Button("QR code"){add("qr")}} label:{Label("Add",systemImage:"plus")}.menuStyle(.borderlessButton).fixedSize()
            }.padding(16)
            StudioMenuField(title:"Overlay category",options:[("all","All overlays"),("text","Titles"),("lower","Lower thirds"),("thanks","Thanks"),("qr","QR codes")],selection:$state.filter).padding(.horizontal,16).padding(.bottom,12)
            Divider()
            ScrollView {
                LazyVStack(spacing:10) {
                    ForEach(model.elements.filter{state.filter=="all" || $0.kind==state.filter}) { element in
                        card(element)
                    }
                }.padding(14)
            }
            Divider()
            HStack {Text("\(model.elements.filter(\.visible).count) on output").font(.caption).foregroundStyle(.secondary);Spacer();Button("Hide all",action:model.clearElements).disabled(!model.elements.contains(where:{$0.visible}))}.padding(14)
        }
    }
    private func add(_ kind:String){model.addElement(kind);state.filter="all";state.editing=model.elements.last?.id}
    private func card(_ e:StudioElement)->some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:10) {
                Image(systemName:e.kind=="qr" ? "qrcode":"text.below.photo").foregroundStyle(Color(hex:"#F5C849"))
                VStack(alignment:.leading,spacing:3){Text(e.name).font(.system(size:13,weight:.semibold)).lineLimit(1);Text(e.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)}
                Spacer(minLength:0)
                Button {model.toggleElement(e.id)} label:{Image(systemName:e.visible ? "eye.fill":"eye").frame(width:30,height:30)}.buttonStyle(.plain).foregroundStyle(e.visible ? Color(hex:"#F5C849"):.secondary).help(e.visible ? "Hide overlay":"Show overlay")
                Button {state.editing=state.editing==e.id ? nil:e.id} label:{Image(systemName:state.editing==e.id ? "chevron.up":"slider.horizontal.3").frame(width:30,height:30)}.buttonStyle(.plain).help("Edit " + e.name)
            }
            if state.editing==e.id {
                Divider()
                field("Name",text:binding(e.id,\.name,""))
                field("Title",text:binding(e.id,\.title,""))
                field(e.kind=="qr" ? "Link or QR content":"Subtitle",text:binding(e.id,\.subtitle,""))
                if e.kind != "qr" {
                    ColorPicker("Background",selection:Binding(get:{Color(hex:e.background)},set:{color in
                        if let c=NSColor(color).usingColorSpace(.deviceRGB) {model.editElement(e.id){$0.background=String(format:"#%02X%02X%02X",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255))}}
                    }),supportsOpacity:false).font(.caption)
                }
                Stepper(value:binding(e.id,\.autoHideAfter,0),in:0...120,step:5){Text(e.autoHideAfter==0 ? "Auto-hide off":"Hide after \(Int(e.autoHideAfter)) seconds").font(.caption)}
                HStack {Button("Done"){state.editing=nil};Spacer();Button("Remove",role:.destructive){model.removeElement(e.id);state.editing=nil}.buttonStyle(.borderless)}
            }
        }.padding(13).background(Color(hex:"#24221E")).clipShape(RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(e.visible ? Color(hex:"#F5C849").opacity(0.5):Color.white.opacity(0.06)))
    }
    private func field(_ title:String,text:Binding<String>)->some View {
        VStack(alignment:.leading,spacing:5){Text(title).font(.caption).foregroundStyle(.secondary);TextField(title,text:text).textFieldStyle(StudioTextFieldStyle())}
    }
}
