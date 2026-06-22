// MCPConnectSheet.swift — guided "Connect an AI app" sheet (macOS).
#if os(macOS)
import SwiftUI

struct MCPConnectSheet: View {
    @EnvironmentObject var mcp: MCPServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an AI app").font(.title3).bold()
            Text("Apps on this Mac can drive RayMol over a local, token-protected link.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()

            HStack(spacing: 8) {
                Circle().fill(mcp.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text("RayMol MCP server").fontWeight(.medium)
                Spacer()
                Toggle("", isOn: Binding(get: { mcp.isRunning }, set: { _ in mcp.toggle() }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if mcp.isRunning, let port = mcp.port {
                Text("Listening on 127.0.0.1:\(port)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            HStack(spacing: 8) {
                Text("Claude Code").fontWeight(.medium)
                if mcp.claudeCLIPath != nil {
                    Text("✓ detected").font(.caption).foregroundStyle(.green)
                } else {
                    Text("not found").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect") { result = mcp.connectClaudeCode().message }
                    .disabled(!mcp.isRunning)
            }
            if let port = mcp.port {
                Text("Manual command:").font(.caption)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text("claude mcp add --transport http raymol "
                        + "http://127.0.0.1:\(port)/mcp "
                        + "--header \"Authorization: Bearer \(mcp.token)\" --scope user")
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled).padding(8)
                }
                .background(Color.black.opacity(0.25)).cornerRadius(6)
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()

            HStack {
                Text("Claude for Mac").foregroundStyle(.secondary)
                Spacer()
                Text("Coming soon").font(.caption).foregroundStyle(.secondary)
            }

            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding(20).frame(width: 470)
    }
}
#endif
