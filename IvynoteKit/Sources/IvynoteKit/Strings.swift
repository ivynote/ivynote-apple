import Foundation

/// Every string the app shows, in each `Language`. One protocol, so a string
/// missing from a language does not compile. Wording follows the web
/// client's dictionary (`client/packages/core/src/i18n.ts`) and the Android
/// client's `Strings.kt` where they have it.
public protocol Strings: Sendable {
    /// For dates and numbers in this language.
    var locale: Locale { get }

    // Common
    var appName: String { get }
    var slogan: String { get }
    var name: String { get }
    var save: String { get }
    var cancel: String { get }
    var create: String { get }
    var delete: String { get }
    var remove: String { get }
    var rename: String { get }
    var open: String { get }
    var retry: String { get }
    var done: String { get }
    var close: String { get }
    var more: String { get }
    var ok: String { get }
    var error: String { get }
    var copied: String { get }
    var restore: String { get }
    var deleteForever: String { get }
    var moveToTrash: String { get }
    var untitled: String { get }
    var note: String { get }
    var notes: String { get }
    var tags: String { get }
    var trash: String { get }
    var pinned: String { get }
    var pin: String { get }
    var unpin: String { get }
    var cannotReadFile: String { get }
    func cannotReadNamedFile(_ name: String) -> String
    func keychainError(_ detail: String) -> String

    // Language
    var language: String { get }
    func followSystem(_ language: String) -> String
    var languageAccountHint: String { get }
    var languageDeviceHint: String { get }

    // Dates
    func yesterday(_ time: String) -> String

    // Sync status (guide 11.7)
    var localUnsynced: String { get }
    var downloadingNotes: String { get }
    var syncing: String { get }
    var offline: String { get }
    func offlinePending(_ n: Int) -> String
    var syncError: String { get }
    func pending(_ n: Int) -> String
    func synced(_ ago: String) -> String
    var neverSynced: String { get }
    func blocked(_ n: Int) -> String
    func uploadsPending(_ n: Int) -> String

    // Libraries
    var libraries: String { get }
    var welcome: String { get }
    var pickLibrary: String { get }
    var connect: String { get }
    var connectHint: String { get }
    var newLocal: String { get }
    var newLocalHint: String { get }
    var newLocalMessage: String { get }
    var canConvert: String { get }
    var startCloud: String { get }
    var startCloudHint: String { get }
    var localOnly: String { get }
    var defaultLibraryName: String { get }
    var renameLibrary: String { get }
    var removeLibrary: String { get }
    func removeNamed(_ name: String) -> String
    func removeLocalMessage(_ name: String) -> String
    func removeServerMessage(_ name: String) -> String
    var turnOnSync: String { get }
    var migratedHint: String { get }
    var cannotOpenData: String { get }
    var backToLibraries: String { get }

    // Account
    var account: String { get }
    var user: String { get }
    var username: String { get }
    var email: String { get }
    var role: String { get }
    var admin: String { get }
    func syncSection(_ library: String) -> String
    var server: String { get }
    var status: String { get }
    var thisDevice: String { get }
    var syncNow: String { get }
    var openAdmin: String { get }
    var signOut: String { get }
    var signOutTitle: String { get }
    var signOutHint: String { get }
    func signOutUnsynced(_ n: Int) -> String
    var signOutMessage: String { get }

    // Library and shelf
    var noNoteSelected: String { get }
    var uploadFailedTitle: String { get }
    func uploadRefused(_ name: String, _ message: String) -> String
    var conflictTitle: String { get }
    func conflictMessage(_ title: String) -> String
    var openCopy: String { get }
    var searchNotes: String { get }
    var newNote: String { get }
    var newFolder: String { get }
    var newSubfolder: String { get }
    var renameFolder: String { get }
    var deleteFolderTitle: String { get }
    func deleteNamed(_ name: String) -> String
    var deleteFolderMessage: String { get }
    var emptyTrashTitle: String { get }
    var emptyTrash: String { get }
    var cannotUndo: String { get }
    var editTagEllipsis: String { get }
    var collapsePinned: String { get }
    var expandPinned: String { get }
    var sort: String { get }
    var sortUpdated: String { get }
    var sortCreated: String { get }
    var sortTitle: String { get }
    func showMore(_ next: Int, _ hidden: Int) -> String
    var moveTo: String { get }
    var noNotebook: String { get }
    var mediaLibraryEllipsis: String { get }
    var accountAndSync: String { get }
    var turnOnSyncEllipsis: String { get }
    var manageLibraries: String { get }
    var switchLibrary: String { get }
    func libraryLabel(_ name: String) -> String

    // Note
    var noteInTrash: String { get }
    var renameNote: String { get }
    var share: String { get }
    var shareAndExport: String { get }
    var history: String { get }
    var showOutline: String { get }
    var hideOutline: String { get }
    var outline: String { get }
    var noHeadings: String { get }
    var noHeadingsHint: String { get }
    var formatHeading: String { get }
    var formatBold: String { get }
    var formatItalic: String { get }
    var formatTask: String { get }
    var formatList: String { get }
    var formatOrdered: String { get }
    var formatQuote: String { get }
    var formatCode: String { get }
    var formatWikiLink: String { get }
    var formatLink: String { get }
    var formatStrike: String { get }
    var photo: String { get }
    var camera: String { get }
    var attachment: String { get }
    var undo: String { get }
    var hideKeyboard: String { get }
    func words(_ n: String) -> String
    var uploading: String { get }
    var backlinks: String { get }
    func backlinksCount(_ n: Int) -> String

    // Attachments
    var insertAttachment: String { get }
    var insertAttachmentHelp: String { get }
    var photoOrVideo: String { get }
    var file: String { get }
    func savedLocally(_ name: String) -> String
    func uploadFailed(_ name: String, _ error: String) -> String
    var fileTooLarge: String { get }
    var localNoServer: String { get }

    // Tags
    func tagColor(_ color: String) -> String
    var removeFromNote: String { get }
    var addTag: String { get }
    func createTag(_ name: String) -> String
    func maxTags(_ n: Int) -> String
    var noTags: String { get }
    var noTagsHint: String { get }
    var searchOrCreateTag: String { get }
    var tagName: String { get }
    var color: String { get }
    var deleteTag: String { get }
    func deleteTagMessage(_ n: Int) -> String
    var editTag: String { get }
    func deleteTagTitle(_ name: String) -> String
    var nameEmpty: String { get }
    var nameTooLong: String { get }
    var tagExists: String { get }

    // History
    var show: String { get }
    var rendered: String { get }
    var source: String { get }
    var restoreVersion: String { get }
    var localNoHistory: String { get }
    var localNoHistoryHint: String { get }
    var historyLoadFailed: String { get }
    var noHistory: String { get }
    var noHistoryHint: String { get }
    var currentVersion: String { get }
    func restorePrompt(_ time: String) -> String

