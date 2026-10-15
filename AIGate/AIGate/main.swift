//
//  main.swift
//  AIGate
//
//  Created by 秋星桥 on 2024/8/15.
//

import Foundation

#if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    Thread {
        LocalNetworkPermissionService().triggerDialog()
    }.start()
#endif

func print(_ items: Any..., separator: String = " ", terminator _: String = "\n") {
    #if DEBUG
        NSLog("[%@] + " + items.map { "\($0)" }.joined(separator: separator),
              NSLocalizedString("CFBundleDisplayName", bundle: Bundle.wrti_support, comment: ""))
    #endif
}

switch BootMode.current {
case .serviceDaemon:
    ServiceDaemon.main()
case .settingApp:
    FaircopyApp.main()
case .bootBoth:
    Thread { ServiceDaemon.main() }.start()
    FaircopyApp.main()
}

exit(0)
