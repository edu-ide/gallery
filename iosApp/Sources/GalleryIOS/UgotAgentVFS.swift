import Foundation
import GallerySharedCore
import UniformTypeIdentifiers

struct AgentWorkspaceFile: Identifiable, Hashable, Sendable {
  let id: String
  let path: String
  let mimeType: String?
  let preview: String?
}

struct AgentWorkspaceStatus: Equatable, Sendable {
  static let empty = AgentWorkspaceStatus(files: [])

  let files: [AgentWorkspaceFile]

  var fileCount: Int { files.count }
  var isEmpty: Bool { files.isEmpty }
}

/// Thin iOS host adapter for the shared KMP Agent VFS.
///
/// MCP result/resource parsing is still protocol-edge glue, but path ownership, persistence,
/// source metadata, manifest semantics, and context projection live in `GallerySharedCore`.
final class UgotAgentVFS: @unchecked Sendable {
  static let shared = UgotAgentVFS()

  private let lock = NSLock()
  private var vfsByRootPath: [String: OkioAgentVirtualFileSystem] = [:]

  private init() {}

  func ingestMCPResult(
    sessionId: String,
    connectorId: String,
    toolName: String,
    toolCallId: String? = nil,
    result: [String: Any],
    persistTextBlocks: Bool = false
  ) -> String {
    lock.lock()
    defer { lock.unlock() }

    let vfs = storeLocked()
    let blocks = Self.contentBlocks(from: result)
    let toolResult = AgentVfsMcpToolResult(
      content: blocks,
      structuredContentJson: Self.jsonString(result["structuredContent"] ?? result["structured_content"]),
      rawResultJson: Self.jsonString(result)
    )
    let ingestor = AgentVfsMcpIngestor(vfs: vfs)
    _ = ingestor.ingestDefault(
      sessionId: sessionId,
      connectorId: connectorId,
      toolName: toolName,
      toolCallId: toolCallId,
      result: toolResult,
      persistTextBlocks: persistTextBlocks
    )

    let sanitizedSessionId = AgentVfsPaths.shared.sanitizeOpaqueSegment(
      raw: sessionId,
      fallback: "session"
    )
    return vfs.contextSummary(within: "/session/\(sanitizedSessionId)", limit: 24)
  }

  func workspaceStatus(sessionId: String) -> AgentWorkspaceStatus {
    lock.lock()
    defer { lock.unlock() }

    let vfs = storeLocked()
    let sessionRoot = sessionRootPath(sessionId: sessionId)
    guard vfs.exists(path: sessionRoot) else {
      return .empty
    }

    let files = vfs.tree(path: sessionRoot, maxDepth: 8)
      .map(\.node)
      .filter { !$0.isDirectory }
      .map { node in
        AgentWorkspaceFile(
          id: node.path.value,
          path: node.path.value,
          mimeType: node.mimeType,
          preview: node.previewText
        )
      }
    return AgentWorkspaceStatus(files: files)
  }

  func ingestUserAttachments(
    sessionId: String,
    attachments: [ChatInputAttachment]
  ) -> String {
    guard !attachments.isEmpty else { return "" }

    lock.lock()
    defer { lock.unlock() }

    let vfs = storeLocked()
    let ingestor = AgentVfsUserAttachmentIngestor(vfs: vfs)
    for attachment in attachments {
      guard let data = try? Data(contentsOf: attachment.url) else { continue }
      _ = ingestor.ingestDefault(
        sessionId: sessionId,
        fileName: attachment.displayName,
        mimeType: Self.mimeType(for: attachment),
        text: nil,
        blobBase64: data.base64EncodedString(),
        externalUri: attachment.url.absoluteString,
        overwrite: false
      )
    }

    let sanitizedSessionId = AgentVfsPaths.shared.sanitizeOpaqueSegment(
      raw: sessionId,
      fallback: "session"
    )
    return vfs.contextSummary(within: "/session/\(sanitizedSessionId)", limit: 24)
  }

  private func sessionRootPath(sessionId: String) -> String {
    let sanitizedSessionId = AgentVfsPaths.shared.sanitizeOpaqueSegment(
      raw: sessionId,
      fallback: "session"
    )
    return "/session/\(sanitizedSessionId)"
  }

  private func storeLocked() -> OkioAgentVirtualFileSystem {
    let rootPath = Self.rootDirectory().path
    if let existing = vfsByRootPath[rootPath] {
      return existing
    }
    let nowEpochMs = Int64(Date().timeIntervalSince1970 * 1_000)
    let vfs = AgentVfsFactory.shared.createSystem(rootPath: rootPath, nowEpochMs: nowEpochMs)
    vfsByRootPath[rootPath] = vfs
    return vfs
  }

  private static func rootDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
      FileManager.default.temporaryDirectory
    let root = base
      .appendingPathComponent("UGOT", isDirectory: true)
      .appendingPathComponent("AgentVFS", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func contentBlocks(from result: [String: Any]) -> [AgentVfsMcpContentBlock] {
    guard let content = result["content"] as? [[String: Any]] else { return [] }
    return content.map(contentBlock)
  }

  private static func contentBlock(from item: [String: Any]) -> AgentVfsMcpContentBlock {
    let type = (item["type"] as? String) ?? inferredContentType(from: item)

    if let resource = resourceContent(from: item["resource"]) {
      return AgentVfsMcpContentBlock(
        type: type,
        text: item["text"] as? String,
        resource: resource,
        uri: item["uri"] as? String,
        name: item["name"] as? String,
        mimeType: mimeType(from: item)
      )
    }

    if type == "resource" || type == "resource_link" || item["uri"] != nil {
      return AgentVfsMcpContentBlock(
        type: type,
        text: item["text"] as? String,
        resource: resourceContent(from: item),
        uri: item["uri"] as? String,
        name: item["name"] as? String,
        mimeType: mimeType(from: item)
      )
    }

    return AgentVfsMcpContentBlock(
      type: type,
      text: item["text"] as? String,
      resource: nil,
      uri: item["uri"] as? String,
      name: item["name"] as? String,
      mimeType: mimeType(from: item)
    )
  }

  private static func resourceContent(from value: Any?) -> AgentVfsMcpResourceContent? {
    guard let dict = value as? [String: Any] else { return nil }
    let uri = dict["uri"] as? String
    let mimeType = mimeType(from: dict)
    let text = dict["text"] as? String
    let blobBase64 = dict["blobBase64"] as? String ?? dict["blob_base64"] as? String ?? dict["blob"] as? String
    guard uri != nil || mimeType != nil || text != nil || blobBase64 != nil else { return nil }
    return AgentVfsMcpResourceContent(
      uri: uri,
      mimeType: mimeType,
      text: text,
      blobBase64: blobBase64
    )
  }

  private static func inferredContentType(from item: [String: Any]) -> String {
    if item["resource"] != nil { return "resource" }
    if item["uri"] != nil { return "resource_link" }
    return "text"
  }

  private static func mimeType(from item: [String: Any]) -> String? {
    item["mimeType"] as? String ??
      item["mime_type"] as? String ??
      item["mime"] as? String
  }

  private static func mimeType(for attachment: ChatInputAttachment) -> String {
    if let type = UTType(filenameExtension: attachment.url.pathExtension),
       let preferred = type.preferredMIMEType {
      return preferred
    }
    switch attachment.kind {
    case .image:
      return "image/jpeg"
    case .audio:
      return "audio/wav"
    }
  }

  private static func jsonString(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String {
      return string
    }
    guard JSONSerialization.isValidJSONObject(value) else {
      return nil
    }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
      return nil
    }
    return text
  }
}
