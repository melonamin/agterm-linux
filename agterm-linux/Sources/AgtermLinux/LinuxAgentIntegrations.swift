import CGtk
import Foundation
import LinuxIntegrations

@MainActor
extension AppController {
    func makeIntegrationsSettingsPage() -> OpaquePointer? {
        let page = preferencesPage(
            "Integrations", name: .integrations, icon: "application-x-addon-symbolic")
        integrationRows.removeAll()
        integrationKindButtons.removeAll()
        integrationButtons.removeAll()

        let cli = preferencesGroup("Command Line")
        addIntegrationRow(.commandLineTool, plan: .commandLineTool, to: cli)
        adw_preferences_page_add(cast(page), cast(cli))

        let hooks = preferencesGroup("Agent Status Hooks")
        addIntegrationRow(.claudeHooks, plan: .hooks, to: hooks)
        addIntegrationRow(.codexHooks, plan: .hooks, to: hooks)
        addIntegrationRow(.piHooks, plan: .hooks, to: hooks)
        addIntegrationRow(.opencodePlugin, plan: .hooks, to: hooks)
        adw_preferences_page_add(cast(page), cast(hooks))

        let skill = preferencesGroup("Agent Skill")
        addIntegrationRow(.agentSkill, plan: .skill, to: skill)
        adw_preferences_page_add(cast(page), cast(skill))

        let actions = preferencesGroup("Status")
        let refresh = OpaquePointer(adw_action_row_new())
        "Inspect integrations again".withCString { adw_preferences_row_set_title(cast(refresh), $0) }
        adw_action_row_add_suffix(
            cast(refresh),
            W(
                preferencesButton(
                    "Refresh", handler: unsafeBitCast(onRefreshIntegrations, to: GCallback.self))))
        adw_preferences_group_add(cast(actions), W(refresh))
        adw_preferences_page_add(cast(page), cast(actions))

        refreshIntegrationStatus()
        return page
    }

    private func addIntegrationRow(
        _ kind: IntegrationKind, plan: IntegrationPlanKind,
        to group: OpaquePointer?
    ) {
        let row = OpaquePointer(adw_action_row_new())
        kind.title.withCString { adw_preferences_row_set_title(cast(row), $0) }
        "Inspecting…".withCString { adw_action_row_set_subtitle(cast(row), $0) }
        let button = preferencesButton(
            "…", handler: unsafeBitCast(onIntegrationAction, to: GCallback.self))
        gtk_widget_set_sensitive(W(button), 0)
        adw_action_row_add_suffix(cast(row), W(button))
        adw_preferences_group_add(cast(group), W(row))
        integrationRows[kind] = row
        if let button {
            integrationKindButtons[kind] = button
            integrationButtons[button] = plan
        }
    }