    // Sharing
    var localNoShare: String { get }
    var shareNeedsNetwork: String { get }
    var shareNote: String { get }
    var publicLink: String { get }
    var publicLinkHint: String { get }
    var newPasswordPlaceholder: String { get }
    var generate: String { get }
    var passwordMin6: String { get }
    var createLink: String { get }
    var legacyShare: String { get }
    var needPassword: String { get }
    var copyLink: String { get }
    var shareExpired: String { get }
    var accessPassword: String { get }
    var passwordSet: String { get }
    var copyPassword: String { get }
    var change: String { get }
    var copyLinkAndPassword: String { get }
    var sendViaApp: String { get }
    var expires: String { get }
    func keepCurrent(_ date: String) -> String
    var neverExpires: String { get }
    func days(_ n: Int) -> String
    var views: String { get }
    func timesCount(_ n: Int) -> String
    var copyRich: String { get }
    var copyMarkdown: String { get }
    var exportMd: String { get }
    var copyOrExport: String { get }
    var copyAsOffline: String { get }
    var copyAsHint: String { get }
    func shareMessage(_ title: String, _ link: String, _ password: String) -> String

    // Media
    var mediaLibrary: String { get }
    var searchFiles: String { get }
    var mediaOffline: String { get }
    var reviewAndClean: String { get }
    var mediaTrashEmpty: String { get }
    var noFiles: String { get }
    var noMatchingFiles: String { get }
    var noFilesHint: String { get }
    func waitingUploads(_ n: Int) -> String
    func notUploaded(_ error: String) -> String
    var savedOnDevice: String { get }
    var uploadsWhenOnline: String { get }
    var retryUpload: String { get }
    var upload: String { get }
    var uploadFiles: String { get }
    func orphanBanner(_ n: Int, _ days: Int) -> String
    func orphanBannerNoDays(_ n: Int) -> String
    var savedLocallyUploadLater: String { get }
    var duplicateMerged: String { get }
    func usedIn(_ n: Int) -> String
    func cleanupIn(_ days: Int) -> String
    var unreferenced: String { get }
    var type: String { get }
    var storage: String { get }
    var storageS3CDN: String { get }
    var storageS3: String { get }
    var storageDisk: String { get }
    var fingerprint: String { get }
    var localReference: String { get }
    var publicUrl: String { get }
    var uploadedAt: String { get }
    var trashedAt: String { get }
    var fileNotFound: String { get }
    var renameFile: String { get }
    var fileName: String { get }
    var purgeFileTitle: String { get }
    var purgeFileMessage: String { get }
    var preview: String { get }
    var copyPublicUrl: String { get }
    var makePublicUrl: String { get }
    var revokePublicUrl: String { get }
    var publicFilesHint: String { get }
    var copyReference: String { get }
    var downloadOriginal: String { get }
    func referencedBy(_ n: Int) -> String
    var publicUrlCopied: String { get }
    var filterAll: String { get }
    var filterImages: String { get }
    var filterVideo: String { get }
    var filterAudio: String { get }
    var filterFiles: String { get }

    // Attachment cache
    var attachmentCache: String { get }
    var localFirstCache: String { get }
    var localFirstCacheHint: String { get }
    var cacheLimit: String { get }
    var cacheUnlimited: String { get }
    var cacheUsage: String { get }
    func cacheFilesCount(_ n: Int) -> String
    var clearCache: String { get }
    var cacheCleared: String { get }
    func cachePendingNote(_ n: Int) -> String
    var cacheSettings: String { get }

    // Sign in
    var cannotConnect: String { get }
    var register: String { get }
    var login: String { get }
    var promoteNote: String { get }
    var signInTitle: String { get }
    var turnOnSyncTitle: String { get }
    func officialRegion(_ region: String) -> String
    var regionCn: String { get }
    var regionGlobal: String { get }
    var customServerEllipsis: String { get }
    var syncNode: String { get }
    var nodeUnreachable: String { get }
    var signInHint: String { get }
    func promoteHint(_ name: String) -> String
    var usernameOrEmail: String { get }
    var emailOptional: String { get }
    var displayNameOptional: String { get }
    var password: String { get }
    var passwordMin8: String { get }
    var firstAdmin: String { get }
    var registrationClosed: String { get }
    var continueMigration: String { get }
    var registerAndSync: String { get }
    var wrongCredentials: String { get }
    func migrationRejected(_ n: Int) -> String
    func migrationInterrupted(_ error: String) -> String
    var preparing: String { get }
    func uploadingFiles(_ done: Int, _ total: Int) -> String
    func uploadingNotes(_ done: Int, _ total: Int) -> String
    var migrationDone: String { get }
    var serverAddress: String { get }
    var insecureWarning: String { get }
    var customServerHint: String { get }
    var useServer: String { get }
    var customServer: String { get }
    var createAccount: String { get }

    // Errors and checks
    func unreachable(_ detail: String) -> String
    var notIvynote: String { get }
    var tooManyAttempts: String { get }
    func serverUnavailable(_ status: Int) -> String
    func requestFailedStatus(_ status: Int) -> String
    var accountNotEmpty: String { get }
    var accountUnavailable: String { get }
    var sessionExpired: String { get }
    var usernameRule: String { get }
    var passwordTooShort: String { get }
    var passwordTooLong: String { get }
    var serverEmpty: String { get }
    var serverInvalid: String { get }
    func unsupportedScheme(_ scheme: String) -> String
    func insecureRemote(_ host: String) -> String

    // Dates, reminders and protected notes (guide 8.4, 9.4, 11.8)
    var agenda: String { get }
    var agendaEmpty: String { get }
    var agendaEmptyHint: String { get }
    var agendaProtectedHint: String { get }
    var agendaOverdue: String { get }
    var agendaToday: String { get }
    var agendaLater: String { get }
    var dateAndReminder: String { get }
    var formatInsert: String { get }
    var protectNote: String { get }
    var changeNotePassword: String { get }
    var removeNotePassword: String { get }
    var lockNoteNow: String { get }
    var protectedNote: String { get }
    func reminderFrom(_ title: String) -> String
    func daysLeft(_ days: Int) -> String
    /// A day branch of the agenda: 今天 · 11月9日 周一, 11月12日 周三.
    func agendaDay(_ day: Tasks.Due, today: Tasks.Due) -> String
    /// A month branch: 本月稍后, 12月, 2027年1月.
    func agendaMonth(_ month: Tasks.Due, today: Tasks.Due) -> String
}

public struct ZhStrings: Strings {
    public init() {}
    public var locale: Locale { Locale(identifier: "zh-Hans") }

    // Common
    public let appName = "常青笔记"
    public let slogan = "本地优先的 Markdown 笔记"
    public let name = "名称"
    public let save = "保存"
    public let cancel = "取消"
    public let create = "创建"
    public let delete = "删除"
    public let remove = "移除"
    public let rename = "重命名"
    public let open = "打开"
    public let retry = "重试"
    public let done = "完成"
    public let close = "关闭"
    public let more = "更多"
    public let ok = "好"
    public let error = "出错了"
    public let copied = "已复制"
    public let restore = "恢复"
    public let deleteForever = "永久删除"
    public let moveToTrash = "移到回收站"
    public let untitled = "无标题"
    public let note = "笔记"
    public let notes = "笔记"
    public let tags = "标签"
    public let trash = "回收站"
    public let pinned = "置顶"
    public let pin = "置顶"
    public let unpin = "取消置顶"
    public let cannotReadFile = "无法读取文件"
    public func cannotReadNamedFile(_ name: String) -> String { "\(name)：无法读取文件" }
    public func keychainError(_ detail: String) -> String { "钥匙串错误：\(detail)" }

