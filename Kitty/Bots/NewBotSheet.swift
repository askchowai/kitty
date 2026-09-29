import SwiftUI
import KittyCore

/// Creates a bot: a Hermes profile on the gateway (name, description, default model) plus its
/// look from the Creator Studio, kept on this device under the new name.
struct NewBotSheet: View {
    var runtime: GatewayRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var cloneFrom = ""
    @State private var options: ModelOptionsResult?
    @State private var provider = ""
    @State private var modelName = ""
    @State private var choice: BotAvatarChoice = .default
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    /// Profile names are folder names on the gateway: letters, digits, dash and underscore.
    private var cleanName: String {
        name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            .reduce(into: "") { if !($0.last == "-" && $1 == "-") { $0.append($1) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    /// The studio stores looks by profile name; while the name is being typed they live under
    /// a draft key and move to the real name on create.
    private var draftKey: String { cleanName.isEmpty ? "new-bot" : cleanName }
    private var canCreate: Bool { !cleanName.isEmpty && !busy && !runtime.profiles.contains { $0.name == cleanName } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        BotAvatar(profile: draftKey, size: 84, active: true, override: choice)
                        Text(cleanName.isEmpty ? "New bot" : cleanName).font(.title3.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                Section {
                    CreatorStudio(profile: draftKey, choice: $choice)
                } header: { Text("Creator Studio") }
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !name.isEmpty, cleanName != name { Text("Saved as \(cleanName)").font(.caption).foregroundStyle(.secondary) }
                    if runtime.profiles.contains(where: { $0.name == cleanName }) { Text("A bot with this name already exists.").font(.caption).foregroundStyle(.red) }
                    TextField("Description", text: $description, axis: .vertical).lineLimit(1...3)
                } header: { Text("Bot") } footer: { Text("The description is what other Hermes surfaces show for this bot.") }
                Section {
                    if let o = options {
                        Menu {
                            ForEach(o.providers) { p in
                                Section(p.name) {
                                    ForEach(p.models ?? [], id: \.self) { m in Button(m) { provider = p.slug; modelName = m } }
                                }
                            }
                        } label: { LabeledContent("Default model", value: modelName.isEmpty ? "Gateway default" : modelName) }
                        .tint(.primary)
                    } else { ProgressView() }
                    Picker("Start from", selection: $cloneFrom) {
                        Text("A fresh profile").tag("")
                        ForEach(runtime.profiles) { Text($0.label).tag($0.name) }
                    }
                } header: { Text("Model") } footer: { Text("Starting from another bot copies its config, skills and instructions.") }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle("New Bot")
            // The preview starts right under the bar; the studio is the first thing to touch.
            .contentMargins(.top, 6, for: .scrollContent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Creating…" : "Create") { Task { await create() } }.disabled(!canCreate)
                }
            }
            .task {
                options = try? await runtime.api.get("/api/model/options", profile: runtime.selectedProfile)
            }
        }
        .presentationDetents([.large])
    }

    private func create() async {
        busy = true; defer { busy = false }
        let n = cleanName
        do {
            var body: [String: JSONValue] = ["name": .string(n)]
            if !cloneFrom.isEmpty { body["clone_from"] = .string(cloneFrom) }
            let _: JSONValue = try await runtime.api.send("POST", "/api/profiles", json: .object(body))
            let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty { let _: JSONValue? = try? await runtime.api.send("PUT", "/api/profiles/\(n)/description", json: .object(["description": .string(d)])) }
            if !modelName.isEmpty { let _: JSONValue? = try? await runtime.api.send("PUT", "/api/profiles/\(n)/model", json: .object(["provider": .string(provider), "model": .string(modelName)])) }
            // The look chosen under the draft key belongs to the new name now.
            BotAvatarStore.set(choice, for: n)
            var colors = BotColors.stored()
            if let c = colors[draftKey] { colors[n] = c }
            colors[draftKey] = nil
            BotColors.save(colors)
            await runtime.loadProfiles()
            NotificationCenter.default.post(name: .hermesSessionsChanged, object: nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
