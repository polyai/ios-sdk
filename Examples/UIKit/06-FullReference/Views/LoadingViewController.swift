// Copyright PolyAI Limited

//  LoadingViewController.swift
//  Examples/UIKit/06-FullReference
//
//  Initial session-loading screen — a centered spinner. Mirrors the SwiftUI
//  06 `LoadingView`. RootViewController swaps to ChatViewController once the
//  session reports ready (or to ErrorViewController on failure).
//
//  Keep README snippets in sync with this file. See SKILL.md §12.

import UIKit

final class LoadingViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Connecting..."
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        view.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }
}