    // Language
    public let language = "语言 · Language"
    public func followSystem(_ language: String) -> String { "跟随系统（\(language)）" }
    public let languageAccountHint = "保存在你的账户中，在登录这个账户的所有设备上生效。"
    public let languageDeviceHint = "只对这台设备生效。登录同步账户后，以账户的语言设置为准。"

    // Dates
    public func yesterday(_ time: String) -> String { "昨天 \(time)" }

    // Sync status (guide 11.7)
    public let localUnsynced = "仅保存在本机 · 未同步"
    public let downloadingNotes = "正在下载笔记…"
    public let syncing = "同步中…"
    public let offline = "离线"
    public func offlinePending(_ n: Int) -> String { "离线 · \(n) 条待同步" }
    public let syncError = "同步出错"
    public func pending(_ n: Int) -> String { "\(n) 条待同步" }
    public func synced(_ ago: String) -> String { "已同步 · \(ago)" }
    public let neverSynced = "尚未同步"
    public func blocked(_ n: Int) -> String { "\(n) 条更改被服务器拒绝" }
    public func uploadsPending(_ n: Int) -> String { "\(n) 个文件待上传" }

    // Libraries
    public let libraries = "笔记库"
    public let welcome = "本地优先的 Markdown 笔记，在手机、电脑和网页间同步。"
    public let pickLibrary = "选择要打开的笔记库"
    public let connect = "登录云同步账户"
    public let connectHint = "在多台设备间同步，支持官方节点和自建服务器"
    public let newLocal = "新建本地笔记库"
    public let newLocalHint = "只保存在这台设备，无需账户，立即可用"
    public let newLocalMessage = "笔记只保存在这台设备上，不会同步。"
    public let canConvert = "本地笔记库可以随时开启同步：注册新账户后，内容会自动上传。"
    public let startCloud = "开始使用 · 多端同步"
    public let startCloudHint = "登录或注册，笔记在手机、电脑和网页间自动同步"
    public let localOnly = "不登录，仅在本机使用"
    public let defaultLibraryName = "我的笔记"
    public let renameLibrary = "重命名笔记库"
    public let removeLibrary = "移除笔记库"
    public func removeNamed(_ name: String) -> String { "移除「\(name)」" }
    public func removeLocalMessage(_ name: String) -> String { "将永久删除「\(name)」里的全部笔记，无法恢复。" }
    public func removeServerMessage(_ name: String) -> String { "将从这台设备删除「\(name)」的本地副本和登录状态。服务器上的笔记不受影响，但尚未同步的更改会丢失。" }
    public let turnOnSync = "开启同步"
    public let migratedHint = "已迁移到云端，确认无误后可以移除"
    public let cannotOpenData = "无法打开本地数据"
    public let backToLibraries = "返回笔记库列表"

    // Account
    public let account = "账户"
    public let user = "用户"
    public let username = "用户名"
    public let email = "邮箱"
    public let role = "角色"
    public let admin = "管理员"
    public func syncSection(_ library: String) -> String { "同步 · \(library)" }
    public let server = "服务器"
    public let status = "状态"
    public let thisDevice = "本设备"
    public let syncNow = "立即同步"
    public let openAdmin = "打开管理后台"
    public let signOut = "退出登录"
    public let signOutTitle = "退出登录？"
    public let signOutHint = "退出后，本设备上这个笔记库的副本会被删除；服务器上的数据不受影响。重新登录后会再次下载。"
    public func signOutUnsynced(_ n: Int) -> String { "还有 \(n) 条更改没有同步到服务器，退出后会丢失。" }
    public let signOutMessage = "这台设备的登录令牌会被撤销，本地数据会被删除。"

    // Library and shelf
    public let noNoteSelected = "未选择笔记"
    public let uploadFailedTitle = "文件未能上传"
    public func uploadRefused(_ name: String, _ message: String) -> String { "「\(name)」被服务器拒绝：\(message)。它会留在本机，下次启动时再试；其他内容照常同步。" }
    public let conflictTitle = "内容冲突"
    public func conflictMessage(_ title: String) -> String { "「\(title)」在其他设备上也改动了同一处。服务器保留了它的版本，你的修改已另存为冲突副本。" }
    public let openCopy = "打开副本"
    public let searchNotes = "搜索笔记"
    public let newNote = "新建笔记"
    public let newFolder = "新建笔记本"
    public let newSubfolder = "新建子笔记本"
    public let renameFolder = "重命名笔记本"
    public let deleteFolderTitle = "删除笔记本？"
    public func deleteNamed(_ name: String) -> String { "删除「\(name)」" }
    public let deleteFolderMessage = "子笔记本会一起删除，其中的笔记移到回收站。"
    public let emptyTrashTitle = "永久删除回收站中的全部笔记？"
    public let emptyTrash = "清空回收站"
    public let cannotUndo = "此操作无法撤销。"
    public let editTagEllipsis = "编辑标签…"
    public let collapsePinned = "收起置顶"
    public let expandPinned = "展开置顶"
    public let sort = "排序"
    public let sortUpdated = "更新时间"
    public let sortCreated = "创建时间"
    public let sortTitle = "标题"
    public func showMore(_ next: Int, _ hidden: Int) -> String { "再显示 \(next) 篇（共 \(hidden) 篇未显示）" }
    public let moveTo = "移动到"
    public let noNotebook = "无笔记本"
    public let mediaLibraryEllipsis = "媒体库…"
    public let accountAndSync = "账户与同步…"
    public let turnOnSyncEllipsis = "开启多端同步…"
    public let manageLibraries = "管理笔记库…"
    public let switchLibrary = "切换笔记库"
    public func libraryLabel(_ name: String) -> String { "笔记库：\(name)" }

    // Note
    public let noteInTrash = "这篇笔记在回收站中"
    public let renameNote = "重命名笔记"
    public let share = "分享"
    public let shareAndExport = "分享与导出"
    public let history = "历史版本"
    public let showOutline = "显示大纲"
    public let hideOutline = "隐藏大纲"
    public let outline = "大纲"
    public let noHeadings = "还没有标题"
    public let noHeadingsHint = "以 # 开头的行会出现在这里。"
    public let formatHeading = "标题"
    public let formatBold = "加粗"
    public let formatItalic = "斜体"
    public let formatTask = "待办"
    public let formatList = "列表"
    public let formatOrdered = "编号"
    public let formatQuote = "引用"
    public let formatCode = "代码"
    public let formatWikiLink = "双链"
    public let formatLink = "链接"
    public let formatStrike = "删除线"
    public let photo = "图片"
    public let camera = "拍照"
    public let attachment = "附件"
    public let undo = "撤销"
    public let hideKeyboard = "收起键盘"
    public func words(_ n: String) -> String { "\(n) 字" }
    public let uploading = "上传中"
    public let backlinks = "反向链接"
    public func backlinksCount(_ n: Int) -> String { "\(n) 条反向链接" }

