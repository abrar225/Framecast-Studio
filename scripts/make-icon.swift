import AppKit
let output=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let image=NSImage(size:NSSize(width:pixels,height:pixels))
        image.lockFocus()
        let s=CGFloat(pixels)/1024
        let t=NSAffineTransform();t.scale(by:s);t.concat()
        NSColor(calibratedRed:0.09,green:0.085,blue:0.075,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:24,y:24,width:976,height:976),xRadius:220,yRadius:220).fill()
        let gold=NSColor(calibratedRed:0.96,green:0.78,blue:0.29,alpha:1)
        gold.setStroke()
        let frame=NSBezierPath(roundedRect:NSRect(x:188,y:253,width:648,height:518),xRadius:76,yRadius:76);frame.lineWidth=56;frame.stroke()
        gold.setFill()
        let play=NSBezierPath();play.move(to:NSPoint(x:442,y:367));play.line(to:NSPoint(x:442,y:657));play.line(to:NSPoint(x:663,y:512));play.close();play.fill()
        NSColor(calibratedRed:0.94,green:0.30,blue:0.29,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:738,y:693,width:125,height:125)).fill()
        image.unlockFocus()
        let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
        let suffix=scale==2 ? "@2x":""
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output+"/icon_\(size)x\(size)\(suffix).png"))
    }
}
