import Foundation

struct CaptureDeviceOption: Identifiable, Equatable {
    let id: String
    let name: String
}

struct RenderLayer: Identifiable,Equatable {
    var id = UUID()
    var kind: String = "camera"
    var text: String = ""
    var path: String = ""
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    var opacity: Double = 1
    var visible: Bool = true
    var mirrored: Bool = false
    var cornerRadius: Double = 0
    var rotation: Double = 0
    var cropLeft: Double = 0
    var cropTop: Double = 0
    var cropRight: Double = 0
    var cropBottom: Double = 0
    var fit: String = "fill"
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var shape:String?
}

struct RenderConfiguration:Equatable {
    var backgroundHex: String = "11131D"
    var title: String = ""
    var layers: [RenderLayer] = []
    var width: Int = 1280
    var height: Int = 720
    var vertical:Bool?
}