    // Attachments
    public let insertAttachment = "插入附件"
    public let insertAttachmentHelp = "插入图片或文件"
    public let photoOrVideo = "照片或视频"
    public let file = "文件"
    public func savedLocally(_ name: String) -> String { "「\(name)」已保存在本机，联网后自动上传" }
    public func uploadFailed(_ name: String, _ error: String) -> String { "「\(name)」上传失败：\(error)" }
    public let fileTooLarge = "文件超过服务器的上传上限"
    public let localNoServer = "本地笔记库没有服务器"

    // Tags
    public func tagColor(_ color: String) -> String {
        switch color {
        case "green": "绿色"
        case "blue": "蓝色"
        case "amber": "琥珀"
        case "pink": "粉色"
        case "purple": "紫色"
        case "gray": "灰色"
        default: "自动"
        }
    }
    public let removeFromNote = "从笔记移除"
    public let addTag = "添加标签"
    public func createTag(_ name: String) -> String { "创建「\(name)」" }
    public func maxTags(_ n: Int) -> String { "一篇笔记最多 \(n) 个标签" }
    public let noTags = "还没有标签"
    public let noTagsHint = "输入名称创建第一个标签。"
    public let searchOrCreateTag = "搜索或创建标签"
    public let tagName = "标签名"
    public let color = "颜色"
    public let deleteTag = "删除标签"
    public func deleteTagMessage(_ n: Int) -> String { "标签会从 \(n) 篇笔记上移除，笔记本身不受影响。" }
    public let editTag = "编辑标签"
    public func deleteTagTitle(_ name: String) -> String { "删除标签「\(name)」？" }
    public let nameEmpty = "名称不能为空"
    public let nameTooLong = "最多 50 个字符"
    public let tagExists = "已有同名标签"

    // History
    public let show = "显示"
    public let rendered = "渲染"
    public let source = "源码"
    public let restoreVersion = "恢复此版本"
    public let localNoHistory = "本地笔记库没有历史版本"
    public let localNoHistoryHint = "历史版本保存在服务器上，开启同步后可用。"
    public let historyLoadFailed = "无法读取历史版本"
    public let noHistory = "暂无历史版本"
    public let noHistoryHint = "同步后的每次修改都会留下一个版本。"
    public let currentVersion = "当前版本"
    public func restorePrompt(_ time: String) -> String { "将笔记恢复为 \(time) 的版本？当前内容会保留在历史中。" }

    // Sharing
    public let localNoShare = "本地笔记库没有服务器，不能生成公开链接。开启多端同步后可以分享。"
    public let shareNeedsNetwork = "分享链接需要联网。"
    public let shareNote = "分享笔记"
    public let publicLink = "公开链接"
    public let publicLinkHint = "拿到链接和访问密码的人可以阅读这篇笔记"
    public let newPasswordPlaceholder = "新密码（至少 6 位）"
    public let generate = "随机生成"
    public let passwordMin6 = "密码至少 6 位"
    public let createLink = "生成链接"
    public let legacyShare = "这个链接是在要求密码之前创建的，设置密码后才能继续访问。"
    public let needPassword = "为保护你的隐私，公开链接必须设置至少 6 位的访问密码。"
    public let copyLink = "复制链接"
    public let shareExpired = "分享已过期"
    public let accessPassword = "访问密码"
    public let passwordSet = "已设置访问密码"
    public let copyPassword = "复制密码"
    public let change = "修改"
    public let copyLinkAndPassword = "复制链接和密码"
    public let sendViaApp = "通过其他应用发送…"
    public let expires = "有效期"
    public func keepCurrent(_ date: String) -> String { "保持当前（\(date)）" }
    public let neverExpires = "永久有效"
    public func days(_ n: Int) -> String { "\(n) 天" }
    public let views = "访问次数"
    public func timesCount(_ n: Int) -> String { "\(n) 次" }
    public let copyRich = "复制富文本"
    public let copyMarkdown = "复制 Markdown"
    public let exportMd = "导出 .md 文件"
    public let copyOrExport = "复制或导出"
    public let copyAsOffline = "离线时附件不会替换为公网链接。"
    public let copyAsHint = "附件会自动公开并替换为公网链接，方便粘贴到博客、公众号等地方。"
    public func shareMessage(_ title: String, _ link: String, _ password: String) -> String { "\(title)\n链接：\(link)\n密码：\(password)" }

    // Media
    public let mediaLibrary = "媒体库"
    public let searchFiles = "搜索文件名"
    public let mediaOffline = "离线 · 显示已同步的文件信息"
    public let reviewAndClean = "查看并清理"
    public let mediaTrashEmpty = "回收站是空的"
    public let noFiles = "还没有文件"
    public let noMatchingFiles = "没有匹配的文件"
    public let noFilesHint = "在笔记中插入图片或文件，就会出现在这里。"
    public func waitingUploads(_ n: Int) -> String { "等待上传 \(n)" }
    public func notUploaded(_ error: String) -> String { "未能上传：\(error)" }
    public let savedOnDevice = "保存在本机"
    public let uploadsWhenOnline = "联网后自动上传"
    public let retryUpload = "重新上传"
    public let upload = "上传"
    public let uploadFiles = "上传文件"
    public func orphanBanner(_ n: Int, _ days: Int) -> String { "\(n) 个文件没有被任何笔记引用，将在 \(days) 天后自动移入回收站。" }
    public func orphanBannerNoDays(_ n: Int) -> String { "\(n) 个文件没有被任何笔记引用。" }
    public let savedLocallyUploadLater = "已保存在本机，联网后自动上传"
    public let duplicateMerged = "重复文件已合并"
    public func usedIn(_ n: Int) -> String { "被 \(n) 篇引用" }
    public func cleanupIn(_ days: Int) -> String { "未引用 · \(days) 天后清理" }
    public let unreferenced = "未引用"
    public let type = "类型"
    public let storage = "存储"
    public let storageS3CDN = "S3 · 已开启 CDN · 已加密"
    public let storageS3 = "S3 · 已加密"
    public let storageDisk = "服务器磁盘 · 已加密"
    public let fingerprint = "指纹"
    public let localReference = "本地引用"
    public let publicUrl = "公网链接"
    public let uploadedAt = "上传于"
    public let trashedAt = "移入回收站"
    public let fileNotFound = "文件不存在"
    public let renameFile = "重命名文件"
    public let fileName = "文件名"
    public let purgeFileTitle = "永久删除这个文件？"
    public let purgeFileMessage = "引用它的笔记将无法显示它。此操作无法撤销。"
    public let preview = "预览"
    public let copyPublicUrl = "复制公网链接"
    public let makePublicUrl = "生成公网链接"
    public let revokePublicUrl = "撤销公网链接"
    public let publicFilesHint = "公网链接不再受登录保护，任何拿到地址的人都能打开这个文件。"
    public let copyReference = "复制引用"
    public let downloadOriginal = "下载原文件"
    public func referencedBy(_ n: Int) -> String { "被 \(n) 篇笔记引用" }
    public let publicUrlCopied = "公网链接已复制"
    public let filterAll = "全部"
    public let filterImages = "图片"
    public let filterVideo = "视频"
    public let filterAudio = "音频"
    public let filterFiles = "文件"

