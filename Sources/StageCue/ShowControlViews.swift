import SwiftUI

struct GroupEditor: View {
    @EnvironmentObject var state: ShowState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    var body: some View {
        HStack(alignment: .top) {
            VStack {
                List(selection: $selected) {
                    ForEach(state.project.groups) { group in Text(group.title).tag(group.id) }
                }.frame(width: 190)
                HStack {
                    Button("New") { let group = CueGroup(); state.project.groups.append(group); selected = group.id }
                    Button("Duplicate") {
                        guard let i = index else { return }; var copy = state.project.groups[i]; copy.id = UUID(); copy.title += " Copy"
                        for j in copy.actions.indices { copy.actions[j].id = UUID() }
                        state.project.groups.append(copy); selected = copy.id
                    }.disabled(index == nil)
                    Button("Delete") { if let i = index { state.project.groups.remove(at: i); selected = nil } }.disabled(index == nil)
                }
            }
            if let i = index {
                VStack(alignment: .leading) {
                    TextField("Group name", text: $state.project.groups[i].title).finishEditingOnCommit()
                    HStack {
                        Picker("Stop behavior", selection: $state.project.groups[i].stopMode) { ForEach(GroupStopMode.allCases) { Text($0.rawValue).tag($0) } }
                        TextField("Stop fade seconds", value: $state.project.groups[i].stopFade, format: .number).finishEditingOnCommit().frame(width: 70)
                    }
                    Toggle("Complete when scheduled actions and owned playback finish", isOn: $state.project.groups[i].automaticCompletion)
                    Text("Delays are seconds from group start. Wait adds an offset to following rows. Changes apply on the next trigger.").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(Array(state.project.groups[i].actions.enumerated()), id: \.element.id) { j, action in
                                actionRow(i, j, action)
                            }
                        }
                    }
                    HStack {
                        Button("Add action") { state.project.groups[i].actions.append(GroupAction()) }
                        Button("Trigger Group") { _ = state.scheduler.launch(state.project.groups[i]) }
                        Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                    ForEach(state.scheduler.runs.filter { $0.definition.id == selected }.suffix(4)) { run in
                        HStack {
                            Text(run.state.rawValue + (run.error.isEmpty ? "" : ": " + run.error)).font(.caption)
                            Spacer()
                            Button(run.state == .paused ? "Resume" : "Pause") { run.state == .paused ? state.scheduler.resume(run.id) : state.scheduler.pause(run.id) }
                            Button("Stop") { state.scheduler.stop(run.id) }
                        }
                    }
                }.frame(maxWidth: .infinity)
            } else {
                VStack { Text("Create a group, add actions, then assign it to a pad in Pad Settings."); Button("Done") { dismiss() } }.frame(maxWidth: .infinity)
            }
        }.padding(20).frame(width: 1000, height: 640)
    }
    private var index: Int? { state.project.groups.firstIndex { $0.id == selected } }
    @ViewBuilder private func actionRow(_ i: Int, _ j: Int, _ action: GroupAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(j + 1)").monospacedDigit()
                Toggle("Enabled", isOn: $state.project.groups[i].actions[j].enabled)
                Picker("Action", selection: $state.project.groups[i].actions[j].kind) { ForEach(ShowActionKind.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 235)
                Text("Delay")
                TextField("Delay seconds", value: $state.project.groups[i].actions[j].delay, format: .number).finishEditingOnCommit().frame(width: 65)
                Button("↑") { if j > 0 { state.project.groups[i].actions.swapAt(j, j - 1) } }.disabled(j == 0)
                Button("↓") { if j + 1 < state.project.groups[i].actions.count { state.project.groups[i].actions.swapAt(j, j + 1) } }.disabled(j + 1 == state.project.groups[i].actions.count)
                Button("Remove") { state.project.groups[i].actions.remove(at: j) }
            }
            HStack {
                if action.kind.needsCue {
                    Picker("Cue", selection: $state.project.groups[i].actions[j].cueID) {
                        Text("Select cue").tag(Optional<UUID>.none)
                        ForEach(state.project.allCues.filter { $0.kind != .group }) { Text($0.title + " (" + $0.kind.rawValue + ")").tag(Optional($0.id)) }
                    }
                    if let id = action.cueID, !state.project.allCues.contains(where: { $0.id == id }) { Text("Missing cue").foregroundStyle(.red) }
                }
                if action.kind == .triggerGroup {
                    Picker("Group", selection: $state.project.groups[i].actions[j].groupID) {
                        Text("Select group").tag(Optional<UUID>.none)
                        ForEach(state.project.groups) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
                if action.kind == .bus { Picker("Bus", selection: $state.project.groups[i].actions[j].bus) { ForEach(0..<6, id: \.self) { Text("Bus \($0 + 1)").tag($0) } } }
                if action.kind == .blackout { Toggle("Blackout on", isOn: $state.project.groups[i].actions[j].blackout) }
                if action.kind == .page { TextField("Page index (0 = first)", value: $state.project.groups[i].actions[j].page, format: .number).finishEditingOnCommit() }
                Text("Seconds")
                TextField("Duration seconds", value: $state.project.groups[i].actions[j].duration, format: .number).finishEditingOnCommit().frame(width: 65)
                if [.play, .fade, .bus].contains(action.kind) {
                    Text("dB"); TextField("Level dB", value: $state.project.groups[i].actions[j].levelDB, format: .number).finishEditingOnCommit().frame(width: 65)
                }
            }
            HStack {
                if action.kind == .play {
                    Toggle("Override cue level", isOn: $state.project.groups[i].actions[j].overrideLevel)
                    Toggle("Override fade-in", isOn: $state.project.groups[i].actions[j].overrideFade)
                }
                Toggle("Playback survives group stop", isOn: $state.project.groups[i].actions[j].survivesTermination)
            }.font(.caption)
            Divider()
        }
    }
}

