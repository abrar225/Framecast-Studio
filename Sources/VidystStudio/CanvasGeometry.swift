import Foundation

struct CanvasFrame:Equatable {
    var x:Double,y:Double,width:Double,height:Double
    init(_ source:StudioSource){x=source.x;y=source.y;width=source.width;height=source.height}
    init(x:Double,y:Double,width:Double,height:Double){self.x=x;self.y=y;self.width=width;self.height=height}
    var finite:Bool {[x,y,width,height].allSatisfy(\.isFinite)}
}
enum SourceShape:String,Codable {case rectangle,rounded,circle}
enum CanvasHandle:String,CaseIterable {
    case topLeft,top,topRight,right,bottomRight,bottom,bottomLeft,left
    var horizontal:Double {switch self {case .topLeft,.left,.bottomLeft:return -1;case .topRight,.right,.bottomRight:return 1;default:return 0}}
    var vertical:Double {switch self {case .topLeft,.top,.topRight:return -1;case .bottomLeft,.bottom,.bottomRight:return 1;default:return 0}}
}
enum CanvasGeometry {
    /// Input translation is measured in a stable, unrotated canvas coordinate space.
    static func moved(_ original:CanvasFrame,dx:Double,dy:Double,canvas:CGSize,snap:Bool)->CanvasFrame {
        guard original.finite,dx.isFinite,dy.isFinite,canvas.width>0,canvas.height>0 else{return original}
        var result=original;result.x += dx/canvas.width;result.y += dy/canvas.height
        if snap {
            func nearest(_ value:Double,_ anchors:[Double],_ threshold:Double)->Double {
                guard let anchor=anchors.min(by:{abs($0-value)<abs($1-value)}),abs(anchor-value)<=threshold else{return value};return anchor
            }
            result.x=nearest(result.x,[0,(1-result.width)/2,1-result.width],6/canvas.width)
            result.y=nearest(result.y,[0,(1-result.height)/2,1-result.height],6/canvas.height)
        }
        result.x=max(-0.95,min(0.98,result.x));result.y=max(-0.95,min(0.98,result.y))
        return result
    }
    static func resized(_ original:CanvasFrame,handle:CanvasHandle,dx:Double,dy:Double,canvas:CGSize,rotation:Double=0,aspectLocked:Bool)->CanvasFrame {
        guard original.finite,dx.isFinite,dy.isFinite,canvas.width>0,canvas.height>0 else{return original}
        let angle=rotation * .pi/180,c=cos(angle),s=sin(angle)
        let localX=dx*c+dy*s,localY = -dx*s+dy*c
        let w=original.width*canvas.width,h=original.height*canvas.height
        guard w>0,h>0 else{return original}
        var nextW=w+handle.horizontal*localX,nextH=h+handle.vertical*localY
        if aspectLocked {
            let horizontalChange=handle.horizontal==0 ? 0:(nextW-w)/w
            let verticalChange=handle.vertical==0 ? 0:(nextH-h)/h
            let change=abs(horizontalChange)>abs(verticalChange) ? horizontalChange:verticalChange
            let scale=max(max(0.02*canvas.width/w,0.02*canvas.height/h),min(min(2*canvas.width/w,2*canvas.height/h),1+change))
            nextW=w*scale;nextH=h*scale
        } else {
            nextW=max(0.02*canvas.width,min(2*canvas.width,nextW));nextH=max(0.02*canvas.height,min(2*canvas.height,nextH))
        }
        // Keep the opposite corner/edge fixed even when the source is rotated.
        let shiftX=(nextW-w)*handle.horizontal/2,shiftY=(nextH-h)*handle.vertical/2
        let centerX=(original.x+original.width/2)*canvas.width+shiftX*c-shiftY*s
        let centerY=(original.y+original.height/2)*canvas.height+shiftX*s+shiftY*c
        return CanvasFrame(x:(centerX-nextW/2)/canvas.width,y:(centerY-nextH/2)/canvas.height,width:nextW/canvas.width,height:nextH/canvas.height)
    }
    static func sized(_ source:StudioSource,fraction:Double,canvas:CGSize)->CanvasFrame {
        let original=CanvasFrame(source)
        guard canvas.width>0,canvas.height>0 else{return original}
        let w=original.width*canvas.width,h=original.height*canvas.height
        guard w>0,h>0 else{return original}
        let scale=min(canvas.width/w,canvas.height/h)*fraction
        let nw=original.width*scale,nh=original.height*scale
        return CanvasFrame(x:max(0,min(1-nw,original.x+(original.width-nw)/2)),y:max(0,min(1-nh,original.y+(original.height-nh)/2)),width:nw,height:nh)
    }
}