    // Attachment cache
    public let attachmentCache = "附件缓存"
    public let localFirstCache = "本地优先缓存"
    public let localFirstCacheHint = "优先从本地附件库读取并缓存已同步附件，达到上限时按访问频率与时间自动清理最冷的文件；待上传文件不会被清理。"
    public let cacheLimit = "缓存上限"
    public let cacheUnlimited = "不限制"
    public let cacheUsage = "当前占用"
    public func cacheFilesCount(_ n: Int) -> String { "\(n) 个文件" }
    public let clearCache = "清理附件缓存"
    public let cacheCleared = "附件缓存已清理"
    public func cachePendingNote(_ n: Int) -> String { "另有 \(n) 个待上传文件保留在本地" }
    public let cacheSettings = "缓存管理"

    // Sign in
    public let cannotConnect = "无法连接服务器"
    public let register = "注册"
    public let login = "登录"
    public let promoteNote = "本地笔记库只能迁移到新注册的账户。已有账户的话，可以先登录，再在网页版或桌面端的「设置 → 导入」中导入本笔记库导出的内容。"
    public let signInTitle = "登录常青笔记"
    public let turnOnSyncTitle = "开启多端同步"
    public func officialRegion(_ region: String) -> String { "常青笔记 · \(region)" }
    public let regionCn = "中国大陆"
    public let regionGlobal = "全球"
    public let customServerEllipsis = "自定义服务器…"
    public let syncNode = "同步节点"
    public let nodeUnreachable = "暂时无法连接这个节点"
    public let signInHint = "笔记先保存在本机，联网时自动同步到你的所有设备。"
    public func promoteHint(_ name: String) -> String { "注册一个新账户，「\(name)」会上传到云端，之后在所有设备上同步。" }
    public let usernameOrEmail = "用户名或邮箱"
    public let emailOptional = "邮箱（可选）"
    public let displayNameOptional = "显示名（可选）"
    public let password = "密码"
    public let passwordMin8 = "密码（至少 8 位）"
    public let firstAdmin = "这台服务器还没有账户。你创建的第一个账户将成为管理员。"
    public let registrationClosed = "这台服务器没有开放注册。"
    public let continueMigration = "继续迁移"
    public let registerAndSync = "注册并开启同步"
    public let wrongCredentials = "用户名或密码错误"
    public func migrationRejected(_ n: Int) -> String { "\(n) 项未能迁移，原内容仍保留在本地笔记库中。" }
    public func migrationInterrupted(_ error: String) -> String { "迁移中断：\(error)。账户已经创建，点「继续迁移」会从中断处继续，已上传的内容不会重复。" }
    public let preparing = "正在准备…"
    public func uploadingFiles(_ done: Int, _ total: Int) -> String { "正在上传附件 \(done)/\(total)" }
    public func uploadingNotes(_ done: Int, _ total: Int) -> String { "正在上传笔记 \(done)/\(total)" }
    public let migrationDone = "迁移完成，正在打开…"
    public let serverAddress = "服务器地址"
    public let insecureWarning = "使用 http 连接时，密码和笔记以明文传输，请只在可信的局域网内使用。"
    public let customServerHint = "连接你自己或团队部署的常青笔记服务器。"
    public let useServer = "使用这个服务器"
    public let customServer = "自定义服务器"
    public let createAccount = "创建账户"

    // Errors and checks
    public func unreachable(_ detail: String) -> String { "无法连接服务器：\(detail)" }
    public let notIvynote = "这个地址不是常青笔记服务器"
    public let tooManyAttempts = "尝试次数过多，请 15 分钟后再试"
    public func serverUnavailable(_ status: Int) -> String { "服务器暂时不可用（\(status)）" }
    public func requestFailedStatus(_ status: Int) -> String { "请求失败（\(status)）" }
    public let accountNotEmpty = "这个账户里已经有笔记。本地笔记库只能迁移到新注册的空账户。"
    public let accountUnavailable = "账户不可用"
    public let sessionExpired = "登录已过期，请重新登录"
    public let usernameRule = "用户名为 2–32 位字母、数字、_ . -，以字母或数字开头"
    public let passwordTooShort = "密码至少 8 个字符"
    public let passwordTooLong = "密码最多 72 字节"
    public let serverEmpty = "请填写服务器地址"
    public let serverInvalid = "服务器地址无效"
    public func unsupportedScheme(_ scheme: String) -> String { "不支持的协议：\(scheme)" }
    public func insecureRemote(_ host: String) -> String { "\(host) 不是局域网地址，必须使用 https://" }

    public let agenda = "日程"
    public let agendaEmpty = "还没有带日期的待办"
    public let agendaEmptyHint = "在待办后输入 @明天 9点、@周五，或点格式栏的日期按钮。选好日期就会出现在这里，到点提醒。"
    public let agendaProtectedHint = "加密笔记中的待办不会出现在日程里。"
    public let agendaOverdue = "已逾期"
    public let agendaToday = "今天"
    public let agendaLater = "接下来"
    public let dateAndReminder = "日期与提醒"
    public let formatInsert = "插入"
    public let protectNote = "设置密码…"
    public let changeNotePassword = "更改密码…"
    public let removeNotePassword = "移除密码"
    public let lockNoteNow = "立即锁定"
    public let protectedNote = "已加密"
    public func reminderFrom(_ title: String) -> String { "来自《\(title)》" }
    public func agendaDay(_ day: Tasks.Due, today: Tasks.Due) -> String {
        let wd = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][agendaWeekday(day)]
        let text = (day.year == today.year ? "" : "\(day.year)年") + "\(day.month)月\(day.day)日 \(wd)"
        switch agendaDaysBetween(today, day) {
        case 0: return "今天 · " + text
        case 1: return "明天 · " + text
        default: return text
        }
    }
    public func agendaMonth(_ month: Tasks.Due, today: Tasks.Due) -> String {
        if month.year == today.year && month.month == today.month { return "本月稍后" }
        return month.year == today.year ? "\(month.month)月" : "\(month.year)年\(month.month)月"
    }
    public func daysLeft(_ days: Int) -> String {
        days == 0 ? "今天" : days > 0 ? "\(days) 天后" : "逾期 \(-days) 天"
    }
}

public struct EnStrings: Strings {
    public init() {}
    public var locale: Locale { Locale(identifier: "en") }

    /// "1 note", "2 notes".
    private func count(_ n: Int, _ one: String) -> String { "\(n) \(n == 1 ? one : one + "s")" }

