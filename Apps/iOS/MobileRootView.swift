import SwiftUI

struct MobileRootView: View {
    @Bindable var controller: MobileController
    let profiles: MobileProfiles
    var body: some View {
        #if ORIV_DEVICE_QA
        // App-only test override; never changes the owner's system setting.
        MobileBrowserView(controller: controller, profiles: profiles,
            reduceMotionOverride: ProcessInfo.processInfo.environment["ORIV_QA_REDUCE_MOTION"] == "1" ? true : nil)
        #else
        MobileBrowserView(controller: controller, profiles: profiles)
        #endif
    }
}
