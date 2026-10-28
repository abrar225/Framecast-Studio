// Framecast build compatibility for the MIT CompactSlider 2.1.0 sources.
// Select the property wrapper explicitly when the SDK also exports a State macro.
import SwiftUI
typealias CompactSliderState<Value> = SwiftUI.State<Value>