extension StudioSource {
    func isCircle(canvas:CGSize)->Bool {
        if let shape{return shape == .circle}
        let w=width*canvas.width,h=height*canvas.height
        return abs(w-h)<1 && cornerRadius>=min(w,h)/2-1 && cornerRadius>0
    }
    /// Normalize new edits at the owning boundary; leave unchanged imported facts alone.
    func acceptingEdit(from old:StudioSource,canvas:CGSize?=nil)->StudioSource? {
        guard [x,y,width,height,opacity,cornerRadius,rotation ?? 0,cropLeft ?? 0,cropTop ?? 0,cropRight ?? 0,cropBottom ?? 0,brightness ?? 0,contrast ?? 1,saturation ?? 1].allSatisfy(\.isFinite) else{return nil}
        var s=self
        if x != old.x{s.x=max(-0.95,min(0.98,x))};if y != old.y{s.y=max(-0.95,min(0.98,y))}
        if width != old.width{s.width=max(0.02,min(2,width))};if height != old.height{s.height=max(0.02,min(2,height))}
        if opacity != old.opacity{s.opacity=max(0,min(1,opacity))}
        if cornerRadius != old.cornerRadius{s.cornerRadius=max(0,min(4096,cornerRadius))}
        if rotation != old.rotation{s.rotation=(rotation ?? 0).truncatingRemainder(dividingBy:360)}
        if brightness != old.brightness{s.brightness=max(-1,min(1,brightness ?? 0))}
        if contrast != old.contrast{s.contrast=max(0,min(4,contrast ?? 1))}
        if saturation != old.saturation{s.saturation=max(0,min(2,saturation ?? 1))}
        if cropLeft != old.cropLeft{s.cropLeft=max(0,min(0.99-(old.cropRight ?? 0),cropLeft ?? 0))}
        if cropTop != old.cropTop{s.cropTop=max(0,min(0.99-(old.cropBottom ?? 0),cropTop ?? 0))}
        if cropRight != old.cropRight{s.cropRight=max(0,min(0.99-(s.cropLeft ?? 0),cropRight ?? 0))}
        if cropBottom != old.cropBottom{s.cropBottom=max(0,min(0.99-(s.cropTop ?? 0),cropBottom ?? 0))}
        if let canvas,canvas.width>0,canvas.height>0,
           s.shape == .circle || (s.shape==nil && old.isCircle(canvas:canvas) && s.cornerRadius==old.cornerRadius) {
            let requested:Double
            if s.width != old.width && s.height==old.height {requested=s.width*canvas.width}
            else if s.height != old.height && s.width==old.width {requested=s.height*canvas.height}
            else {requested=min(s.width*canvas.width,s.height*canvas.height)}
            let side=max(0.02*max(canvas.width,canvas.height),min(2*min(canvas.width,canvas.height),requested))
            s.width=side/canvas.width;s.height=side/canvas.height;s.shape = .circle;s.aspectLocked=true
        }
        if let canvas,canvas.width>0,canvas.height>0,s.shape != .circle,s.aspectLocked==true,old.width>0,old.height>0 {
            let onlyWidth=s.width != old.width && s.height==old.height
            let onlyHeight=s.height != old.height && s.width==old.width
            if onlyWidth || onlyHeight {
                let requested=onlyWidth ? s.width/old.width:s.height/old.height
                let scale=max(max(0.02/old.width,0.02/old.height),min(min(2/old.width,2/old.height),requested))
                s.width=old.width*scale;s.height=old.height*scale
            }
        }
        if old.locked==true {s.x=old.x;s.y=old.y;s.width=old.width;s.height=old.height;s.rotation=old.rotation}
        return s
    }
}
