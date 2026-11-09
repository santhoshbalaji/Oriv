import SwiftUI

struct MobileRootView: View {
    @Bindable var controller: MobileController
    let profiles: MobileProfiles
    var body: some View {
        MobileBrowserView(controller: controller, profiles: profiles)
    }
}
