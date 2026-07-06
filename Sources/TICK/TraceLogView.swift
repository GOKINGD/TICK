import SwiftUI

struct TraceLogView: View {
    @ObservedObject var store: TraceStore
    @State private var selectedEventID: UUID?
    @State private var selectedTraceID = TraceFilter.all

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private enum TraceFilter {
        static let all = "__all__"
        static let ungrouped = "__ungrouped__"
    }

    private var traceIDs: [String] {
        Array(Set(store.events.compactMap(\.traceID))).sorted { lhs, rhs in
            latestDate(for: lhs) > latestDate(for: rhs)
        }
    }

    private var filteredEvents: [TraceEvent] {
        let events: [TraceEvent]
        switch selectedTraceID {
        case TraceFilter.all:
            events = store.events
        case TraceFilter.ungrouped:
            events = store.events.filter { $0.traceID == nil }
        default:
            events = store.events.filter { $0.traceID == selectedTraceID }
        }

        return events.sorted { $0.date > $1.date }
    }

    private var selectedEvent: TraceEvent? {
        if let selectedEventID,
           let event = filteredEvents.first(where: { $0.id == selectedEventID }) {
            return event
        }
        return filteredEvents.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TICK Trace")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Button("Clear") {
                    store.clear()
                    selectedEventID = nil
                    selectedTraceID = TraceFilter.all
                }
            }

            HStack(spacing: 10) {
                Text("Run")
                    .font(.system(size: 12, weight: .bold, design: .rounded))

                Picker("", selection: $selectedTraceID) {
                    Text("All").tag(TraceFilter.all)
                    if store.events.contains(where: { $0.traceID == nil }) {
                        Text("Ungrouped").tag(TraceFilter.ungrouped)
                    }
                    ForEach(traceIDs, id: \.self) { traceID in
                        Text(traceLabel(traceID)).tag(traceID)
                    }
                }
                .labelsHidden()
                .frame(width: 360)

                Text("\(filteredEvents.count) events")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            HStack(spacing: 12) {
                eventList
                    .frame(width: 320)

                Divider()

                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 980, height: 600)
        .background(Color(red: 0.94, green: 0.97, blue: 0.98))
        .onChange(of: store.events) { events in
            if selectedTraceID != TraceFilter.all,
               !events.contains(where: { $0.traceID == selectedTraceID }) {
                selectedTraceID = TraceFilter.all
            }
            selectedEventID = filteredEvents.first?.id
        }
        .onChange(of: selectedTraceID) { _ in
            selectedEventID = filteredEvents.first?.id
        }
        .onAppear {
            selectedEventID = filteredEvents.first?.id
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filteredEvents) { event in
                    Button {
                        selectedEventID = event.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(formatter.string(from: event.date))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(event.stage)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.08, green: 0.34, blue: 0.42))
                            }

                            if let traceID = event.traceID {
                                Text(traceID)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Text(event.detail)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(red: 0.12, green: 0.17, blue: 0.20))
                                .lineLimit(3)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(event.id == selectedEventID ? Color(red: 0.78, green: 0.93, blue: 0.94) : Color.white.opacity(0.70))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selectedEvent {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedEvent.stage)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(formatter.string(from: selectedEvent.date))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let traceID = selectedEvent.traceID {
                            Text(traceID)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }

                GroupBox("Summary") {
                    ScrollView {
                        Text(selectedEvent.detail)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }

                GroupBox("Tokens") {
                    tokenGrid(selectedEvent.tokenUsage)
                }

                GroupBox("Raw HTTP") {
                    ScrollView {
                        Text(selectedEvent.rawHTTP ?? "No raw HTTP payload for this event.")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("No trace events yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tokenGrid(_ usage: LLMTokenUsage?) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
            tokenRow("Prompt tokens", usage?.promptTokens)
            tokenRow("Completion tokens", usage?.completionTokens)
            tokenRow("Total tokens", usage?.computedTotalTokens)
            Divider()
            tokenRow("Request words", usage?.requestWordCount)
            tokenRow("Response words", usage?.responseWordCount)
            tokenRow("Total words", usage?.totalWordCount)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func tokenRow(_ label: String, _ value: Int?) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "n/a")
                .textSelection(.enabled)
        }
    }

    private func latestDate(for traceID: String) -> Date {
        store.events.filter { $0.traceID == traceID }.map(\.date).max() ?? .distantPast
    }

    private func traceLabel(_ traceID: String) -> String {
        let count = store.events.filter { $0.traceID == traceID }.count
        return "\(traceID) · \(count)"
    }
}