    func refreshIntegrationStatus() {
        let id = windowID
        integrationRefreshGeneration &+= 1
        let generation = integrationRefreshGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = IntegrationService().status()
            runOnMain {
                MainActor.assumeIsolated {
                    guard let controller = gWindows[id], controller.settingsDialog != nil,
                          controller.integrationRefreshGeneration == generation else { return }
                    controller.applyIntegrationSnapshot(snapshot)
                }
            }
        }
    }

    private func applyIntegrationSnapshot(_ snapshot: IntegrationSnapshot) {
        for item in snapshot.items {
            guard let row = integrationRows[item.kind] else { continue }
            let path = item.path.map { "\n\($0)" } ?? ""
            let version = item.version.map { " · version \($0)" } ?? ""
            "\(item.state.label)\(version) — \(item.detail)\(path)".withCString {
                adw_action_row_set_subtitle(cast(row), $0)
            }
            guard let button = integrationKindButtons[item.kind] else { continue }
            // A conflict remains reviewable: a multi-target hooks/skill plan may still contain safe
            // operations for another agent, while a conflict-only plan explains what must be resolved.
            let actionable = ![.installed, .unavailable].contains(item.state)
            let label =
                item.state == .updateAvailable
                ? "Update"
                : (item.state == .partial
                    ? "Repair"
                    : (item.state == .installed
                        ? "Current"
                        : (item.state == .conflict
                            ? "Review"
                            : (item.state == .unavailable ? "Unavailable" : "Install"))))
            label.withCString { gtk_button_set_label(BUTTON(button), $0) }
            gtk_widget_set_sensitive(W(button), actionable ? 1 : 0)
        }
    }

    func prepareIntegration(_ kind: IntegrationPlanKind) {
        guard !integrationOperationInFlight else {
            showToast("Finish the current integration change first")
            return
        }
        integrationOperationInFlight = true
        showToast("Inspecting integration files…")
        let id = windowID
        DispatchQueue.global(qos: .userInitiated).async {
            let service = IntegrationService()
            do {
                let plan: IntegrationPlan
                switch kind {
                case .commandLineTool: plan = try service.planCommandLineTool()
                case .hooks: plan = try service.planHooks()
                case .skill: plan = try service.planSkill()
                }
                runOnMain { MainActor.assumeIsolated { gWindows[id]?.presentIntegrationPlan(plan) } }
            } catch {
                let message = String(describing: error)
                runOnMain {
                    MainActor.assumeIsolated {
                        guard let controller = gWindows[id] else { return }
                        controller.integrationOperationInFlight = false
                        controller.presentIntegrationResult(title: "Inspection Failed", text: message)
                    }
                }
            }
        }
    }

    private func presentIntegrationPlan(_ plan: IntegrationPlan) {
        guard plan.canApply else {
            integrationOperationInFlight = false
            presentIntegrationResult(
                title: plan.conflicts.isEmpty ? "Already Current" : "Resolve Conflicts",
                text: plan.summary)
            return
        }
        pendingIntegrationPlan = plan
        let dialog = OpaquePointer(
            "Apply Integration Changes?".withCString { title in
                plan.summary.withCString { body in adw_alert_dialog_new(title, body) }
            })
        attachControllerContext(to: dialog, windowID: windowID)
        "cancel".withCString { id in
            "Cancel".withCString { label in adw_alert_dialog_add_response(cast(dialog), id, label) }
        }
        "apply".withCString { id in
            "Apply".withCString { label in adw_alert_dialog_add_response(cast(dialog), id, label) }
        }
        "apply".withCString { adw_alert_dialog_set_default_response(cast(dialog), $0) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(
            dialog, "response", unsafeBitCast(onIntegrationPlanResponse, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func respondToIntegrationPlan(_ response: String) {
        guard response == "apply", let plan = pendingIntegrationPlan else {
            pendingIntegrationPlan = nil
            integrationOperationInFlight = false
            return
        }
        pendingIntegrationPlan = nil
        let id = windowID
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try IntegrationService().apply(plan)
                let text = result.results.map {
                    "\($0.success ? "OK" : "FAILED") \($0.action): \($0.path)\n\($0.message)"
                }.joined(separator: "\n\n") + result.conflicts.map {
                    "\n\nSKIPPED conflict: \($0)"
                }.joined()
                runOnMain {
                    MainActor.assumeIsolated {
                        guard let controller = gWindows[id] else { return }
                        controller.integrationOperationInFlight = false
                        controller.presentIntegrationResult(
                            title: result.succeeded ? "Integration Updated" : "Update Incomplete",
                            text: text)
                        controller.refreshIntegrationStatus()
                    }
                }
            } catch {
                let message = String(describing: error)
                runOnMain {
                    MainActor.assumeIsolated {
                        guard let controller = gWindows[id] else { return }
                        controller.integrationOperationInFlight = false
                        controller.presentIntegrationResult(title: "Update Failed", text: message)
                    }
                }
            }
        }
    }

    func presentIntegrationResult(title: String, text: String) {
        let dialog = OpaquePointer(
            title.withCString { heading in
                text.withCString { body in adw_alert_dialog_new(heading, body) }
            })
        attachControllerContext(to: dialog, windowID: windowID)
        "ok".withCString { id in
            "OK".withCString { label in adw_alert_dialog_add_response(cast(dialog), id, label) }
        }
        "ok".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        adw_dialog_present(cast(dialog), W(window))
    }
}

private let onRefreshIntegrations: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.refreshIntegrationStatus() }
}
private let onIntegrationAction: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        guard let button, let controller = controllerForWidget(button),
              let kind = controller.integrationButtons[button] else { return }
        controller.prepareIntegration(kind)
    }
}
private let onIntegrationPlanResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let value = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated {
        controllerForObject(dialog)?.respondToIntegrationPlan(value)
    }
}
