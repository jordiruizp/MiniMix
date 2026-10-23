import Core
import SwiftUI

/// Vista raíz. G · T50 la sustituye por el layout completo.
public struct RootView: View {
    public init() {}
    public var body: some View {
        Text("MiniMix")
            .font(.largeTitle)
            .frame(minWidth: 960, minHeight: 600)
    }
}
