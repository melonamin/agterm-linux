import agtermCore

func linuxPickItemStatusError(_ item: ControlPickItem) -> String? {
    if let status = item.status, AgentStatus(rawValue: status) == nil {
        return "invalid pick item status (\(AgentStatus.allCases.map(\.rawValue).joined(separator: "|")))"
    }
    if let color = item.statusColor, !WatermarkConfig.isValidColorHex(color) {
        return "invalid pick item color (expected #rrggbb)"
    }
    if let shape = item.statusShape, StatusShape(rawValue: shape) == nil {
        return "invalid pick item shape (\(StatusShape.validNamesList))"
    }
    return nil
}

func linuxPickIndicator(_ item: ControlPickItem) -> AgentIndicator? {
    guard let raw = item.status, let status = AgentStatus(rawValue: raw) else { return nil }
    return AgentIndicator(status: status, color: item.statusColor, shape: item.statusShape.flatMap(StatusShape.init(rawValue:)))
}
