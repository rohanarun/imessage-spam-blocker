import SwiftUI
import AppKit
import Darwin
import Contacts
import GuardCore

@MainActor final class AppModel: ObservableObject {
    @Published var store = Store()
    @Published var key = ""
    @Published var openRouterKey = ""
    var selectedKey: String { (store.settings.provider == .openrouter ? openRouterKey : key).trimmingCharacters(in:.whitespacesAndNewlines) }
    @Published var running = false
    @Published var busy = false
    @Published var status = "Set up Jev to get started."
    @Published var failure: String?
    private var loop: Task<Void,Never>?
    private var openedAccessSettings = false
    @Published var contactsStatus = "Not requested"
    private let file: URL
    init() {
        file=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("QuietMessages/state.json")
        do {
            if FileManager.default.fileExists(atPath:file.path) {store=try JSONDecoder().decode(Store.self,from:Data(contentsOf:file))}
            key=Keychain.read("jev")
            openRouterKey=Keychain.read("openrouter")
            status=selectedKey.isEmpty ? "Set up Jev to get started." : "Ready when you are."
            for i in store.records.indices where store.records[i].state == "pending" {
                store.records[i].state = "needs verification"
            }
        } catch {failure="Could not load saved history: \(error.localizedDescription)"}
    }
    func requestContactsAccess() async {
        let authorization=CNContactStore.authorizationStatus(for:.contacts)
        if authorization == .authorized {contactsStatus="Allowed";return}
        if authorization == .denied || authorization == .restricted {
            contactsStatus="Denied — enable iMessage Spam Blocker in Contacts settings."
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
            return
        }
        do {
            let granted=try await CNContactStore().requestAccess(for:.contacts)
            contactsStatus=granted ? "Allowed" : "Not allowed"
        } catch {contactsStatus=error.localizedDescription}
    }
    @discardableResult func checkMessagesAccess() -> Bool {
        let database=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        let descriptor=Darwin.open(database.path,O_RDONLY)
        if descriptor >= 0 {Darwin.close(descriptor);openedAccessSettings=false;return true}
        let code=errno
        if code == EPERM || code == EACCES {
            status="Full Disk Access required. Enable iMessage Spam Blocker, then quit and reopen it."
            if !openedAccessSettings {
                openedAccessSettings=NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        } else if code == ENOENT {
            status="Messages database not found. Sign into Messages on this Mac first."
        } else {
            status="Cannot open the Messages database: \(String(cString:strerror(code)))."
        }
        return false
    }
    func save() throws {
        let directory=file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(store).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func persistKey(_ value: String, name: String) {
        do {
            let clean=value.trimmingCharacters(in:.whitespacesAndNewlines)
            try Keychain.save(clean,name:name)
            guard Keychain.read(name) == clean else {throw GuardError.message("Keychain could not verify the saved key. Please allow this app's Keychain access if macOS asks.")}
            status="API key saved securely."
        } catch {failure=error.localizedDescription}
    }
    func saveSettings() {
        do {try Keychain.save(key.trimmingCharacters(in:.whitespacesAndNewlines),name:"jev");try Keychain.save(openRouterKey.trimmingCharacters(in:.whitespacesAndNewlines),name:"openrouter");try save();status="Settings saved securely."} catch {failure=error.localizedDescription}
    }
    func start() {
        guard !running,!busy else {return}
        openedAccessSettings=false
        guard checkMessagesAccess() else {failure=status;return}
        guard !selectedKey.isEmpty else {failure="Enter the API key for your selected provider in Settings.";return}
        do {
            let credentialName=store.settings.provider == .openrouter ? "openrouter" : "jev"
            try Keychain.save(selectedKey,name:credentialName)
            guard Keychain.read(credentialName) == selectedKey else {throw GuardError.message("Could not verify the saved API key in Keychain.")}
            try save()
            if store.cursor == nil {store.cursor=Date().timeIntervalSince1970*1000;try save()}
            running=true;status="Watching new messages."
            loop=Task { [weak self] in
                while let self,self.running,!Task.isCancelled {
                    await self.scan()
                    do {try await Task.sleep(for:.seconds(self.store.settings.interval))} catch {break}
                }
            }
        } catch {failure=error.localizedDescription}
    }
    func stop() {running=false;loop?.cancel();loop=nil;status="Protection paused. Existing blocks remain."}
    func scan() async {
        guard !busy,let cursor=store.cursor else {return};busy=true;defer{busy=false}
        do {
            guard let resources=Bundle.main.resourceURL else {throw GuardError.message("Bundled Photon bridge missing.")}
            let messages=try await Bridge(resources:resources).messages(after:cursor)
            for message in messages.sorted(by:{($0.dateCreated ?? 0)<($1.dateCreated ?? 0)}) {
                guard running,!Task.isCancelled else {return}
                if store.processed.contains(message.id) {continue}
                if let prior=store.records.first(where:{$0.messageID == message.id}) {
                    // Reuse the durable decision after a failed native mutation; never reclassify or duplicate it.
                    if !store.activity.contains(where:{$0.id == message.id}) {
                        store.activity.insert(Activity(id:message.id,sender:prior.sender,text:prior.excerpt,outcome:prior.state == "blocked" ? "Blocked" : "Block not confirmed"),at:0)
                    }
                    store.processed.insert(message.id)
                    if let time=message.dateCreated {store.cursor=max(store.cursor ?? time,time)}
                    try save();continue
                }
                guard let sender=message.handle?.address,let text=message.text,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {store.processed.insert(message.id);try save();continue}
                if message.isFromMe {
                    store.activity.insert(Activity(id:message.id,sender:sender,text:text,outcome:"Outgoing context"),at:0)
                } else if store.allowed.contains(sender) {
                    store.activity.insert(Activity(id:message.id,sender:sender,text:text,outcome:"Always allowed"),at:0)
                } else {
                    let answer=try await Jev(settings:store.settings,key:selectedKey).classify(message,context:Array(store.activity.reversed()))
                    guard running,!Task.isCancelled else {return}
                    var outcome=answer.choice == "allow" ? "Allowed" : "Needs review"
                    if answer.shouldBlock(minimum:store.settings.minimumConfidence),message.chatKind == "dm" {
                        if store.records.contains(where:{$0.sender == sender && $0.state == "blocked"}) {outcome="Already blocked"}
                        else {
                            let record=BlockRecord(sender:sender,messageID:message.id,excerpt:text,state:"pending",judgment:answer)
                            store.records.insert(record,at:0);try save()
                            do {
                                try await MessagesBlocker.set(sender,blocked:true,settings:store.settings,key:selectedKey)
                                store.records[0].state="blocked";outcome="Blocked"
                            } catch {
                                store.records[0].state="needs verification";store.records[0].error=error.localizedDescription
                                try save();throw error
                            }
                        }
                    }
                    store.activity.insert(Activity(id:message.id,sender:sender,text:text,outcome:outcome),at:0)
                }
                store.processed.insert(message.id)
                // The timestamp is inclusive; GUIDs deduplicate equal-time rows and restart retries.
                if let time=message.dateCreated {store.cursor=max(store.cursor ?? time,time)}
                try save()
            }
            status="Watching new messages · Last checked \(Date().formatted(date:.omitted,time:.shortened))"
        } catch {stop();if checkMessagesAccess() {failure=error.localizedDescription;status="Paused — connection needs attention."}}
    }
    func retryBlock(_ record: BlockRecord) async {
        guard !busy else {return}
        busy=true;defer {busy=false}
        do {
            store.allowed.remove(record.sender);try save()
            try await MessagesBlocker.set(record.sender,blocked:true,settings:store.settings,key:selectedKey)
            for index in store.records.indices where store.records[index].sender == record.sender {
                store.records[index].state="blocked";store.records[index].error=nil
            }
            try save();status="Native block confirmed."
        } catch {
            for index in store.records.indices where store.records[index].messageID == record.messageID {store.records[index].error=error.localizedDescription}
            try? save();failure=error.localizedDescription
        }
    }
    func restore(_ record: BlockRecord) async {
        guard !busy else {return}
        busy=true;defer {busy=false}
        do {
            // Persist the override first, preventing automatic reblocking even after a crash.
            store.allowed.insert(record.sender);try save()
            try await MessagesBlocker.set(record.sender,blocked:false,settings:store.settings,key:selectedKey)
            for index in store.records.indices where store.records[index].sender == record.sender {store.records[index].state="restored";store.records[index].error=nil}
            try save();status="Sender restored and always allowed."
        } catch {failure=error.localizedDescription}
    }
    func removeAllowance(_ sender: String) {store.allowed.remove(sender);do{try save()}catch{failure=error.localizedDescription}}
}

@main struct QuietMessagesApp: App {
    @StateObject private var model=AppModel()
    var body: some Scene {
        WindowGroup("iMessage Spam Blocker") { MainView().environmentObject(model).frame(minWidth:860,minHeight:580) }
            .windowStyle(.hiddenTitleBar)
        MenuBarExtra("iMessage Spam Blocker",systemImage:"shield.lefthalf.filled") {
            Text(model.running ? "Protection on" : "Protection paused")
            Button(model.running ? "Pause" : "Start protection") {model.running ? model.stop() : model.start()}
            Divider()
            Button("Open iMessage Spam Blocker") {NSApp.activate(ignoringOtherApps:true);NSApp.windows.first?.makeKeyAndOrderFront(nil)}
            Button("Quit") {NSApp.terminate(nil)}
        }
    }
}
struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection="Activity"
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:28) {
                Label("iMessage Spam Blocker",systemImage:"shield.lefthalf.filled").font(.headline).padding(.top,24)
                List(["Activity","Blocked Senders","Settings"],id:\.self,selection:$selection) { item in
                    Label(item,systemImage:item == "Activity" ? "waveform.path" : item == "Settings" ? "slider.horizontal.3" : "person.crop.circle.badge.minus").tag(item)
                }.listStyle(.sidebar)
                VStack(alignment:.leading,spacing:8) {
                    HStack {Circle().fill(model.running ? Color.green : Color.secondary).frame(width:7,height:7);Text(model.running ? "Protection on" : "Protection paused").font(.caption)}
                    Text("Powered by Jev · Local Photon bridge").font(.caption2).foregroundStyle(.secondary)
                }.padding(.bottom,20)
            }.padding(.horizontal,12).navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:8) {
                        Text(selection).font(.system(size:30,weight:.semibold))
                        Text(selection == "Activity" ? "Less noise. More peace of mind." : selection == "Blocked Senders" ? "Every change has a way back." : "Your Mac. Your preferences.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection != "Settings" {Button(model.running ? "Pause protection" : "Start protection") {model.running ? model.stop() : model.start()}.buttonStyle(.borderedProminent).disabled(model.busy && !model.running)}
                }
                if selection == "Settings" {settings}
                else if selection == "Blocked Senders" {blocks}
                else {activity}
                Spacer(minLength:0)
                HStack {if model.busy {ProgressView().controlSize(.small)};Text(model.status).font(.caption).foregroundStyle(.secondary)}
            }.padding(32)
        }
        .onChange(of:model.key) {_,value in model.persistKey(value,name:"jev")}
        .onChange(of:model.openRouterKey) {_,value in model.persistKey(value,name:"openrouter")}
        .onChange(of:model.store.settings.provider) {_,_ in do {try model.save()} catch {model.failure=error.localizedDescription}}
        .task {if model.checkMessagesAccess() {await model.requestContactsAccess()}}
        .alert("Needs attention",isPresented:Binding(get:{model.failure != nil},set:{if !$0 {model.failure=nil}})) {Button("OK"){model.failure=nil}} message:{Text(model.failure ?? "")}
    }
    var activity: some View {
        Group {
            if model.store.activity.isEmpty {
                ContentUnavailableView("A quieter inbox starts here",systemImage:"bubble.left.and.text.bubble.right",description:Text("Add your Jev or OpenRouter key in Settings, grant Full Disk Access, then start protection. Only new messages are scanned."))
            } else {
                List(model.store.activity) {item in
                    VStack(alignment:.leading,spacing:8) {
                        HStack {Text(item.sender).fontWeight(.medium);Spacer();Text(item.outcome).font(.caption).foregroundStyle(item.outcome == "Blocked" ? .orange : .secondary)}
                        Text(item.text).lineLimit(3).foregroundStyle(.secondary)
                        Text(item.date.formatted()).font(.caption2).foregroundStyle(.tertiary)
                    }.padding(.vertical,8)
                }.listStyle(.plain)
            }
        }
    }
    var blocks: some View {
        Group {
            if model.store.records.isEmpty {ContentUnavailableView("No blocked senders",systemImage:"checkmark.shield",description:Text("Confirmed blocks appear here with the original message and a Restore button."))}
            else {List(model.store.records) {record in
                VStack(alignment:.leading,spacing:8) {
                    HStack {Text(record.sender).fontWeight(.medium);Spacer();Text(record.state.capitalized).font(.caption);if record.state == "needs verification" || record.state == "restored" {Button(record.state == "restored" ? "Block again" : "Retry block"){Task {await model.retryBlock(record)}}.disabled(model.busy)};if record.state != "restored" {Button("Restore"){Task {await model.restore(record)}}.disabled(model.busy)}}
                    Text(record.excerpt).foregroundStyle(.secondary).lineLimit(3)
                    Text("\(record.date.formatted()) · Jev confidence \(record.judgment.confidence.formatted(.percent))").font(.caption2).foregroundStyle(.secondary)
                    if let error=record.error {Text(error).font(.caption).foregroundStyle(.orange)}
                }.padding(.vertical,8)
            }.listStyle(.plain)}
        }
    }
    var settings: some View {
        Form {
            Section("Jev") {
                Picker("Provider",selection:$model.store.settings.provider) {
                    Text("TypeSafe direct").tag(JevProvider.typesafe)
                    Text("OpenRouter").tag(JevProvider.openrouter)
                }
                SecureField("TypeSafe API key",text:$model.key)
                SecureField("OpenRouter API key (optional)",text:$model.openRouterKey)
                if model.store.settings.provider == .openrouter {
                    TextField("OpenRouter Jev model",text:$model.store.settings.openRouterModel)
                    Link("Get an OpenRouter key",destination:URL(string:"https://openrouter.ai/settings/keys")!)
                } else {
                    TextField("TypeSafe model",text:$model.store.settings.model)
                    Link("Get a Jev API key",destination:URL(string:"https://typesafe.ai")!)
                }
                Text(model.store.settings.provider == .openrouter
                     ? "Message text, sender and recent conversation context are sent through OpenRouter to TypeSafe's Jev. Only your OpenRouter key is used. Both keys are stored separately in Keychain."
                     : "Message text, sender and recent conversation context are sent directly to TypeSafe. Only your TypeSafe key is used. Both keys are stored separately in Keychain.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Protection") {
                Slider(value:$model.store.settings.minimumConfidence,in:0.5...1,step:0.01) {Text("Minimum confidence")} minimumValueLabel:{Text("50%")} maximumValueLabel:{Text("100%")}
                Text("Automatic block threshold: \(model.store.settings.minimumConfidence.formatted(.percent))").font(.caption)
                Text("This is a configurable starting threshold, not a validated accuracy guarantee. Ambiguous and group messages stay for review.").font(.caption).foregroundStyle(.secondary)
                TextField("Check interval (seconds)",value:$model.store.settings.interval,format:.number)
                TextEditor(text:$model.store.settings.policy).frame(height:110).font(.body)
            }
            Section("Contacts") {
                Text(model.contactsStatus).font(.caption).foregroundStyle(.secondary)
                Button("Allow Contacts access") {Task {await model.requestContactsAccess()}}
                Text("macOS controls this permission. Contacts access alone does not establish that native blocking is supported.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local Photon bridge") {
                Text("Photon iMessage Kit reads the local Messages database. Grant iMessage Spam Blocker Full Disk Access, then relaunch this app. No Photon cloud credentials are required.").font(.caption).foregroundStyle(.secondary)
                Button("Open Full Disk Access settings") {NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)}
                Button("Open Accessibility settings") {NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)}
                Text("Blocking uses Messages’ own controls and requires Accessibility permission. It brings Messages forward briefly and verifies the inverse Block/Unblock action. It may also affect calls or FaceTime. Keep the app running for automatic protection.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.store.allowed.isEmpty {Section("Always allowed") {ForEach(model.store.allowed.sorted(),id:\.self) {sender in HStack {Text(sender);Spacer();Button("Remove exception"){model.removeAllowance(sender)}}}}}
            Button("Save settings"){if model.store.settings.interval > 0 {model.saveSettings()} else {model.failure="Check interval must be positive."}}.buttonStyle(.borderedProminent)
        }.formStyle(.grouped).disabled(model.running || model.busy)
    }
}