    // Common
    public let appName = "Ivynote"
    public let slogan = "Local-first Markdown notes"
    public let name = "Name"
    public let save = "Save"
    public let cancel = "Cancel"
    public let create = "Create"
    public let delete = "Delete"
    public let remove = "Remove"
    public let rename = "Rename"
    public let open = "Open"
    public let retry = "Retry"
    public let done = "Done"
    public let close = "Close"
    public let more = "More"
    public let ok = "OK"
    public let error = "Something went wrong"
    public let copied = "Copied"
    public let restore = "Restore"
    public let deleteForever = "Delete forever"
    public let moveToTrash = "Move to trash"
    public let untitled = "Untitled"
    public let note = "Note"
    public let notes = "Notes"
    public let tags = "Tags"
    public let trash = "Trash"
    public let pinned = "Pinned"
    public let pin = "Pin"
    public let unpin = "Unpin"
    public let cannotReadFile = "Could not read the file"
    public func cannotReadNamedFile(_ name: String) -> String { "\(name): could not read the file" }
    public func keychainError(_ detail: String) -> String { "Keychain error: \(detail)" }

    // Language
    public let language = "Language · 语言"
    public func followSystem(_ language: String) -> String { "System default (\(language))" }
    public let languageAccountHint = "Saved in your account, on every device signed in to it."
    public let languageDeviceHint = "For this device only. Once you sign in to a synced account, the account’s language applies."

    // Dates
    public func yesterday(_ time: String) -> String { "Yesterday \(time)" }

    // Sync status (guide 11.7)
    public let localUnsynced = "On this device only · not synced"
    public let downloadingNotes = "Downloading notes…"
    public let syncing = "Syncing…"
    public let offline = "Offline"
    public func offlinePending(_ n: Int) -> String { "Offline · \(count(n, "change")) to sync" }
    public let syncError = "Sync error"
    public func pending(_ n: Int) -> String { "\(count(n, "change")) to sync" }
    public func synced(_ ago: String) -> String { "Synced · \(ago)" }
    public let neverSynced = "Not synced yet"
    public func blocked(_ n: Int) -> String { "\(count(n, "change")) refused by the server" }
    public func uploadsPending(_ n: Int) -> String { "\(count(n, "file")) to upload" }

    // Libraries
    public let libraries = "Libraries"
    public let welcome = "Local-first Markdown notes that sync across your phone, computer and the web."
    public let pickLibrary = "Pick a library to open"
    public let connect = "Sign in to sync"
    public let connectHint = "Sync across devices, on the official service or your own server"
    public let newLocal = "New local library"
    public let newLocalHint = "Stays on this device, no account, ready right away"
    public let newLocalMessage = "Notes stay on this device and do not sync."
    public let canConvert = "A local library can turn on sync at any time: create an account and its content is uploaded."
    public let startCloud = "Get started · Sync everywhere"
    public let startCloudHint = "Sign in or sign up; notes sync across your phone, computer and the web"
    public let localOnly = "Use on this device only, without an account"
    public let defaultLibraryName = "My notes"
    public let renameLibrary = "Rename library"
    public let removeLibrary = "Remove library"
    public func removeNamed(_ name: String) -> String { "Remove “\(name)”" }
    public func removeLocalMessage(_ name: String) -> String { "All notes in “\(name)” will be deleted for good. This cannot be undone." }
    public func removeServerMessage(_ name: String) -> String { "The copy of “\(name)” on this device and its sign-in will be removed. Notes on the server are not affected, but changes not synced yet are lost." }
    public let turnOnSync = "Turn on sync"
    public let migratedHint = "Moved to the cloud; remove it once you have checked"
    public let cannotOpenData = "Could not open the local data"
    public let backToLibraries = "Back to libraries"

    // Account
    public let account = "Account"
    public let user = "User"
    public let username = "Username"
    public let email = "Email"
    public let role = "Role"
    public let admin = "Admin"
    public func syncSection(_ library: String) -> String { "Sync · \(library)" }
    public let server = "Server"
    public let status = "Status"
    public let thisDevice = "This device"
    public let syncNow = "Sync now"
    public let openAdmin = "Open admin console"
    public let signOut = "Sign out"
    public let signOutTitle = "Sign out?"
    public let signOutHint = "Signing out deletes this library’s copy on this device; the data on the server is not affected and downloads again when you sign back in."
    public func signOutUnsynced(_ n: Int) -> String { "\(count(n, "change")) not synced to the server yet will be lost." }
    public let signOutMessage = "This device’s sign-in token is revoked and the local data deleted."

    // Library and shelf
    public let noNoteSelected = "No note selected"
    public let uploadFailedTitle = "A file could not be uploaded"
    public func uploadRefused(_ name: String, _ message: String) -> String { "The server refused “\(name)”: \(message). It stays on this device and is tried again next launch; everything else keeps syncing." }
    public let conflictTitle = "Conflict"
    public func conflictMessage(_ title: String) -> String { "“\(title)” was changed in the same place on another device. The server kept that version; your edit was saved as a conflict copy." }
    public let openCopy = "Open copy"
    public let searchNotes = "Search notes"
    public let newNote = "New note"
    public let newFolder = "New notebook"
    public let newSubfolder = "New sub-notebook"
    public let renameFolder = "Rename notebook"
    public let deleteFolderTitle = "Delete notebook?"
    public func deleteNamed(_ name: String) -> String { "Delete “\(name)”" }
    public let deleteFolderMessage = "Its sub-notebooks are deleted too; its notes go to the trash."
    public let emptyTrashTitle = "Delete all notes in the trash for good?"
    public let emptyTrash = "Empty trash"
    public let cannotUndo = "This cannot be undone."
    public let editTagEllipsis = "Edit tag…"
    public let collapsePinned = "Collapse pinned"
    public let expandPinned = "Expand pinned"
    public let sort = "Sort"
    public let sortUpdated = "Last updated"
    public let sortCreated = "Date created"
    public let sortTitle = "Title"
    public func showMore(_ next: Int, _ hidden: Int) -> String { "Show \(next) more (\(hidden) not shown)" }
    public let moveTo = "Move to"
    public let noNotebook = "No notebook"
    public let mediaLibraryEllipsis = "Media library…"
    public let accountAndSync = "Account and sync…"
    public let turnOnSyncEllipsis = "Turn on sync…"
    public let manageLibraries = "Manage libraries…"
    public let switchLibrary = "Switch library"
    public func libraryLabel(_ name: String) -> String { "Library: \(name)" }

    // Note
    public let noteInTrash = "This note is in the trash"
    public let renameNote = "Rename note"
    public let share = "Share"
    public let shareAndExport = "Share and export"
    public let history = "History"
    public let showOutline = "Show outline"
    public let hideOutline = "Hide outline"
    public let outline = "Outline"
    public let noHeadings = "No headings yet"
    public let noHeadingsHint = "Lines starting with # show up here."
    public let formatHeading = "Heading"
    public let formatBold = "Bold"
    public let formatItalic = "Italic"
    public let formatTask = "Task"
    public let formatList = "List"
    public let formatOrdered = "Numbered list"
    public let formatQuote = "Quote"
    public let formatCode = "Code"
    public let formatWikiLink = "Wiki link"
    public let formatLink = "Link"
    public let formatStrike = "Strikethrough"
    public let photo = "Photo"
    public let camera = "Take photo"
    public let attachment = "Attachment"
    public let undo = "Undo"
    public let hideKeyboard = "Hide keyboard"
    public func words(_ n: String) -> String { "\(n) words" }
    public let uploading = "Uploading"
    public let backlinks = "Backlinks"
    public func backlinksCount(_ n: Int) -> String { "\(count(n, "backlink"))" }

