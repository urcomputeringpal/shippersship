import ShipKit
import SwiftUI

struct PipelineView: View {
    let pipeline: Pipeline

    var body: some View {
        HStack(spacing: 0) {
            step(pipeline.review, "Review", "person.2")
            connector(after: pipeline.review)
            step(pipeline.checks, "CI", "checkmark.seal")
            connector(after: pipeline.checks)
            step(pipeline.merge, "Merge", "arrow.triangle.merge")
            connector(after: pipeline.merge)
            step(pipeline.deploy, "Deploy", "shippingbox")
        }
        .fixedSize()
    }

    private func step(_ status: StepStatus, _ name: String, _ symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(status.fill)
                .overlay(Circle().strokeBorder(status.color, lineWidth: status == .ready ? 1.5 : 0))
            Image(systemName: status.symbol(default: symbol))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(status.iconColor)
                .symbolEffect(.pulse, isActive: status == .active)
        }
        .frame(width: 20, height: 20)
        .help("\(name): \(status.label)")
    }

    private func connector(after status: StepStatus) -> some View {
        Rectangle()
            .fill(status == .done ? Color.green.opacity(0.6) : Color.secondary.opacity(0.25))
            .frame(width: 8, height: 2)
    }
}

extension StepStatus {
    var color: Color {
        switch self {
        case .done, .ready: .green
        case .active: .blue
        case .failed: .red
        case .blocked: .orange
        case .pending, .skipped: .secondary
        }
    }

    var fill: Color {
        switch self {
        case .ready: .clear
        case .pending: .secondary.opacity(0.15)
        case .skipped: .secondary.opacity(0.07)
        default: color
        }
    }

    var iconColor: Color {
        switch self {
        case .ready: .green
        case .pending: .secondary
        case .skipped: .secondary.opacity(0.5)
        default: .white
        }
    }

    func symbol(default symbol: String) -> String {
        switch self {
        case .done: "checkmark"
        case .failed: "xmark"
        case .blocked: "exclamationmark"
        case .skipped: "minus"
        case .active: "ellipsis"
        case .ready, .pending: symbol
        }
    }

    var label: String {
        switch self {
        case .pending: "not started"
        case .active: "in progress"
        case .ready: "ready"
        case .blocked: "blocked"
        case .failed: "failed"
        case .done: "done"
        case .skipped: "n/a"
        }
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .progress: .blue
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}

// MARK: - Token & settings
