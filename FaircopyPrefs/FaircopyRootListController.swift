import Combine
import SwiftUI
import SwiftUIIntrospect
import UIKit

final class FaircopyRootController: UIHostingController<FaircopyRootView> {
    private let primaryScrollViewSubject = CurrentValueSubject<UIScrollView?, Never>(nil)
    private var cancellables = Set<AnyCancellable>()

    init() {
        super.init(rootView: FaircopyRootView(scrollViewSubject: primaryScrollViewSubject))

        primaryScrollViewSubject
            .compactMap { $0 }
            .sink { scrollView in
                NSLog("[Faircopy] Primary scroll view: \(scrollView)")
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc var contentScrollView: UIScrollView? {
        primaryScrollViewSubject.value
    }
}

@objc(FaircopyRootListController)
final class FaircopyRootListController: PSListController {
    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = NSLocalizedString("Faircopy", bundle: Bundle.wrti_support, comment: "")
        navigationItem.largeTitleDisplayMode = .never

        let controller = FaircopyRootController()
        addChild(controller)

        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(controller.view)

        controller.didMove(toParent: self)
    }

    @objc var contentScrollView: UIScrollView? {
        (children.first as? FaircopyRootController)?.contentScrollView
    }
}