    // Attachments
    public let insertAttachment = "Insert attachment"
    public let insertAttachmentHelp = "Insert an image or file"
    public let photoOrVideo = "Photo or video"
    public let file = "File"
    public func savedLocally(_ name: String) -> String { "“\(name)” is saved on this device and uploads once you are online" }
    public func uploadFailed(_ name: String, _ error: String) -> String { "Could not upload “\(name)”: \(error)" }
    public let fileTooLarge = "The file is larger than the server allows"
    public let localNoServer = "Local libraries have no server"

    // Tags
    public func tagColor(_ color: String) -> String {
        switch color {
        case "green": "Green"
        case "blue": "Blue"
        case "amber": "Amber"
        case "pink": "Pink"
        case "purple": "Purple"
        case "gray": "Gray"
        default: "Automatic"
        }
    }
    public let removeFromNote = "Remove from note"
    public let addTag = "Add tag"
    public func createTag(_ name: String) -> String { "Create “\(name)”" }
    public func maxTags(_ n: Int) -> String { "A note can have at most \(n) tags" }
    public let noTags = "No tags yet"
    public let noTagsHint = "Type a name to create your first tag."
    public let searchOrCreateTag = "Search or create a tag"
    public let tagName = "Tag name"
    public let color = "Color"
    public let deleteTag = "Delete tag"
    public func deleteTagMessage(_ n: Int) -> String { "The tag is removed from \(count(n, "note")); the notes themselves are not affected." }
    public let editTag = "Edit tag"
    public func deleteTagTitle(_ name: String) -> String { "Delete tag “\(name)”?" }
    public let nameEmpty = "The name cannot be empty"
    public let nameTooLong = "At most 50 characters"
    public let tagExists = "A tag with this name exists"

    // History
    public let show = "Show"
    public let rendered = "Rendered"
    public let source = "Source"
    public let restoreVersion = "Restore this version"
    public let localNoHistory = "Local libraries have no history"
    public let localNoHistoryHint = "Saved versions are kept on the server; turn on sync to get them."
    public let historyLoadFailed = "Could not load the history"
    public let noHistory = "No saved versions yet"
    public let noHistoryHint = "Every change leaves a version once it syncs."
    public let currentVersion = "Current version"
    public func restorePrompt(_ time: String) -> String { "Restore the note to the version of \(time)? The current text stays in the history." }

    // Sharing
    public let localNoShare = "Local libraries have no server and cannot make public links. Turn on sync to share."
    public let shareNeedsNetwork = "Sharing needs a connection."
    public let shareNote = "Share note"
    public let publicLink = "Public link"
    public let publicLinkHint = "Anyone with the link and the password can read this note"
    public let newPasswordPlaceholder = "New password (6+ characters)"
    public let generate = "Generate"
    public let passwordMin6 = "At least 6 characters"
    public let createLink = "Create link"
    public let legacyShare = "This link was created before passwords were required. Set one to reopen it."
    public let needPassword = "To protect your privacy, a public link needs a password of at least 6 characters."
    public let copyLink = "Copy link"
    public let shareExpired = "This share has expired"
    public let accessPassword = "Password"
    public let passwordSet = "Password set"
    public let copyPassword = "Copy password"
    public let change = "Change"
    public let copyLinkAndPassword = "Copy link and password"
    public let sendViaApp = "Send with another app…"
    public let expires = "Expires"
    public func keepCurrent(_ date: String) -> String { "Keep (\(date))" }
    public let neverExpires = "Never"
    public func days(_ n: Int) -> String { "\(count(n, "day"))" }
    public let views = "Views"
    public func timesCount(_ n: Int) -> String { "\(n)" }
    public let copyRich = "Copy rich text"
    public let copyMarkdown = "Copy Markdown"
    public let exportMd = "Export .md file"
    public let copyOrExport = "Copy or export"
    public let copyAsOffline = "Offline, attachments are not replaced with public links."
    public let copyAsHint = "Attachments are made public and replaced with their public links, ready to paste into a blog or newsletter."
    public func shareMessage(_ title: String, _ link: String, _ password: String) -> String { "\(title)\nLink: \(link)\nPassword: \(password)" }

    // Media
    public let mediaLibrary = "Media library"
    public let searchFiles = "Search file names"
    public let mediaOffline = "Offline · showing synced file details"
    public let reviewAndClean = "Review and clean up"
    public let mediaTrashEmpty = "The trash is empty"
    public let noFiles = "No files yet"
    public let noMatchingFiles = "No matching files"
    public let noFilesHint = "Images and files added to notes show up here."
    public func waitingUploads(_ n: Int) -> String { "Waiting to upload: \(n)" }
    public func notUploaded(_ error: String) -> String { "Not uploaded: \(error)" }
    public let savedOnDevice = "Saved on this device"
    public let uploadsWhenOnline = "Uploads once online"
    public let retryUpload = "Upload again"
    public let upload = "Upload"
    public let uploadFiles = "Upload files"
    public func orphanBanner(_ n: Int, _ days: Int) -> String { "\(count(n, "file")) not used by any note will move to the trash in \(count(days, "day"))." }
    public func orphanBannerNoDays(_ n: Int) -> String { "\(count(n, "file")) not used by any note." }
    public let savedLocallyUploadLater = "Saved on this device; uploads once online"
    public let duplicateMerged = "Duplicate file merged"
    public func usedIn(_ n: Int) -> String { "In \(count(n, "note"))" }
    public func cleanupIn(_ days: Int) -> String { "Unused · cleaned up in \(count(days, "day"))" }
    public let unreferenced = "Unused"
    public let type = "Type"
    public let storage = "Storage"
    public let storageS3CDN = "S3 · CDN on · encrypted"
    public let storageS3 = "S3 · encrypted"
    public let storageDisk = "Server disk · encrypted"
    public let fingerprint = "Fingerprint"
    public let localReference = "Local reference"
    public let publicUrl = "Public link"
    public let uploadedAt = "Uploaded"
    public let trashedAt = "Moved to trash"
    public let fileNotFound = "File not found"
    public let renameFile = "Rename file"
    public let fileName = "File name"
    public let purgeFileTitle = "Delete this file forever?"
    public let purgeFileMessage = "Notes using it will no longer show it. This cannot be undone."
    public let preview = "Preview"
    public let copyPublicUrl = "Copy public link"
    public let makePublicUrl = "Make public link"
    public let revokePublicUrl = "Revoke public link"
    public let publicFilesHint = "A public link is not protected by sign-in: anyone with the address can open this file."
    public let copyReference = "Copy reference"
    public let downloadOriginal = "Download original"
    public func referencedBy(_ n: Int) -> String { "Used in \(count(n, "note"))" }
    public let publicUrlCopied = "Public link copied"
    public let filterAll = "All"
    public let filterImages = "Images"
    public let filterVideo = "Video"
    public let filterAudio = "Audio"
    public let filterFiles = "Files"

