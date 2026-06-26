//
//  SwipeBackDisabler.swift
//  VectraPro
//
//  Disables the navigation swipe-back gesture (it conflicts with map panning).
//  Use via `.disablesSwipeBack()`.
//

import SwiftUI
import UIKit

/// Gesture delegate that prevents the swipe-back from ever beginning.
final class NoSwipeBackDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = NoSwipeBackDelegate()
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

extension View {
    func disablesSwipeBack() -> some View {
        background(SwipeBackDisabler())
    }
}

private struct SwipeBackDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.apply()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        // Re-apply on every SwiftUI update — UIKit re-enables the gesture once
        // the push animation completes, so a one-shot disable gets overridden.
        func apply() {
            DispatchQueue.main.async { Self.disableSwipeBack() }
        }

        private static func disableSwipeBack() {
            let navControllers = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .compactMap { $0.rootViewController }
                .flatMap { findNavigationControllers(in: $0) }

            for nav in navControllers {
                nav.interactivePopGestureRecognizer?.isEnabled = false
                // Delegate that refuses to begin — survives SwiftUI re-enabling.
                nav.interactivePopGestureRecognizer?.delegate = NoSwipeBackDelegate.shared
            }
        }

        private static func findNavigationControllers(in vc: UIViewController) -> [UINavigationController] {
            var result: [UINavigationController] = []
            if let nav = vc as? UINavigationController { result.append(nav) }
            vc.children.forEach { result += findNavigationControllers(in: $0) }
            if let presented = vc.presentedViewController {
                result += findNavigationControllers(in: presented)
            }
            return result
        }
    }
}