struct SequenceEditor: View {
    @EnvironmentObject var state: ShowState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    var body: some View {
        HStack(alignment: .top) {
            VStack {
                List(selection: $selected) { ForEach(state.project.sequences) { Text($0.title).tag($0.id) } }.frame(width: 180)
                HStack {
                    Button("New") { let item = CueSequence(); state.project.sequences.append(item); selected = item.id }
                    Button("Duplicate") {
                        guard let i = index else { return }; var copy = state.project.sequences[i]; copy.id = UUID(); copy.title += " Copy"
                        for j in copy.steps.indices { copy.steps[j].id = UUID() }
                        state.project.sequences.append(copy); selected = copy.id
                    }.disabled(index == nil)
                    Button("Delete") { if let i = index { state.project.sequences.remove(at: i); selected = nil } }.disabled(index == nil)
                }
            }
            VStack(alignment: .leading) {
                if let i = index {
                    TextField("Sequence name", text: $state.project.sequences[i].title).finishEditingOnCommit()
                    Text("Drag rows to reorder. Advancement belongs to the currently running row. Follow with a completion time advances without stopping media.").font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(Array(state.project.sequences[i].steps.enumerated()), id: \.element.id) { j, step in
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("\(j + 1)").monospacedDigit()
                                    TextField("Step name", text: $state.project.sequences[i].steps[j].title).finishEditingOnCommit()
                                    Picker("Type", selection: $state.project.sequences[i].steps[j].target) { ForEach(SequenceTarget.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 120)
                                    Button("Remove") { state.project.sequences[i].steps.remove(at: j) }
                                }
                                HStack {
                                    if step.target == .cue {
                                        Picker("Cue", selection: $state.project.sequences[i].steps[j].cueID) {
                                            Text("Select cue").tag(Optional<UUID>.none)
                                            ForEach(state.project.allCues.filter { $0.kind != .group }) { Text($0.title).tag(Optional($0.id)) }
                                        }
                                    } else {
                                        Picker("Group", selection: $state.project.sequences[i].steps[j].groupID) {
                                            Text("Select group").tag(Optional<UUID>.none)
                                            ForEach(state.project.groups) { Text($0.title).tag(Optional($0.id)) }
                                        }
                                    }
                                    Picker("Advance", selection: $state.project.sequences[i].steps[j].advancement) { ForEach(AdvanceMode.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 150)
                                    if step.advancement == .timed {
                                        Text("Delay"); TextField("Advance delay", value: $state.project.sequences[i].steps[j].delay, format: .number).finishEditingOnCommit().frame(width: 70)
                                    }
                                    if step.advancement == .follow {
                                        Text("Complete after"); TextField("Completion seconds (0 = natural)", value: $state.project.sequences[i].steps[j].completionAfter, format: .number).finishEditingOnCommit().frame(width: 70)
                                    }
                                }
                            }
                            .draggable(step.id.uuidString)
                            .dropDestination(for: String.self) { values, _ in
                                guard let value = values.first, let id = UUID(uuidString: value), let source = state.project.sequences[i].steps.firstIndex(where: { $0.id == id }), source != j else { return false }
                                let moved = state.project.sequences[i].steps.remove(at: source)
                                state.project.sequences[i].steps.insert(moved, at: min(j, state.project.sequences[i].steps.count))
                                return true
                            }
                        }
                        .onMove { from, to in state.project.sequences[i].steps.move(fromOffsets: from, toOffset: to) }
                    }
                    HStack {
                        Button("Add step") { state.project.sequences[i].steps.append(SequenceStep()) }
                        Button("Load for GO") { state.loadSequence(state.project.sequences[i].id) }
                        Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                } else { Text("Create a sequence and add media cues or groups."); Button("Done") { dismiss() } }
                HStack {
                    Button("GO") { state.performShowCommand(.go) }.buttonStyle(.borderedProminent)
                    Button(state.sequence.state == .paused ? "Resume" : "Pause") { state.performShowCommand(.pause) }
                    Button("Stop") { state.performShowCommand(.stop) }
                    Button("Skip next") { state.performShowCommand(.next) }
                    Button("Back") { state.performShowCommand(.previous) }
                    Button("Reset") { state.sequence.reset() }
                }
                Text("\(state.sequence.state.rawValue) • Current: \(state.sequence.currentStep?.title ?? "—") • Next: \(state.sequence.nextStep?.title ?? "End")").font(.caption)
                if !state.sequence.error.isEmpty { Text(state.sequence.error).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity)
        }.padding(20).frame(width: 1050, height: 680)
    }
    private var index: Int? { state.project.sequences.firstIndex { $0.id == selected } }
}

struct ShowPerformanceView: View {
    @EnvironmentObject var state: ShowState
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Sequence", selection: Binding(get: { state.project.show.sequenceID }, set: { state.loadSequence($0) })) {
                        Text("Select sequence").tag(Optional<UUID>.none)
                        ForEach(state.project.sequences) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Button("Reload / Reset") { state.loadSequence(state.project.show.sequenceID) }
                    Button("Shortcuts") { state.editingShowKeys = true }
                }
                ScrollViewReader { proxy in
                    List {
                        if let definition = state.sequence.definition {
                            ForEach(Array(definition.steps.enumerated()), id: \.element.id) { i, step in
                                HStack(spacing: 12) {
                                    Text(String(format: "%02d", i + 1)).font(.title3.monospaced()).frame(width: 42)
                                    Image(systemName: step.target == .group ? "square.stack.3d.up" : cueIcon(step))
                                    Text(step.title).font(.title3).lineLimit(2)
                                    Spacer()
                                    Text(state.sequence.stepStates[step.id]?.rawValue ?? "Ready").font(.callout)
                                    Text(step.advancement.rawValue).font(.caption).foregroundStyle(.secondary)
                                }.padding(8)
                                    .listRowBackground(i == state.sequence.current ? Color.indigo.opacity(0.5) : Color.clear)
                                    .id(step.id)
                            }
                        } else { Text("Prepare a sequence using the Sequences editor, then select it above.") }
                    }
                    .onChange(of: state.sequence.current) { _, _ in
                        if let id = state.sequence.currentStep?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                Text(state.sequence.state.rawValue.uppercased()).font(.headline).foregroundStyle(state.sequence.state == .error ? .red : .secondary)
                Text("CURRENT").font(.caption).foregroundStyle(.secondary)
                Text(state.sequence.currentStep?.title ?? "Ready for first cue").font(.title2.bold())
                Text("NEXT").font(.caption).foregroundStyle(.secondary)
                Text(state.sequence.nextStep?.title ?? "End of sequence").font(.title3)
                Button { state.performShowCommand(.go) } label: {
                    Text("GO").font(.system(size: 40, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 72)
                }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
                    .disabled(state.sequence.definition == nil || state.sequence.state == .paused || state.sequence.state == .error)
                HStack {
                    Button(state.sequence.state == .paused ? "Resume" : "Pause") { state.performShowCommand(.pause) }
                    Button("Stop") { state.performShowCommand(.stop) }.tint(.red)
                }
                HStack {
                    Button("Skip next") { state.performShowCommand(.next) }
                    Button("Back") { state.performShowCommand(.previous) }
                    Button("Reset") { state.scheduler.manualOverride("sequence"); state.sequence.reset() }
                }
                Text("Elapsed " + time(state.sequence.elapsed)).monospacedDigit()
                if let remaining = state.sequence.countdown { Text("Next GO in " + time(remaining)).font(.title3.monospacedDigit()).foregroundStyle(.yellow) }
                if !state.sequence.error.isEmpty { Text(state.sequence.error).foregroundStyle(.red) }
                Divider(); Text("RUNNING GROUPS").font(.caption.bold())
                ScrollView {
                    ForEach(state.scheduler.runs.filter { [.running, .paused, .error].contains($0.state) }) { run in
                        VStack(alignment: .leading) {
                            Text(run.definition.title).bold()
                            Text(run.state.rawValue + " • " + time(run.elapsed)).font(.caption.monospacedDigit())
                            if let remaining = run.nextEvent { Text("Next action in " + time(remaining)).font(.caption).foregroundStyle(.yellow) }
                            if !run.error.isEmpty { Text(run.error).font(.caption).foregroundStyle(.red) }
                            HStack {
                                Button(run.state == .paused ? "Resume" : "Pause") { run.state == .paused ? state.scheduler.resume(run.id) : state.scheduler.pause(run.id) }
                                Button("Stop") { state.scheduler.stop(run.id) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
                    }
                }
            }.frame(width: 320)
        }.padding(14).background(Color(white: 0.07)).preferredColorScheme(.dark)
    }
    private func time(_ value: Double) -> String { String(format: "%02d:%04.1f", Int(max(0, value)) / 60, max(0, value).truncatingRemainder(dividingBy: 60)) }
    private func cueIcon(_ step: SequenceStep) -> String {
        switch state.project.allCues.first(where: { $0.id == step.cueID })?.kind {
        case .video: return "film"; case .image: return "photo"; default: return "waveform"
        }
    }
}

struct ShowKeyEditor: View {
    @EnvironmentObject var state: ShowState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Show Control Shortcuts").font(.title2.bold())
            Text("Command + Option + chosen key. Available in both modes. Command-period always remains Emergency Stop All.").font(.callout)
            ForEach(ShowCommand.allCases) { command in
                Picker(command.rawValue, selection: Binding(get: { state.project.show.keys[command.rawValue] ?? "" }, set: { state.setShowKey($0, command: command) })) {
                    Text("None").tag("")
                    ForEach(ShowConfiguration.availableKeys.filter { key in
                        key == state.project.show.keys[command.rawValue] || !state.project.show.keys.contains(where: { $0.value == key })
                    }, id: \.self) { Text("⌘⌥" + $0.uppercased()).tag($0) }
                }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width: 520)
    }
}
