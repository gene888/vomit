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
                        ForEach(state.project.cues.compactMap { $0 }.filter { $0.kind != .group }) { Text($0.title + " (" + $0.kind.rawValue + ")").tag(Optional($0.id)) }
                    }
                    if let id = action.cueID, !state.project.cues.compactMap({ $0 }).contains(where: { $0.id == id }) { Text("Missing cue").foregroundStyle(.red) }
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