    // Attachment cache
    public let attachmentCache = "Attachment cache"
    public let localFirstCache = "Local-first cache"
    public let localFirstCacheHint = "Read attachments from the local store first and keep synced files cached up to the limit. Coldest files are evicted automatically; pending uploads are never evicted."
    public let cacheLimit = "Cache limit"
    public let cacheUnlimited = "Unlimited"
    public let cacheUsage = "Current usage"
    public func cacheFilesCount(_ n: Int) -> String { count(n, "file") }
    public let clearCache = "Clear attachment cache"
    public let cacheCleared = "Attachment cache cleared"
    public func cachePendingNote(_ n: Int) -> String { "\(count(n, "pending upload")) kept locally" }
    public let cacheSettings = "Cache settings"

    // Sign in
    public let cannotConnect = "Cannot reach the server"
    public let register = "Sign up"
    public let login = "Sign in"
    public let promoteNote = "A local library can only move to a newly created account. With an existing account, sign in and import this library’s export in Settings → Import on the web or desktop app."
    public let signInTitle = "Sign in to Ivynote"
    public let turnOnSyncTitle = "Turn on sync"
    public func officialRegion(_ region: String) -> String { "Ivynote · \(region)" }
    public let regionCn = "Mainland China"
    public let regionGlobal = "Global"
    public let customServerEllipsis = "Custom server…"
    public let syncNode = "Sync service"
    public let nodeUnreachable = "This service cannot be reached right now"
    public let signInHint = "Notes are saved on this device first and sync to all your devices when online."
    public func promoteHint(_ name: String) -> String { "Create a new account: “\(name)” is uploaded to the cloud and syncs on all your devices." }
    public let usernameOrEmail = "Username or email"
    public let emailOptional = "Email (optional)"
    public let displayNameOptional = "Display name (optional)"
    public let password = "Password"
    public let passwordMin8 = "Password (8+ characters)"
    public let firstAdmin = "This server has no accounts yet. The first account you create becomes its admin."
    public let registrationClosed = "This server does not accept sign-ups."
    public let continueMigration = "Continue"
    public let registerAndSync = "Sign up and turn on sync"
    public let wrongCredentials = "Wrong username or password"
    public func migrationRejected(_ n: Int) -> String { "\(count(n, "item")) could not be moved; the local library still has everything." }
    public func migrationInterrupted(_ error: String) -> String { "Moving stopped: \(error). The account exists; tap Continue to resume where it stopped, without uploading anything twice." }
    public let preparing = "Preparing…"
    public func uploadingFiles(_ done: Int, _ total: Int) -> String { "Uploading attachments \(done)/\(total)" }
    public func uploadingNotes(_ done: Int, _ total: Int) -> String { "Uploading notes \(done)/\(total)" }
    public let migrationDone = "Done, opening…"
    public let serverAddress = "Server address"
    public let insecureWarning = "Over http, passwords and notes travel unencrypted. Use it only on a local network you trust."
    public let customServerHint = "Connect to an Ivynote server you or your team run."
    public let useServer = "Use this server"
    public let customServer = "Custom server"
    public let createAccount = "Create account"

    // Errors and checks
    public func unreachable(_ detail: String) -> String { "Cannot reach the server: \(detail)" }
    public let notIvynote = "This address is not an Ivynote server"
    public let tooManyAttempts = "Too many attempts; try again in 15 minutes"
    public func serverUnavailable(_ status: Int) -> String { "The server is unavailable right now (\(status))" }
    public func requestFailedStatus(_ status: Int) -> String { "Request failed (\(status))" }
    public let accountNotEmpty = "This account already has notes. A local library can only move to a new, empty account."
    public let accountUnavailable = "This account is not available"
    public let sessionExpired = "Your session has expired; please sign in again"
    public let usernameRule = "Usernames have 2–32 letters, digits, _ . or -, starting with a letter or digit"
    public let passwordTooShort = "The password needs at least 8 characters"
    public let passwordTooLong = "The password can be at most 72 bytes"
    public let serverEmpty = "Enter the server address"
    public let serverInvalid = "The server address is not valid"
    public func unsupportedScheme(_ scheme: String) -> String { "Unsupported protocol: \(scheme)" }
    public func insecureRemote(_ host: String) -> String { "\(host) is not on the local network; use https://" }

    public let agenda = "Agenda"
    public let agendaEmpty = "No dated to-dos yet"
    public let agendaEmptyHint = "Type @tomorrow 9am or @fri after a to-do, or tap the date button in the format bar. Dated to-dos appear here and remind you when they are due."
    public let agendaProtectedHint = "To-dos in password-protected notes are not shown here."
    public let agendaOverdue = "Overdue"
    public let agendaToday = "Today"
    public let agendaLater = "Coming up"
    public let dateAndReminder = "Date & reminder"
    public let formatInsert = "Insert"
    public let protectNote = "Protect with password…"
    public let changeNotePassword = "Change password…"
    public let removeNotePassword = "Remove password"
    public let lockNoteNow = "Lock now"
    public let protectedNote = "Protected"
    public func reminderFrom(_ title: String) -> String { "From “\(title)”" }
    public func agendaDay(_ day: Tasks.Due, today: Tasks.Due) -> String {
        let wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][agendaWeekday(day)]
        let mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][max(0, min(11, day.month - 1))]
        let text = "\(wd), \(mon) \(day.day)" + (day.year == today.year ? "" : ", \(day.year)")
        switch agendaDaysBetween(today, day) {
        case 0: return "Today · " + text
        case 1: return "Tomorrow · " + text
        default: return text
        }
    }
    public func agendaMonth(_ month: Tasks.Due, today: Tasks.Due) -> String {
        if month.year == today.year && month.month == today.month { return "Later this month" }
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let name = names[max(0, min(11, month.month - 1))]
        return month.year == today.year ? name : "\(name) \(month.year)"
    }
    public func daysLeft(_ days: Int) -> String {
        if days == 0 { return "today" }
        if days > 0 { return days == 1 ? "in 1 day" : "in \(days) days" }
        return days == -1 ? "1 day overdue" : "\(-days) days overdue"
    }
}

/// Weekday of a date, 0 = Sunday, in the Gregorian calendar.
func agendaWeekday(_ d: Tasks.Due) -> Int {
    let cal = Calendar(identifier: .gregorian)
    guard let date = cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) else { return 0 }
    return cal.component(.weekday, from: date) - 1
}

/// Days from `a` to `b`.
func agendaDaysBetween(_ a: Tasks.Due, _ b: Tasks.Due) -> Int {
    let cal = Calendar(identifier: .gregorian)
    guard let x = cal.date(from: DateComponents(year: a.year, month: a.month, day: a.day)),
          let y = cal.date(from: DateComponents(year: b.year, month: b.month, day: b.day)) else { return 0 }
    return cal.dateComponents([.day], from: x, to: y).day ?? 0
}
