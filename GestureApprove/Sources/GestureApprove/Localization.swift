import Foundation

/// 轻量多语言：编译进字典，按系统语言选择，缺失回退英文。
/// 支持 6 种语言：en / zh-Hans / ja / ko / es / fr。
/// 因为本 app 是手动组装的 .app（非 Xcode 工程），用代码内字典比 .lproj 资源更省心。
enum I18n {
    /// 手动语言覆盖的存储键；值为语言代码或 "system"（跟随系统）。
    static let langKey = "appLanguage"
    /// 可选界面语言（首项 "system" 表示跟随系统）。
    static let supported = ["system", "en", "zh", "ja", "ko", "es", "fr"]

    /// 当前语言代码（"en"/"zh"/"ja"/"ko"/"es"/"fr"）。手动覆盖优先，否则跟随系统。
    /// 用计算属性而非常量：在设置里改语言后，新渲染的文案立即生效。
    static var lang: String { resolveLang() }

    private static func resolveLang() -> String {
        if let override = UserDefaults.standard.string(forKey: langKey),
           override != "system", supported.contains(override) {
            return override
        }
        for pref in Locale.preferredLanguages {
            let p = pref.lowercased()
            if p.hasPrefix("zh") { return "zh" }
            if p.hasPrefix("ja") { return "ja" }
            if p.hasPrefix("ko") { return "ko" }
            if p.hasPrefix("es") { return "es" }
            if p.hasPrefix("fr") { return "fr" }
            if p.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    static func string(_ key: String) -> String { string(key, lang: lang) }

    static func string(_ key: String, lang: String) -> String {
        guard let entry = table[key] else { return key }
        return entry[lang] ?? entry["en"] ?? key
    }

    /// Hub（网页 + HTTP API）只有 zh/en 两套文案，规则和页面里的
    /// `('__HUB_LANG__'||'en').startsWith('zh')?'zh':'en'` 完全一致。
    /// 日/韩/西/法语的用户看到的是英文页面，那么 API 的 reason 也该是英文 ——
    /// 母语句子嵌在英文页面里，比统一英文更难读。
    static var hubLang: String { lang.hasPrefix("zh") ? "zh" : "en" }
}

/// 取本地化文案的快捷函数。
func L(_ key: String) -> String { I18n.string(key) }
/// 只给 Hub（网页与 HTTP API）用：压到 zh/en，跟页面语言一致。
func LHub(_ key: String) -> String { I18n.string(key, lang: I18n.hubLang) }

private let table: [String: [String: String]] = [
    // MARK: 菜单
    "menu.running": [
        "en": "Gesture Approve · Running", "zh": "手势审批 · 运行中",
        "ja": "ジェスチャー承認 · 実行中", "ko": "제스처 승인 · 실행 중",
        "es": "Gesture Approve · En ejecución", "fr": "Gesture Approve · En cours",
    ],
    "menu.enable": [
        "en": "Enable approval gating", "zh": "启用审批拦截",
        "ja": "承認ゲートを有効化", "ko": "승인 게이트 사용",
        "es": "Activar control de aprobación", "fr": "Activer le contrôle d'approbation",
    ],
    "menu.bigMode": [
        "en": "Big mode (large card)", "zh": "大字模式（放大卡片）",
        "ja": "ビッグモード（拡大カード）", "ko": "빅 모드(카드 확대)",
        "es": "Modo grande (tarjeta ampliada)", "fr": "Mode grand (carte agrandie)",
    ],
    "menu.hub": [
        "en": "Remote Hub (sessions)", "zh": "远程 Hub(会话中枢)",
        "ja": "リモート Hub（セッション）", "ko": "원격 Hub(세션)",
        "es": "Hub remoto (sesiones)", "fr": "Hub distant (sessions)",
    ],
    "menu.hubConfig": [
        "en": "Hub config…", "zh": "Hub 配置…",
        "ja": "Hub 設定…", "ko": "Hub 구성…",
        "es": "Configuración del Hub…", "fr": "Config du Hub…",
    ],
    "menu.launchAtLogin": [
        "en": "Launch at login", "zh": "开机自启",
        "ja": "ログイン時に起動", "ko": "로그인 시 실행",
        "es": "Abrir al iniciar sesión", "fr": "Lancer à l'ouverture de session",
    ],
    "menu.settings": [
        "en": "Settings…", "zh": "设置…", "ja": "設定…", "ko": "설정…",
        "es": "Ajustes…", "fr": "Réglages…",
    ],
    "menu.test": [
        "en": "Test approval card", "zh": "测试审批卡片",
        "ja": "承認カードをテスト", "ko": "승인 카드 테스트",
        "es": "Probar tarjeta de aprobación", "fr": "Tester la carte d'approbation",
    ],
    "menu.log": [
        "en": "Approval log…", "zh": "审批日志…",
        "ja": "承認ログ…", "ko": "승인 로그…",
        "es": "Registro de aprobaciones…", "fr": "Journal d'approbation…",
    ],
    "menu.quit": [
        "en": "Quit", "zh": "退出", "ja": "終了", "ko": "종료",
        "es": "Salir", "fr": "Quitter",
    ],
    "menu.updateTo": [   // 后面接版本号，如「🆕 更新到 0.7.7」
        "en": "Update to", "zh": "更新到", "ja": "更新：",
        "ko": "업데이트:", "es": "Actualizar a", "fr": "Mettre à jour vers",
    ],

    // MARK: 菜单里的用量区（只显示正在跑的 AI CLI）
    "usage.runningTip": [   // %d = 在跑的会话/进程数
        "en": "%d session(s) running", "zh": "%d 个会话正在运行",
        "ja": "%d 件のセッションが実行中", "ko": "%d개 세션 실행 중",
        "es": "%d sesión(es) en ejecución", "fr": "%d session(s) en cours",
    ],
    "usage.notRunningTip": [
        "en": "not running right now", "zh": "当前没有在运行",
        "ja": "現在は実行していません", "ko": "지금은 실행 중이 아님",
        "es": "no se está ejecutando ahora", "fr": "pas en cours d'exécution",
    ],
    "usage.resetIn": [      // %@ = 2h13m
        "en": "resets in %@", "zh": "%@ 后重置",
        "ja": "%@後にリセット", "ko": "%@ 후 초기화",
        "es": "se reinicia en %@", "fr": "réinit. dans %@",
    ],
    "usage.resetting": [
        "en": "resetting…", "zh": "正在重置…",
        "ja": "リセット中…", "ko": "초기화 중…",
        "es": "reiniciando…", "fr": "réinitialisation…",
    ],
    "usage.poolDefault": [  // 多池并存时，给没有可读名字的主池一个标题，免得它那两行看着无主
        "en": "Subscription", "zh": "订阅额度",
        "ja": "サブスクリプション", "ko": "구독 할당량",
        "es": "Suscripción", "fr": "Abonnement",
    ],
    "usage.remaining": [    // %@ = 72（可能带对齐用的前导空格）
        "en": "%@%% left", "zh": "剩余 %@%%",
        "ja": "残り %@%%", "ko": "%@%% 남음",
        "es": "queda %@%%", "fr": "%@%% restants",
    ],
    "usage.observed": [     // %@ = 3h12m；数值是本地观测到的最后一次，不是刚查的账户
        "en": "observed %@ ago", "zh": "%@ 前观测到",
        "ja": "%@前に観測", "ko": "%@ 전 관측",
        "es": "observado hace %@", "fr": "observé il y a %@",
    ],
    "usage.observedNow": [
        "en": "just observed", "zh": "刚刚观测到",
        "ja": "たった今観測", "ko": "방금 관측",
        "es": "observado ahora", "fr": "observé à l'instant",
    ],
    "usage.noSnapshot": [   // 还没收到过这个工具的额度上报（为什么没收到由下面三条说）
        "en": "no quota reported yet", "zh": "还没收到额度上报",
        "ja": "クォータ未取得", "ko": "할당량 보고 없음",
        "es": "sin cuota reportada aún", "fr": "aucun quota reçu",
    ],
    // ── Hub HTTP API 的 reason/note 文案。**只有 zh/en**：一律经 LHub() 取，
    // 和 Hub 页面同一条降级规则（非中文→英文）。这些字符串不出现在 app 界面里，
    // 所以不需要另外四种语言 —— 留着没人校对的死译文只会误导下一个人。
    "hubapi.reason.sessionExited": [
        "en": "Session liveness unconfirmed; resuming requires its own dedicated action", "zh": "会话未确认存活；恢复必须使用独立动作",
    ],
    "hubapi.reason.ownerNotConnected": [
        "en": "Not connected to the app-server hosting this session; monitoring is not an input channel", "zh": "未连接承载该会话的 app-server；监控不等于输入通道",
    ],
    "hubapi.reason.messagingDisabled": [
        "en": "The session has no registered inbox", "zh": "会话没有已注册 inbox",
    ],
    "hubapi.reason.versionUnsupported": [
        "en": "The target does not declare the supported peerProtocol 1; a software version alone is not proof", "zh": "目标未声明受支持的 peerProtocol 1；不能仅按软件版本推断",
    ],
    "hubapi.reason.sessionArchived": [
        "en": "The session is archived; unarchive it in Codex before queueing messages", "zh": "会话已归档；先在 Codex 里 unarchive 才能排队消息",
    ],
    "hubapi.reason.sessionUnidentified": [
        "en": "Missing the Codex thread id", "zh": "缺少 Codex thread id",
    ],
    "hubapi.reason.codexQueue": [
        "en": "Queued into the Codex thread; handled when the session reads its next turn", "zh": "排进 Codex thread 队列；会话下一轮读取时处理",
    ],
    "hubapi.reason.claudeInbox": [
        "en": "Peer message; subject to the target's inbound policy, delivery must be read back", "zh": "peer 消息；遵循目标 inbound 策略，送达需回读",
    ],
    "hubapi.cap.steer": [
        "en": "Native steer is not wired up; a peer message does not interrupt a tool already running", "zh": "未接入原生 steer；peer 消息不打断正在执行的工具",
    ],
    "hubapi.cap.enqueue": [
        "en": "Messages are never replayed automatically into an unconfirmed execution channel", "zh": "不在未确认的执行通道自动重放消息",
    ],
    "hubapi.cap.approve": [
        "en": "Only an exactly matching, genuinely pending approval can be answered", "zh": "只允许答复准确匹配的真实挂起审批",
    ],
    "hubapi.cap.answer": [
        "en": "No structured question/answer response channel is registered right now", "zh": "当前未注册结构化问答响应通道",
    ],
    "hubapi.cap.interrupt": [
        "en": "Killing a process must not masquerade as a native interrupt", "zh": "不能通过杀进程冒充原生中断",
    ],
    "hubapi.cap.resume": [
        "en": "Resume in the original client; starting a second process would fight over the same session", "zh": "请在原客户端恢复；避免另起进程抢占同一会话",
    ],
    "hubapi.cap.replyViaUI": [
        "en": "The UI channel has not yet passed verification for targeting the right session", "zh": "UI 通道尚未完成准确会话定位验证",
    ],
    "hubapi.cap.approvePending": [
        "en": "Answers only the approval request GestureApprove currently has pending", "zh": "仅答复当前 GestureApprove 挂起请求",
    ],
    "hubapi.err.codexMissing": [
        "en": "The codex executable could not be found", "zh": "找不到 codex 可执行文件",
    ],
    "hubapi.err.queueTimeout": [
        "en": "codex queue timed out without returning", "zh": "codex queue 超时未返回",
    ],
    "hubapi.err.queueNoOutput": [
        "en": "codex queue produced no output", "zh": "codex queue 没有输出",
    ],
    "hubapi.ok.queued": [
        "en": "Queued into the Codex thread; handled when the session reads its next turn", "zh": "已排进 Codex thread 队列；会话下一轮读取时处理",
    ],
    "hubapi.err.invalidMessage": [
        "en": "A message must be 1–32000 bytes", "zh": "消息必须为 1–32000 字节",
    ],
    "hubapi.ok.unconfirmed": [
        "en": "Written to the session inbox; the session log must confirm receipt — the inbound policy may hold or reject it", "zh": "已写入原会话 inbox；需会话记录确认接收，可能被 inbound 策略暂存或拒绝",
    ],
    "hubapi.ok.confirmedInLog": [
        "en": "Confirmed in the target session's log", "zh": "已在目标会话记录中确认",
    ],
    "hubapi.err.persistence": [
        "en": "The action record could not be persisted; nothing was sent or decided", "zh": "无法持久化操作记录；未发送或裁决",
    ],
    "hubapi.note.quotas": [
        "en": "No Web API or Keychain was queried; values are the latest local observation. Model-specific allowances that were never reported cannot be inferred. Pools with current=false come from earlier reports and are kept only as history.", "zh": "未查询 Web API/Keychain；数值为最近本地观测。未下发的模型独立额度不可推算。current=false 的池来自更早的上报，仅作历史保留。",
    ],
    // ── 采集器安装/卸载的整套文案。走设置里的报错弹窗、菜单栏那行提示，
    // 以及 Claude 状态栏（hook 子进程里 L() 一样能读到语言设置）。
    "monitor.err.claudeUnreadable": [
        "en": "Claude settings could not be parsed; nothing was changed", "zh": "Claude settings 无法解析，未修改",
        "ja": "Claude の settings を解析できません。変更していません", "ko": "Claude settings를 해석할 수 없어 변경하지 않았습니다",
        "es": "No se pudo leer la configuración de Claude; no se cambió nada", "fr": "Configuration Claude illisible ; rien n'a été modifié",
    ],
    "monitor.err.codexNotUTF8": [
        "en": "The Codex config is not UTF-8; nothing was changed", "zh": "Codex 配置不是 UTF-8，未修改",
        "ja": "Codex の設定が UTF-8 ではありません。変更していません", "ko": "Codex 설정이 UTF-8이 아니어서 변경하지 않았습니다",
        "es": "La configuración de Codex no es UTF-8; no se cambió nada", "fr": "La configuration Codex n'est pas en UTF-8 ; rien n'a été modifié",
    ],
    "monitor.err.codexBlockBroken": [
        "en": "The Codex collector block is incomplete; nothing was changed", "zh": "Codex 监控配置块不完整，未修改",
        "ja": "Codex のコレクター設定ブロックが不完全です。変更していません", "ko": "Codex 수집기 설정 블록이 불완전하여 변경하지 않았습니다",
        "es": "El bloque del recolector de Codex está incompleto; no se cambió nada", "fr": "Le bloc collecteur Codex est incomplet ; rien n'a été modifié",
    ],
    "monitor.err.toolMissing": [   // %1$@ = 工具名，%2$@ = 配置目录
        "en": "%1$@ was not found on this Mac (%2$@ does not exist and its command is not on PATH); no file was created",
        "zh": "未检测到 %1$@（%2$@ 不存在，PATH 里也没有它的命令），未创建任何文件",
        "ja": "%1$@ が見つかりません（%2$@ が存在せず、PATH にもコマンドがありません）。ファイルは作成していません",
        "ko": "%1$@를 찾을 수 없습니다(%2$@가 없고 PATH에도 명령이 없음). 파일을 만들지 않았습니다",
        "es": "No se encontró %1$@ en este Mac (%2$@ no existe y su comando no está en PATH); no se creó ningún archivo",
        "fr": "%1$@ est introuvable sur ce Mac (%2$@ n'existe pas et sa commande n'est pas dans le PATH) ; aucun fichier créé",
    ],
    "monitor.err.codexRejected": [
        "en": "Codex could not load the updated config; the Codex config was rolled back (Claude is unaffected). Check hooks version compatibility.",
        "zh": "Codex 未能加载更新后的配置，已回滚 Codex 配置（Claude 不受影响）；请检查 hooks 版本兼容性",
        "ja": "Codex が更新後の設定を読み込めませんでした。Codex の設定のみロールバックしました（Claude は影響なし）。hooks のバージョン互換性を確認してください",
        "ko": "Codex가 갱신된 설정을 불러오지 못해 Codex 설정만 되돌렸습니다(Claude는 영향 없음). hooks 버전 호환성을 확인하세요",
        "es": "Codex no pudo cargar la configuración actualizada; se revirtió solo la de Codex (Claude no se ve afectado). Revisa la compatibilidad de versiones de hooks.",
        "fr": "Codex n'a pas pu charger la configuration mise à jour ; seule celle de Codex a été annulée (Claude non affecté). Vérifiez la compatibilité des versions de hooks.",
    ],
    "monitor.err.unknownTarget": [
        "en": "unknown collection target", "zh": "未知的采集目标",
        "ja": "不明な収集対象", "ko": "알 수 없는 수집 대상",
        "es": "objetivo de recopilación desconocido", "fr": "cible de collecte inconnue",
    ],
    "monitor.note.codexTrust": [
        "en": "Review and trust the new definitions in Codex under /hooks; installed does not yet mean the client trusts them.",
        "zh": "请在 Codex /hooks 审阅信任新定义；未收到事件前不宣称已生效",
        "ja": "Codex の /hooks で新しい定義を確認し信頼してください。インストール済みでもクライアントが信頼したとは限りません",
        "ko": "Codex의 /hooks에서 새 정의를 검토하고 신뢰하세요. 설치했다고 클라이언트가 신뢰한 것은 아닙니다",
        "es": "Revisa y confía en las nuevas definiciones en Codex bajo /hooks; instalado no significa aún que el cliente confíe en ellas.",
        "fr": "Vérifiez et approuvez les nouvelles définitions dans Codex sous /hooks ; installé ne signifie pas encore que le client les approuve.",
    ],
    "monitor.skip.notConnected": [
        "en": "no collector connected; nothing to restore", "zh": "未接入采集器，无需还原",
        "ja": "コレクター未接続。復元するものはありません", "ko": "연결된 수집기 없음. 복원할 것이 없습니다",
        "es": "sin recolector conectado; nada que restaurar", "fr": "aucun collecteur connecté ; rien à restaurer",
    ],
    "monitor.hint.installed": [
        "en": "Only newly started sessions pick up the collector; the original config is backed up alongside as .ga-monitor-backup.",
        "zh": "新开的会话才会带上采集器；原配置已备份为同名 .ga-monitor-backup",
        "ja": "新しく開いたセッションのみコレクターを読み込みます。元の設定は同名の .ga-monitor-backup に保存済みです",
        "ko": "새로 시작한 세션만 수집기를 불러옵니다. 원본 설정은 같은 이름의 .ga-monitor-backup으로 백업했습니다",
        "es": "Solo las sesiones nuevas cargan el recolector; la configuración original está respaldada como .ga-monitor-backup.",
        "fr": "Seules les nouvelles sessions chargent le collecteur ; la configuration d'origine est sauvegardée en .ga-monitor-backup.",
    ],
    "monitor.hint.uninstalled": [
        "en": "Restored; sessions already running still hold the old config.",
        "zh": "已还原；运行中的会话仍持有旧配置",
        "ja": "復元しました。実行中のセッションは古い設定を保持したままです",
        "ko": "복원했습니다. 실행 중인 세션은 여전히 이전 설정을 사용합니다",
        "es": "Restaurado; las sesiones en curso aún tienen la configuración anterior.",
        "fr": "Restauré ; les sessions déjà en cours conservent l'ancienne configuration.",
    ],
    "monitor.statusline.waiting": [   // 装好后客户端还没报过额度时，状态栏那一行
        "en": "quota: awaiting first report", "zh": "额度等待首次响应",
        "ja": "クォータ: 初回の報告待ち", "ko": "할당량: 첫 보고 대기 중",
        "es": "cuota: esperando el primer informe", "fr": "quota : en attente du premier rapport",
    ],
    "usage.collectOff": [   // 采集器没装：唯一能点的一行，点了就装
        "en": "Quota collection is off — turn it on", "zh": "额度采集未开启 · 点此开启",
        "ja": "クォータ収集はオフ · タップで有効化", "ko": "할당량 수집 꺼짐 · 눌러서 켜기",
        "es": "Recopilación de cuota desactivada: actívala", "fr": "Collecte du quota désactivée — activer",
    ],
    "usage.collectBroken": [   // 装过，但配置指向旧路径/被别的工具换走
        "en": "Collection config is stale — repair it", "zh": "采集配置已失效 · 点此修复",
        "ja": "収集設定が無効です · タップで修復", "ko": "수집 설정이 무효 · 눌러서 복구",
        "es": "Configuración de recopilación obsoleta: repárala", "fr": "Configuration de collecte obsolète — réparer",
    ],
    "usage.collectWaiting": [  // 装好了，等客户端下一次刷状态栏
        "en": "Collecting — new sessions report on next refresh", "zh": "已开启 · 新开的会话刷新状态栏后显示",
        "ja": "収集中 · 新しいセッションの次回更新で表示", "ko": "수집 중 · 새 세션의 다음 갱신 후 표시",
        "es": "Recopilando: aparecerá tras la próxima actualización", "fr": "Collecte active — visible à la prochaine actualisation",
    ],
    "usage.collectConfirm.title": [
        "en": "Turn on quota collection?", "zh": "开启额度采集？",
        "ja": "クォータ収集を有効にしますか？", "ko": "할당량 수집을 켤까요?",
        "es": "¿Activar la recopilación de cuota?", "fr": "Activer la collecte du quota ?",
    ],
    "usage.collectConfirm.body": [
        "en": "Registers hooks in the config of each AI tool found on this Mac and wraps its status line (your own status line still runs). The original config is backed up next to it; turning this off restores it. Only tools you actually have are touched.",
        "zh": "会在本机检测到的每个 AI 工具的配置里注册 hook，并包装它的状态栏（你原来的状态栏照常执行）。原配置会备份在旁边，关掉即还原。没装的工具一个字节都不写。",
        "ja": "このMacで検出した各AIツールの設定にフックを登録し、ステータスラインをラップします（元のステータスラインもそのまま動作）。元の設定は隣にバックアップされ、オフにすると復元されます。",
        "ko": "이 Mac에서 발견된 각 AI 도구 설정에 훅을 등록하고 상태 표시줄을 감쌉니다(기존 상태 표시줄도 그대로 실행). 원본 설정은 옆에 백업되며 끄면 복원됩니다.",
        "es": "Registra hooks en la configuración de cada herramienta de IA encontrada en este Mac y envuelve su status line (la tuya sigue ejecutándose). La configuración original se respalda al lado; al desactivarlo se restaura.",
        "fr": "Enregistre des hooks dans la configuration de chaque outil d'IA détecté sur ce Mac et encapsule sa status line (la vôtre continue de s'exécuter). La configuration d'origine est sauvegardée à côté ; la désactivation la restaure.",
    ],
    "usage.collectConfirm.ok": [
        "en": "Turn On", "zh": "开启",
        "ja": "有効にする", "ko": "켜기",
        "es": "Activar", "fr": "Activer",
    ],
    "settings.usage.collect": [
        "en": "Collect quota from installed AI tools", "zh": "接入本机 AI 工具的额度采集",
        "ja": "インストール済み AI ツールからクォータを収集", "ko": "설치된 AI 도구에서 할당량 수집",
        "es": "Recopilar cuota de las herramientas de IA instaladas", "fr": "Collecter le quota des outils d'IA installés",
    ],
    "settings.usage.collectNote": [
        "en": "Quota only exists where each client reports it — Claude via its status line, Codex via its session records. Turning this on registers a collector in the config of every AI tool found on this Mac; tools you don't have are left alone.",
        "zh": "额度只有各家客户端自己报得出来 —— Claude 走 statusLine，Codex 走会话记录。勾上会在本机检测到的每个 AI 工具的配置里注册采集器；没装的工具一概不碰。",
        "ja": "クォータは各クライアントが報告するものだけです（Claude はステータスライン、Codex はセッション記録）。オンにすると、このMacで検出した各 AI ツールの設定にコレクターを登録します。未インストールのツールには触れません。",
        "ko": "할당량은 각 클라이언트가 보고하는 것만 존재합니다(Claude는 상태 표시줄, Codex는 세션 기록). 켜면 이 Mac에서 발견된 각 AI 도구 설정에 수집기를 등록하며, 설치되지 않은 도구는 건드리지 않습니다.",
        "es": "La cuota solo existe donde cada cliente la reporta: Claude vía su status line, Codex vía sus registros de sesión. Al activarlo se registra un recolector en la configuración de cada herramienta de IA encontrada en este Mac; las que no tengas no se tocan.",
        "fr": "Le quota n'existe que là où chaque client le rapporte — Claude via sa status line, Codex via ses enregistrements de session. L'activer enregistre un collecteur dans la configuration de chaque outil d'IA détecté sur ce Mac ; les outils absents ne sont pas touchés.",
    ],
    "settings.usage.collectPrivacy": [
        "en": "No browser, no account Web API, no Keychain. Your own status line still runs, the original config is backed up next to it, and turning this off restores it.",
        "zh": "不读浏览器、不调账户 Web API、不碰钥匙串。你原来的状态栏照常执行，原配置备份在旁边，关掉即还原。",
        "ja": "ブラウザもアカウント Web API も Keychain も使いません。元のステータスラインはそのまま動作し、元の設定は隣にバックアップされ、オフにすると復元されます。",
        "ko": "브라우저, 계정 웹 API, 키체인을 사용하지 않습니다. 기존 상태 표시줄은 그대로 실행되고, 원본 설정은 옆에 백업되며 끄면 복원됩니다.",
        "es": "Sin navegador, sin Web API de cuenta, sin Llavero. Tu propia status line sigue ejecutándose, la configuración original se respalda al lado y al desactivarlo se restaura.",
        "fr": "Pas de navigateur, pas d'API Web de compte, pas de trousseau. Votre propre status line continue de s'exécuter, la configuration d'origine est sauvegardée à côté et la désactivation la restaure.",
    ],
    "settings.usage.state.collecting": [
        "en": "collecting", "zh": "采集中",
        "ja": "収集中", "ko": "수집 중",
        "es": "recopilando", "fr": "collecte active",
    ],
    "settings.usage.state.stale": [
        "en": "config stale — reopen this window to repair", "zh": "配置已失效 · 重开本窗口即自动修复",
        "ja": "設定が無効 · このウィンドウを開き直すと修復", "ko": "설정 무효 · 이 창을 다시 열면 복구",
        "es": "config obsoleta: reabre esta ventana para repararla", "fr": "config obsolète — rouvrez cette fenêtre pour réparer",
    ],
    "settings.usage.state.absent": [
        "en": "not connected", "zh": "未接入",
        "ja": "未接続", "ko": "연결 안 됨",
        "es": "no conectado", "fr": "non connecté",
    ],
    "settings.usage.state.missing": [
        "en": "not installed on this Mac", "zh": "本机未安装",
        "ja": "このMacに未インストール", "ko": "이 Mac에 미설치",
        "es": "no instalado en este Mac", "fr": "non installé sur ce Mac",
    ],
    "usage.pending": [      // 窗口刚重置，等下一次请求才有新数值
        "en": "waiting for next request", "zh": "等下次请求刷新",
        "ja": "次のリクエスト待ち", "ko": "다음 요청 대기 중",
        "es": "esperando la próxima solicitud", "fr": "en attente d'une requête",
    ],
    "usage.noCredentials": [
        "en": "Claude Code credentials unavailable", "zh": "读不到 Claude Code 凭证",
        "ja": "Claude Code の認証情報を取得できません", "ko": "Claude Code 자격 증명을 읽을 수 없음",
        "es": "Credenciales de Claude Code no disponibles", "fr": "Identifiants Claude Code indisponibles",
    ],
    "usage.keychainDenied": [
        "en": "Keychain access denied — restart to retry", "zh": "钥匙串访问被拒绝，重启 app 可重试",
        "ja": "キーチェーンアクセスが拒否されました（再起動で再試行）", "ko": "키체인 접근 거부됨 — 재시작 후 재시도",
        "es": "Acceso al llavero denegado: reinicia para reintentar", "fr": "Accès au trousseau refusé — redémarrez pour réessayer",
    ],
    "usage.rateLimited": [
        "en": "usage API throttled, retrying later", "zh": "用量接口被限流，稍后重试",
        "ja": "使用量 API が制限中、後で再試行", "ko": "사용량 API 제한 중, 나중에 재시도",
        "es": "API de uso limitada, reintentando", "fr": "API d'usage limitée, nouvel essai plus tard",
    ],
    "usage.fetchFailed": [
        "en": "couldn't fetch usage", "zh": "用量获取失败",
        "ja": "使用量を取得できませんでした", "ko": "사용량을 가져오지 못함",
        "es": "no se pudo obtener el uso", "fr": "impossible de récupérer l'usage",
    ],
    // 数据来源问询（Chrome 网页通道 vs 本机钥匙串）
    "usage.notify.title": [
        "en": "Usage is in", "zh": "用量获取成功",
        "ja": "使用量を取得しました", "ko": "사용량을 가져왔습니다",
        "es": "Uso obtenido", "fr": "Usage récupéré",
    ],
    "usage.chooseSource": [
        "en": "Choose where to read usage…", "zh": "选择用量数据来源…",
        "ja": "使用量の取得元を選ぶ…", "ko": "사용량 출처 선택…",
        "es": "Elegir de dónde leer el uso…", "fr": "Choisir la source de l'usage…",
    ],
    "usage.ask.title": [
        "en": "Read Claude usage in the browser",
        "zh": "在浏览器中获取 Claude 用量信息",
        "ja": "ブラウザで Claude の使用量を取得",
        "ko": "브라우저에서 Claude 사용량 가져오기",
        "es": "Leer el uso de Claude en el navegador",
        "fr": "Lire l'usage de Claude dans le navigateur",
    ],
    "usage.ask.firstTime": [
        "en": "Your usage can be read from a signed-in claude.ai tab in Chrome, which never asks for permission and stays signed in for months. Or read it through the Keychain, which asks again every time Claude Code refreshes its token.",
        "zh": "用量可以借 Chrome 里已登录的 claude.ai 标签页读取，全程不弹授权框，登录态还能撑好几个月。或者走 Keychain 读，但每次 Claude Code 刷新 token 之后系统都会再问你一次。",
        "ja": "使用量は Chrome のログイン済み claude.ai タブから取得できます。許可を求められることはなく、ログインも数か月保ちます。あるいはキーチェーン経由でも読めますが、Claude Code がトークンを更新するたびに許可を聞かれます。",
        "ko": "사용량은 Chrome에 로그인된 claude.ai 탭에서 읽을 수 있고, 권한을 묻지 않으며 로그인도 몇 달 유지됩니다. 아니면 키체인으로 읽을 수도 있지만, Claude Code가 토큰을 갱신할 때마다 다시 묻습니다.",
        "es": "El uso puede leerse desde una pestaña de claude.ai con sesión iniciada en Chrome, que nunca pide permiso y sigue conectada durante meses. O léelo con el llavero, que vuelve a pedir permiso cada vez que Claude Code renueva su token.",
        "fr": "L'usage peut être lu depuis un onglet claude.ai connecté dans Chrome, qui ne demande jamais d'autorisation et reste connecté des mois. Ou lisez-le via le trousseau, qui redemande l'autorisation à chaque renouvellement de jeton par Claude Code.",
    ],
    "usage.ask.noTab": [
        "en": "Chrome doesn't have a signed-in claude.ai tab open right now. Opening one keeps usage prompt-free, or you can read it through the Keychain instead, which asks for permission again every time Claude Code refreshes its token.",
        "zh": "Chrome 里现在没有已登录的 claude.ai 标签页。开一个就能继续不弹授权框地读用量，或者改走 Keychain，但每次 Claude Code 刷新 token 之后系统都会再问你一次。",
        "ja": "Chrome にログイン済みの claude.ai タブが今ありません。開けば許可を求められずに取得を続けられます。キーチェーン経由に切り替えることもできますが、Claude Code がトークンを更新するたびに許可を聞かれます。",
        "ko": "지금 Chrome에 로그인된 claude.ai 탭이 없습니다. 하나 열면 권한 창 없이 계속 읽을 수 있고, 대신 키체인으로 읽을 수도 있지만 Claude Code가 토큰을 갱신할 때마다 다시 묻습니다.",
        "es": "Ahora mismo Chrome no tiene abierta ninguna pestaña de claude.ai con sesión iniciada. Abrir una mantiene la lectura sin diálogos, o puedes leerlo con el llavero, que vuelve a pedir permiso cada vez que Claude Code renueva su token.",
        "fr": "Aucun onglet claude.ai connecté n'est ouvert dans Chrome pour le moment. En ouvrir un permet de continuer sans autorisation, ou vous pouvez lire via le trousseau, qui redemande l'autorisation à chaque renouvellement de jeton.",
    ],
    "usage.ask.jsDisabled": [
        "en": "Chrome is blocking scripted access, so turn on View ▸ Developer ▸ Allow JavaScript from Apple Events and try again. Or read usage through the Keychain instead, which asks for permission again every time Claude Code refreshes its token.",
        "zh": "Chrome 挡住了脚本访问，到菜单栏打开「显示 ▸ 开发者 ▸ 允许通过 Apple 事件执行 JavaScript」再试一次。或者改走 Keychain 读取，但每次 Claude Code 刷新 token 之后系统都会再问你一次。",
        "ja": "Chrome がスクリプトからのアクセスを拒否しています。「表示 ▸ デベロッパー ▸ Apple Events からの JavaScript を許可」をオンにしてもう一度お試しください。キーチェーン経由でも読めますが、Claude Code がトークンを更新するたびに許可を聞かれます。",
        "ko": "Chrome가 스크립트 접근을 막고 있습니다. ‘보기 ▸ 개발자용 ▸ Apple Events의 JavaScript 허용’을 켜고 다시 시도하세요. 대신 키체인으로 읽을 수도 있지만, Claude Code가 토큰을 갱신할 때마다 다시 묻습니다.",
        "es": "Chrome bloquea el acceso por script: activa Ver ▸ Desarrollador ▸ Permitir JavaScript desde Apple Events e inténtalo otra vez. O lee el uso con el llavero, que vuelve a pedir permiso cada vez que Claude Code renueva su token.",
        "fr": "Chrome bloque l'accès par script : activez Affichage ▸ Développement ▸ Autoriser JavaScript depuis les Apple Events, puis réessayez. Ou lisez l'usage via le trousseau, qui redemande l'autorisation à chaque renouvellement de jeton.",
    ],
    "usage.ask.otherAccount": [
        "en": "The claude.ai tab is signed in to a different account than Claude Code, so its numbers wouldn't be yours. Sign in with the same account, or read usage through the Keychain, which always uses Claude Code's own login but asks for permission after every token refresh.",
        "zh": "claude.ai 标签页登录的账号和 Claude Code 用的不是同一个，那边的数字不是你这个额度。换成同一个账号登录，或者改走 Keychain——它读的一定是 Claude Code 自己的登录态，但每次 token 刷新后都会问一次授权。",
        "ja": "claude.ai タブは Claude Code とは別のアカウントでログインしているため、その数字はあなたの使用量ではありません。同じアカウントでログインし直すか、キーチェーン経由にしてください（常に Claude Code 自身のログインを使いますが、トークン更新のたびに許可を求められます）。",
        "ko": "claude.ai 탭이 Claude Code와 다른 계정으로 로그인되어 있어 그 수치는 내 사용량이 아닙니다. 같은 계정으로 로그인하거나 키체인으로 읽으세요. 키체인은 항상 Claude Code의 로그인을 쓰지만 토큰 갱신 때마다 권한을 묻습니다.",
        "es": "La pestaña de claude.ai tiene iniciada una cuenta distinta a la de Claude Code, así que esos números no serían los tuyos. Inicia sesión con la misma cuenta o lee el uso con el llavero, que siempre usa la sesión de Claude Code pero pide permiso tras cada renovación del token.",
        "fr": "L'onglet claude.ai est connecté à un compte différent de celui de Claude Code : ces chiffres ne seraient pas les vôtres. Connectez-vous au même compte, ou lisez l'usage via le trousseau, qui utilise toujours la session de Claude Code mais demande l'autorisation à chaque renouvellement de jeton.",
    ],
    "usage.ask.otherFailure": [
        "en": "The claude.ai tab didn't return anything, so the sign-in may have expired — open Claude Web to check. Or read usage through the Keychain instead, which asks for permission again every time Claude Code refreshes its token.",
        "zh": "claude.ai 标签页什么都没返回，可能是登录态过期了，打开 Claude Web 看一眼。或者改走 Keychain 读取，但每次 Claude Code 刷新 token 之后系统都会再问你一次。",
        "ja": "claude.ai タブから何も返ってきませんでした。ログインが切れている可能性があるので、Claude Web を開いて確認してください。キーチェーン経由でも読めますが、トークン更新のたびに許可を聞かれます。",
        "ko": "claude.ai 탭이 아무것도 반환하지 않았습니다. 로그인이 만료됐을 수 있으니 Claude Web을 열어 확인해 보세요. 대신 키체인으로 읽을 수도 있지만, 토큰이 갱신될 때마다 다시 묻습니다.",
        "es": "La pestaña de claude.ai no devolvió nada, así que puede que la sesión haya caducado: abre Claude Web para comprobarlo. O lee el uso con el llavero, que vuelve a pedir permiso cada vez que Claude Code renueva su token.",
        "fr": "L'onglet claude.ai n'a rien renvoyé, la connexion a peut-être expiré — ouvrez Claude Web pour vérifier. Ou lisez l'usage via le trousseau, qui redemande l'autorisation à chaque renouvellement de jeton.",
    ],
    "usage.ask.useChrome": [
        "en": "Open Claude Web", "zh": "打开 Claude Web",
        "ja": "Claude Web を開く", "ko": "Claude Web 열기",
        "es": "Abrir Claude Web", "fr": "Ouvrir Claude Web",
    ],
    "usage.ask.useKeychain": [
        "en": "Read via Keychain", "zh": "通过 Keychain 读取",
        "ja": "キーチェーンで読み取る", "ko": "키체인으로 읽기",
        "es": "Leer con el llavero", "fr": "Lire via le trousseau",
    ],
    "usage.ask.snooze": [
        "en": "Skip usage for now", "zh": "暂不获取用量",
        "ja": "今は取得しない", "ko": "지금은 가져오지 않기",
        "es": "No leer el uso por ahora", "fr": "Ne pas lire l'usage pour l'instant",
    ],
    "usage.chromeNoTab": [
        "en": "no signed-in claude.ai tab in Chrome", "zh": "Chrome 里没有已登录的 claude.ai 标签页",
        "ja": "ログイン済みの claude.ai タブがありません", "ko": "Chrome에 로그인된 claude.ai 탭 없음",
        "es": "sin pestaña de claude.ai con sesión en Chrome", "fr": "aucun onglet claude.ai connecté dans Chrome",
    ],
    "usage.chromeJSOff": [
        "en": "Chrome blocks JavaScript from Apple Events", "zh": "Chrome 未允许通过 Apple 事件执行 JavaScript",
        "ja": "Chrome が Apple Events からの JavaScript を拒否", "ko": "Chrome가 Apple Events의 JavaScript를 차단함",
        "es": "Chrome bloquea JavaScript desde Apple Events", "fr": "Chrome bloque JavaScript depuis les Apple Events",
    ],
    "usage.chromeOtherAccount": [
        "en": "browser signed in to a different account", "zh": "浏览器登录的是另一个账号",
        "ja": "ブラウザは別アカウントでログイン中", "ko": "브라우저가 다른 계정으로 로그인됨",
        "es": "el navegador tiene otra cuenta iniciada", "fr": "navigateur connecté à un autre compte",
    ],
    "usage.chromeFailed": [
        "en": "claude.ai tab didn't return usage", "zh": "claude.ai 标签页没返回用量",
        "ja": "claude.ai タブから取得できませんでした", "ko": "claude.ai 탭에서 사용량을 받지 못함",
        "es": "la pestaña de claude.ai no devolvió el uso", "fr": "l'onglet claude.ai n'a rien renvoyé",
    ],

    "usage.codexNoSnapshot": [
        "en": "no recent quota snapshot", "zh": "暂无最近的额度快照",
        "ja": "最近のクォータ情報がありません", "ko": "최근 할당량 스냅샷 없음",
        "es": "sin datos de cuota recientes", "fr": "aucun relevé de quota récent",
    ],

    "settings.usage.enable": [
        "en": "Show AI CLI usage in the menu", "zh": "在菜单里显示 AI CLI 用量",
        "ja": "メニューに AI CLI の使用量を表示", "ko": "메뉴에 AI CLI 사용량 표시",
        "es": "Mostrar el uso de las CLI de IA en el menú", "fr": "Afficher l'usage des CLI IA dans le menu",
    ],
    "settings.usage.note": [
        "en": "Only tools that are actually running are listed. Codex quota comes from local session files; for Claude Code, pick where to read it:",
        "zh": "只列出真正在跑的工具。Codex 的额度直接读本地会话文件；Claude Code 的额度从哪里取由你决定：",
        "ja": "実行中のツールのみ表示します。Codex のクォータはローカルのセッションファイルから取得します。Claude Code は取得元を選べます:",
        "ko": "실행 중인 도구만 표시합니다. Codex 할당량은 로컬 세션 파일에서 읽고, Claude Code는 출처를 선택할 수 있습니다:",
        "es": "Solo se listan las herramientas en ejecución. La cuota de Codex se lee de archivos locales; para Claude Code, elige de dónde leerla:",
        "fr": "Seuls les outils réellement en cours sont listés. Le quota Codex provient des fichiers locaux ; pour Claude Code, choisissez la source :",
    ],
    "settings.usage.source": [
        "en": "Claude Code usage from", "zh": "Claude Code 用量取自",
        "ja": "Claude Code の使用量の取得元", "ko": "Claude Code 사용량 출처",
        "es": "Uso de Claude Code desde", "fr": "Usage Claude Code depuis",
    ],
    "settings.usage.sourceAsk": [
        "en": "Ask me", "zh": "问我",
        "ja": "確認する", "ko": "물어보기",
        "es": "Preguntarme", "fr": "Me demander",
    ],
    "settings.usage.sourceChrome": [
        "en": "Chrome", "zh": "Chrome",
        "ja": "Chrome", "ko": "Chrome",
        "es": "Chrome", "fr": "Chrome",
    ],
    "settings.usage.sourceKeychain": [
        "en": "Keychain", "zh": "钥匙串",
        "ja": "キーチェーン", "ko": "키체인",
        "es": "Llavero", "fr": "Trousseau",
    ],
    "settings.usage.snoozed": [
        "en": "Not asking about usage for 24 hours.", "zh": "24 小时内不再主动询问用量。",
        "ja": "24 時間は使用量について確認しません。", "ko": "24시간 동안 사용량을 묻지 않습니다.",
        "es": "No se preguntará por el uso durante 24 horas.", "fr": "Aucune demande sur l'usage pendant 24 h.",
    ],
    "settings.usage.resume": [
        "en": "Resume now", "zh": "立即恢复",
        "ja": "今すぐ再開", "ko": "지금 다시 켜기",
        "es": "Reanudar ahora", "fr": "Reprendre",
    ],
    "settings.usage.sourceNote": [
        "en": "Chrome needs a signed-in claude.ai tab and never prompts; the Keychain route asks for permission again whenever Claude Code refreshes its token.",
        "zh": "Chrome 需要开着已登录的 claude.ai 标签页，全程不弹授权框；钥匙串那条路每次 Claude Code 刷新 token 后都会再问一次授权。",
        "ja": "Chrome はログイン済みの claude.ai タブが必要ですが、許可ダイアログは出ません。キーチェーンは Claude Code がトークンを更新するたびに許可を求められます。",
        "ko": "Chrome는 로그인된 claude.ai 탭이 필요하지만 권한 창이 뜨지 않습니다. 키체인은 Claude Code가 토큰을 갱신할 때마다 권한을 다시 묻습니다.",
        "es": "Chrome requiere una pestaña de claude.ai con sesión iniciada y nunca pide permiso; la vía del llavero lo pide otra vez cada vez que Claude Code renueva su token.",
        "fr": "Chrome nécessite un onglet claude.ai connecté et ne demande jamais d'autorisation ; la voie du trousseau en redemande à chaque renouvellement de jeton.",
    ],

    // MARK: 审批日志窗口
    "log.windowTitle": [
        "en": "Approval Log", "zh": "审批日志",
        "ja": "承認ログ", "ko": "승인 로그",
        "es": "Registro de aprobaciones", "fr": "Journal d'approbation",
    ],
    "log.empty": [
        "en": "No approvals recorded yet", "zh": "暂无审批记录",
        "ja": "まだ承認記録はありません", "ko": "아직 승인 기록이 없습니다",
        "es": "Aún no hay aprobaciones registradas", "fr": "Aucune approbation enregistrée",
    ],
    "log.refresh": [
        "en": "Refresh", "zh": "刷新", "ja": "更新", "ko": "새로고침",
        "es": "Actualizar", "fr": "Actualiser",
    ],
    "log.reveal": [
        "en": "Show in Finder", "zh": "在 Finder 中显示",
        "ja": "Finder で表示", "ko": "Finder에서 보기",
        "es": "Mostrar en Finder", "fr": "Afficher dans le Finder",
    ],
    "log.clear": [
        "en": "Clear", "zh": "清空", "ja": "消去", "ko": "지우기",
        "es": "Borrar", "fr": "Effacer",
    ],
    "log.clearConfirm": [
        "en": "Clear all approval log entries?", "zh": "清空所有审批日志记录？",
        "ja": "すべての承認ログを消去しますか？", "ko": "모든 승인 로그를 지울까요?",
        "es": "¿Borrar todo el registro de aprobaciones?", "fr": "Effacer tout le journal d'approbation ?",
    ],
    "log.danger": [
        "en": "Blacklist", "zh": "黑名单",
        "ja": "ブラックリスト", "ko": "블랙리스트",
        "es": "Lista negra", "fr": "Liste noire",
    ],
    "log.allow": [
        "en": "Allowed", "zh": "放行", "ja": "許可", "ko": "허용",
        "es": "Permitido", "fr": "Autorisé",
    ],
    "log.deny": [
        "en": "Denied", "zh": "拒绝", "ja": "拒否", "ko": "거부",
        "es": "Rechazado", "fr": "Refusé",
    ],
    "log.ask": [
        "en": "To terminal", "zh": "交回终端",
        "ja": "ターミナルへ", "ko": "터미널로",
        "es": "Al terminal", "fr": "Au terminal",
    ],
    "gate.allowlist": [
        "en": "Allowlist", "zh": "白名单",
        "ja": "許可リスト", "ko": "허용 목록",
        "es": "Lista de permitidos", "fr": "Liste blanche",
    ],
    "gate.smartgate": [
        "en": "Smart gate", "zh": "智能放行",
        "ja": "スマートゲート", "ko": "스마트 게이트",
        "es": "Puerta inteligente", "fr": "Portail intelligent",
    ],
    "gate.gesture": [
        "en": "Gesture", "zh": "手势",
        "ja": "ジェスチャー", "ko": "제스처",
        "es": "Gesto", "fr": "Geste",
    ],
    "gate.alwaysAllow": [
        "en": "Always allow", "zh": "总是允许",
        "ja": "常に許可", "ko": "항상 허용",
        "es": "Permitir siempre", "fr": "Toujours autoriser",
    ],
    "gate.timeout": [
        "en": "Timed out", "zh": "超时",
        "ja": "タイムアウト", "ko": "시간 초과",
        "es": "Tiempo agotado", "fr": "Délai dépassé",
    ],
    "gate.suspended": [
        "en": "Locked/asleep", "zh": "锁屏/睡眠",
        "ja": "ロック/スリープ", "ko": "잠금/절전",
        "es": "Bloqueado/reposo", "fr": "Verrouillé/veille",
    ],
    "gate.gatingOff": [
        "en": "Gating off", "zh": "拦截关闭",
        "ja": "ゲート無効", "ko": "게이트 꺼짐",
        "es": "Control desactivado", "fr": "Contrôle désactivé",
    ],
    "log.addAllowlist": [
        "en": "Allowlist", "zh": "加入白名单",
        "ja": "許可リストへ", "ko": "허용 목록에 추가",
        "es": "Permitir", "fr": "Autoriser",
    ],
    "log.addAllowlist.help": [
        "en": "Add this exact command to trusted commands — it will skip the gesture from now on",
        "zh": "把这条命令加入信任命令，以后同样命令免审直接放行",
        "ja": "このコマンドを信頼済みに追加し、以後はジェスチャーを省略します",
        "ko": "이 명령을 신뢰 명령에 추가하여 이후 제스처를 건너뜁니다",
        "es": "Añadir este comando exacto a los comandos de confianza — se saltará el gesto a partir de ahora",
        "fr": "Ajouter cette commande exacte aux commandes de confiance — le geste sera ignoré désormais",
    ],
    "log.inAllowlist": [
        "en": "In allowlist", "zh": "已在白名单",
        "ja": "許可リスト済み", "ko": "허용 목록에 있음",
        "es": "En la lista", "fr": "Dans la liste",
    ],
    "app.name": [
        "en": "Gesture Approve", "zh": "手势审批",
        "ja": "ジェスチャー承認", "ko": "제스처 승인",
        "es": "Gesture Approve", "fr": "Gesture Approve",
    ],

    // MARK: 给 hook 的判定理由（会显示在终端）
    "reply.notReady": [
        "en": "Service not ready", "zh": "服务未就绪",
        "ja": "サービス未準備", "ko": "서비스가 준비되지 않음",
        "es": "Servicio no disponible", "fr": "Service non prêt",
    ],
    "reply.gatingOff": [
        "en": "Approval gating is off", "zh": "审批拦截已关闭",
        "ja": "承認ゲートは無効です", "ko": "승인 게이트가 꺼져 있음",
        "es": "Control de aprobación desactivado", "fr": "Contrôle d'approbation désactivé",
    ],
    "reply.suspended": [
        "en": "Screen locked / asleep — back to terminal prompt",
        "zh": "屏幕锁定/睡眠中，交回终端审批",
        "ja": "画面ロック/スリープ中 — ターミナルに戻します",
        "ko": "화면 잠금/절전 중 — 터미널로 되돌림",
        "es": "Pantalla bloqueada / en reposo — vuelve al terminal",
        "fr": "Écran verrouillé / en veille — retour au terminal",
    ],
    "reply.allowlist": [
        "en": "Auto-allowed by allowlist", "zh": "白名单自动放行",
        "ja": "許可リストにより自動承認", "ko": "허용 목록으로 자동 통과",
        "es": "Permitido por la lista de permitidos", "fr": "Autorisé par la liste blanche",
    ],
    "reply.smartgate": [
        "en": "Auto-allowed by smart gate (local LLM)", "zh": "智能放行（本地 LLM）",
        "ja": "スマートゲートにより自動承認（ローカル LLM）", "ko": "스마트 게이트 자동 통과（로컬 LLM）",
        "es": "Permitido por la puerta inteligente (LLM local)", "fr": "Autorisé par le portail intelligent (LLM local)",
    ],
    "reply.approved": [
        "en": "👍 Approved", "zh": "👍 通过", "ja": "👍 承認", "ko": "👍 승인",
        "es": "👍 Aprobado", "fr": "👍 Approuvé",
    ],
    "reply.denied": [
        "en": "🖐 Denied", "zh": "🖐 拒绝", "ja": "🖐 拒否", "ko": "🖐 거부",
        "es": "🖐 Rechazado", "fr": "🖐 Refusé",
    ],
    "reply.timeout": [
        "en": "Timed out — back to terminal prompt", "zh": "超时，交回终端审批",
        "ja": "タイムアウト — ターミナルに戻します", "ko": "시간 초과 — 터미널로 되돌림",
        "es": "Tiempo agotado — vuelve al terminal", "fr": "Délai dépassé — retour au terminal",
    ],

    // MARK: 测试结果通知
    "test.operation": [
        "en": "Test gesture recognition", "zh": "测试手势识别",
        "ja": "ジェスチャー認識のテスト", "ko": "제스처 인식 테스트",
        "es": "Probar reconocimiento de gestos", "fr": "Tester la reconnaissance des gestes",
    ],
    "test.approved": [
        "en": "✅ Approved (👍)", "zh": "✅ 已通过（👍）",
        "ja": "✅ 承認しました（👍）", "ko": "✅ 승인됨 (👍)",
        "es": "✅ Aprobado (👍)", "fr": "✅ Approuvé (👍)",
    ],
    "test.denied": [
        "en": "🛑 Denied (🖐)", "zh": "🛑 已拒绝（🖐）",
        "ja": "🛑 拒否しました（🖐）", "ko": "🛑 거부됨 (🖐)",
        "es": "🛑 Rechazado (🖐)", "fr": "🛑 Refusé (🖐)",
    ],
    "test.timeout": [
        "en": "⌛️ No response (real approvals fall back to the terminal)",
        "zh": "⌛️ 超时未操作（真实审批时会交回终端）",
        "ja": "⌛️ 操作なし（実際の承認ではターミナルに戻ります）",
        "ko": "⌛️ 응답 없음 (실제 승인 시 터미널로 되돌립니다)",
        "es": "⌛️ Sin respuesta (las aprobaciones reales vuelven al terminal)",
        "fr": "⌛️ Aucune réponse (les vraies approbations reviennent au terminal)",
    ],
    "test.notifyTitle": [
        "en": "Gesture Approve · Test result", "zh": "手势审批 · 测试结果",
        "ja": "ジェスチャー承認 · テスト結果", "ko": "제스처 승인 · 테스트 결과",
        "es": "Gesture Approve · Resultado de la prueba", "fr": "Gesture Approve · Résultat du test",
    ],

    // MARK: 固件刷写窗
    "firmware.windowTitle": [
        "en": "Flash ESP32-CAM firmware", "zh": "刷写 ESP32-CAM 固件",
        "ja": "ESP32-CAM ファームウェアを書き込む", "ko": "ESP32-CAM 펌웨어 플래시",
        "es": "Flashear firmware del ESP32-CAM", "fr": "Flasher le firmware de l'ESP32-CAM",
    ],
    "firmware.title": [
        "en": "Turn an ESP32-CAM into an approval camera", "zh": "把 ESP32-CAM 刷成审批摄像头",
        "ja": "ESP32-CAM を承認用カメラにする", "ko": "ESP32-CAM을 승인용 카메라로 만들기",
        "es": "Convierte un ESP32-CAM en cámara de aprobación",
        "fr": "Transformer un ESP32-CAM en caméra d'approbation",
    ],
    "firmware.intro": [
        "en": "The ESP32-CAM is a cheap little camera module. After flashing the matching firmware, it streams video to your Mac over USB and can recognize gestures in place of the built-in camera.",
        "zh": "ESP32-CAM 是一块很便宜的带摄像头的小模块。刷入配套固件后，它就能通过 USB 把画面传给电脑，代替自带摄像头识别手势。",
        "ja": "ESP32-CAM は安価な小型カメラモジュールです。専用ファームウェアを書き込むと、USB 経由で映像を Mac に送り、内蔵カメラの代わりにジェスチャーを認識できます。",
        "ko": "ESP32-CAM은 저렴한 소형 카메라 모듈입니다. 전용 펌웨어를 플래시하면 USB로 Mac에 영상을 보내 내장 카메라 대신 제스처를 인식할 수 있습니다.",
        "es": "El ESP32-CAM es un módulo de cámara pequeño y económico. Tras flashear el firmware correspondiente, envía vídeo al Mac por USB y reconoce gestos en lugar de la cámara integrada.",
        "fr": "L'ESP32-CAM est un petit module caméra bon marché. Après avoir flashé le firmware adapté, il envoie la vidéo au Mac via USB et reconnaît les gestes à la place de la caméra intégrée.",
    ],
    "firmware.step1": [
        "en": "Connect the ESP32-CAM to your Mac with a USB-to-serial adapter",
        "zh": "用 USB-串口适配器把 ESP32-CAM 接到电脑",
        "ja": "USB-シリアル変換アダプタで ESP32-CAM を Mac に接続",
        "ko": "USB-시리얼 어댑터로 ESP32-CAM을 Mac에 연결",
        "es": "Conecta el ESP32-CAM al Mac con un adaptador USB-serie",
        "fr": "Branchez l'ESP32-CAM au Mac avec un adaptateur USB-série",
    ],
    "firmware.step2": [
        "en": "Click \"Start flashing\" and wait for \"Flash succeeded\"",
        "zh": "点「开始刷写」，等待出现「刷写成功」",
        "ja": "「書き込み開始」をクリックし、「書き込み成功」を待つ",
        "ko": "\"플래시 시작\"을 클릭하고 \"플래시 성공\"을 기다리기",
        "es": "Haz clic en «Iniciar flasheo» y espera a «Flasheo correcto»",
        "fr": "Cliquez sur « Démarrer le flash » et attendez « Flash réussi »",
    ],
    "firmware.step3": [
        "en": "Back in Settings, set the video source to \"ESP32-CAM (serial)\"",
        "zh": "回到设置，把视频输入源选成「ESP32-CAM（串口）」",
        "ja": "設定に戻り、映像入力を「ESP32-CAM（シリアル）」に設定",
        "ko": "설정으로 돌아가 비디오 입력을 \"ESP32-CAM(시리얼)\"로 선택",
        "es": "Vuelve a Ajustes y elige la fuente de vídeo «ESP32-CAM (serie)»",
        "fr": "Dans Réglages, choisissez la source vidéo « ESP32-CAM (série) »",
    ],
    "firmware.runLabel": [
        "en": "Start flashing", "zh": "开始刷写", "ja": "書き込み開始",
        "ko": "플래시 시작", "es": "Iniciar flasheo", "fr": "Démarrer le flash",
    ],
    "firmware.rerunLabel": [
        "en": "Flash again", "zh": "重新刷写", "ja": "再書き込み",
        "ko": "다시 플래시", "es": "Volver a flashear", "fr": "Reflasher",
    ],
    "firmware.footer": [
        "en": "No PlatformIO needed. A ~20 MB tool downloads automatically the first time. Bare FTDI has no auto-reset: tie GPIO0 to GND → reset → retry.",
        "zh": "无需安装 PlatformIO。首次会自动下载约 20MB 小工具。裸 FTDI 没自动复位：GPIO0 接 GND → 复位 → 重试。",
        "ja": "PlatformIO は不要。初回は約 20MB のツールを自動ダウンロードします。素の FTDI は自動リセット非対応：GPIO0 を GND に → リセット → 再試行。",
        "ko": "PlatformIO 불필요. 처음에는 약 20MB 도구를 자동으로 내려받습니다. 베어 FTDI는 자동 리셋이 없음: GPIO0을 GND에 연결 → 리셋 → 재시도.",
        "es": "No requiere PlatformIO. La primera vez se descarga una herramienta de ~20 MB. FTDI sin reset automático: conecta GPIO0 a GND → reinicia → reintenta.",
        "fr": "PlatformIO inutile. Un outil d'environ 20 Mo se télécharge automatiquement la première fois. FTDI nu sans reset auto : reliez GPIO0 à GND → reset → réessayez.",
    ],
    "firmware.running": [
        "en": "Flashing…", "zh": "正在刷写…", "ja": "書き込み中…",
        "ko": "플래시 중…", "es": "Flasheando…", "fr": "Flash en cours…",
    ],
    "firmware.success": [
        "en": "Flash succeeded", "zh": "刷写成功", "ja": "書き込み成功",
        "ko": "플래시 성공", "es": "Flasheo correcto", "fr": "Flash réussi",
    ],
    "firmware.failed": [
        "en": "Flash failed", "zh": "刷写失败", "ja": "書き込み失敗",
        "ko": "플래시 실패", "es": "Flasheo fallido", "fr": "Échec du flash",
    ],
    "firmware.idleHint": [
        "en": "Connect the device, click \"Start flashing\", and watch progress here.",
        "zh": "把设备接好后点「开始刷写」，这里实时显示进度。",
        "ja": "デバイスを接続して「書き込み開始」を押すと、ここに進捗が表示されます。",
        "ko": "기기를 연결하고 \"플래시 시작\"을 누르면 여기에 진행 상황이 표시됩니다.",
        "es": "Conecta el dispositivo, pulsa «Iniciar flasheo» y verás el progreso aquí.",
        "fr": "Branchez l'appareil, cliquez sur « Démarrer le flash » et suivez la progression ici.",
    ],

    // MARK: MediaPipe 下载窗
    "mp.windowTitle": [
        "en": "Download the MediaPipe engine", "zh": "下载 MediaPipe 识别引擎",
        "ja": "MediaPipe 認識エンジンをダウンロード", "ko": "MediaPipe 인식 엔진 다운로드",
        "es": "Descargar el motor MediaPipe", "fr": "Télécharger le moteur MediaPipe",
    ],
    "mp.title": [
        "en": "Download MediaPipe (more accurate recognition)", "zh": "下载 MediaPipe（更准的手势识别）",
        "ja": "MediaPipe をダウンロード（より高精度な認識）", "ko": "MediaPipe 다운로드 (더 정확한 인식)",
        "es": "Descargar MediaPipe (reconocimiento más preciso)",
        "fr": "Télécharger MediaPipe (reconnaissance plus précise)",
    ],
    "mp.intro": [
        "en": "MediaPipe is Google's pretrained gesture model — more accurate and more tolerant of lighting and angle. It needs a ~300 MB Python runtime (downloaded once).",
        "zh": "MediaPipe 是 Google 的预训练手势模型，识别更准、更耐受光线与角度。它需要一个约 300MB 的 Python 运行时（仅下载一次）。",
        "ja": "MediaPipe は Google の学習済みジェスチャーモデルで、より高精度で光や角度に強いです。約 300MB の Python ランタイムが必要です（初回のみ）。",
        "ko": "MediaPipe는 Google의 사전 학습 제스처 모델로 더 정확하고 조명·각도에 강합니다. 약 300MB의 Python 런타임이 필요합니다(최초 1회).",
        "es": "MediaPipe es el modelo de gestos preentrenado de Google: más preciso y tolerante a la luz y al ángulo. Necesita un entorno Python de ~300 MB (se descarga una vez).",
        "fr": "MediaPipe est le modèle de gestes pré-entraîné de Google — plus précis et tolérant à la lumière et à l'angle. Il nécessite un runtime Python d'environ 300 Mo (téléchargé une seule fois).",
    ],
    "mp.step1": [
        "en": "Click \"Start download\" to set up Python and fetch the model automatically",
        "zh": "点「开始下载」，自动建好 Python 环境并下载模型",
        "ja": "「ダウンロード開始」を押すと、Python 環境を構築しモデルを自動取得します",
        "ko": "\"다운로드 시작\"을 누르면 Python 환경을 만들고 모델을 자동으로 받습니다",
        "es": "Haz clic en «Iniciar descarga» para preparar Python y obtener el modelo automáticamente",
        "fr": "Cliquez sur « Démarrer le téléchargement » pour configurer Python et récupérer le modèle automatiquement",
    ],
    "mp.step2": [
        "en": "When it finishes, MediaPipe is enabled automatically back in Settings",
        "zh": "完成后回到设置即自动启用 MediaPipe",
        "ja": "完了後、設定に戻ると MediaPipe が自動的に有効になります",
        "ko": "완료되면 설정으로 돌아갈 때 MediaPipe가 자동으로 켜집니다",
        "es": "Al terminar, MediaPipe se activa automáticamente en Ajustes",
        "fr": "Une fois terminé, MediaPipe est activé automatiquement dans Réglages",
    ],
    "mp.runLabel": [
        "en": "Start download", "zh": "开始下载", "ja": "ダウンロード開始",
        "ko": "다운로드 시작", "es": "Iniciar descarga", "fr": "Démarrer le téléchargement",
    ],
    "mp.rerunLabel": [
        "en": "Download again", "zh": "重新下载", "ja": "再ダウンロード",
        "ko": "다시 다운로드", "es": "Descargar de nuevo", "fr": "Retélécharger",
    ],
    "mp.footer": [
        "en": "About 300 MB; time depends on your connection. No app restart needed.",
        "zh": "下载约 300MB，耗时取决于网速。完成后无需重启 app。",
        "ja": "ダウンロードは約 300MB、所要時間は回線速度によります。完了後にアプリの再起動は不要です。",
        "ko": "약 300MB이며 소요 시간은 네트워크 속도에 따라 다릅니다. 완료 후 앱 재시작은 필요 없습니다.",
        "es": "Unos 300 MB; el tiempo depende de tu conexión. No hace falta reiniciar la app.",
        "fr": "Environ 300 Mo ; la durée dépend de votre connexion. Aucun redémarrage de l'app nécessaire.",
    ],
    "mp.running": [
        "en": "Downloading and installing…", "zh": "正在下载安装…",
        "ja": "ダウンロード・インストール中…", "ko": "다운로드 및 설치 중…",
        "es": "Descargando e instalando…", "fr": "Téléchargement et installation…",
    ],
    "mp.success": [
        "en": "Installation complete", "zh": "安装完成", "ja": "インストール完了",
        "ko": "설치 완료", "es": "Instalación completada", "fr": "Installation terminée",
    ],
    "mp.failed": [
        "en": "Installation failed", "zh": "安装失败", "ja": "インストール失敗",
        "ko": "설치 실패", "es": "Instalación fallida", "fr": "Échec de l'installation",
    ],
    "mp.idleHint": [
        "en": "Click \"Start download\" to begin; progress shows here.",
        "zh": "点「开始下载」开始安装，这里实时显示进度。",
        "ja": "「ダウンロード開始」を押すとインストールが始まり、ここに進捗が表示されます。",
        "ko": "\"다운로드 시작\"을 누르면 설치가 시작되고 여기에 진행 상황이 표시됩니다.",
        "es": "Pulsa «Iniciar descarga» para empezar; el progreso aparece aquí.",
        "fr": "Cliquez sur « Démarrer le téléchargement » pour commencer ; la progression s'affiche ici.",
    ],

    // MARK: 智能放行守门员下载窗
    "gk.windowTitle": [
        "en": "Smart Gate Setup", "zh": "智能放行组件", "ja": "スマートゲート設定",
        "ko": "스마트 게이트 설정", "es": "Configurar puerta inteligente", "fr": "Configuration du portail intelligent",
    ],
    "gk.title": [
        "en": "Download the local LLM gatekeeper", "zh": "下载本地 LLM 守门员组件",
        "ja": "ローカル LLM ゲートキーパーをダウンロード", "ko": "로컬 LLM 게이트키퍼 다운로드",
        "es": "Descargar el guardián LLM local", "fr": "Télécharger le gardien LLM local",
    ],
    "gk.intro": [
        "en": "A small helper (~50MB) plus the local model (~1GB) — both download here. Once it says ready, everything works with no further wait. Runs fully on your Mac.",
        "zh": "一个小巧的 helper（约 50MB）加本地模型（约 1GB）——都在这里一并下好。显示「就绪」后即可直接用、不再额外等待。全程不离开你的 Mac。",
        "ja": "小さなヘルパー（約50MB）とローカルモデル（約1GB）をここで一括ダウンロード。「準備完了」になればすぐ使え、追加の待ち時間はありません。すべて Mac 内で完結します。",
        "ko": "작은 헬퍼(~50MB)와 로컬 모델(~1GB)을 여기서 한 번에 다운로드합니다. \"준비됨\"이 표시되면 추가 대기 없이 바로 작동합니다. 모든 것이 Mac 안에서 처리됩니다.",
        "es": "Un pequeño ayudante (~50MB) más el modelo local (~1GB), ambos se descargan aquí. Cuando diga «listo», todo funciona sin más espera. Funciona totalmente en tu Mac.",
        "fr": "Un petit assistant (~50 Mo) plus le modèle local (~1 Go), tout se télécharge ici. Une fois « prêt », tout fonctionne sans attente supplémentaire. Entièrement sur votre Mac.",
    ],
    "gk.step1": [
        "en": "Download the prebuilt helper from GitHub Releases.",
        "zh": "从 GitHub Releases 下载预编译的 helper。",
        "ja": "GitHub Releases からビルド済みヘルパーをダウンロード。",
        "ko": "GitHub Releases에서 미리 빌드된 헬퍼를 다운로드.",
        "es": "Descargar el ayudante precompilado desde GitHub Releases.",
        "fr": "Télécharger l'assistant précompilé depuis GitHub Releases.",
    ],
    "gk.step2": [
        "en": "Unpack to Application Support and clear quarantine.",
        "zh": "解压到 Application Support 并清除隔离属性。",
        "ja": "Application Support に展開し、隔離属性を解除。",
        "ko": "Application Support에 풀고 격리 속성 제거.",
        "es": "Descomprimir en Application Support y quitar la cuarentena.",
        "fr": "Décompresser dans Application Support et lever la quarantaine.",
    ],
    "gk.step3": [
        "en": "Prefetch the model weights (~1GB) so it's ready to use.",
        "zh": "预取模型权重（约 1GB），下完即可直接用。",
        "ja": "モデルの重み（約1GB）を事前取得し、すぐ使える状態に。",
        "ko": "모델 가중치(~1GB)를 미리 받아 바로 사용 가능하게 합니다.",
        "es": "Precargar los pesos del modelo (~1GB) para dejarlo listo.",
        "fr": "Pré-télécharger les poids du modèle (~1 Go) pour qu'il soit prêt.",
    ],
    "gk.runLabel": [
        "en": "Start download", "zh": "开始下载", "ja": "ダウンロード開始",
        "ko": "다운로드 시작", "es": "Iniciar descarga", "fr": "Démarrer le téléchargement",
    ],
    "gk.rerunLabel": [
        "en": "Re-download", "zh": "重新下载", "ja": "再ダウンロード",
        "ko": "다시 다운로드", "es": "Volver a descargar", "fr": "Retélécharger",
    ],
    "gk.footer": [
        "en": "Runs fully on-device. If download fails, the gesture flow keeps working.",
        "zh": "全程本地运行。下载失败也不影响：仍按手势审批。",
        "ja": "完全にオンデバイスで動作。ダウンロードに失敗してもジェスチャー審査は機能します。",
        "ko": "완전히 온디바이스로 실행됩니다. 다운로드가 실패해도 제스처 흐름은 계속 작동합니다.",
        "es": "Funciona totalmente en el dispositivo. Si la descarga falla, el gesto sigue funcionando.",
        "fr": "Fonctionne entièrement sur l'appareil. En cas d'échec, le geste continue de fonctionner.",
    ],
    "gk.running": [
        "en": "Downloading…", "zh": "下载中…", "ja": "ダウンロード中…",
        "ko": "다운로드 중…", "es": "Descargando…", "fr": "Téléchargement…",
    ],
    "gk.success": [
        "en": "Ready", "zh": "已就绪", "ja": "準備完了", "ko": "준비됨",
        "es": "Listo", "fr": "Prêt",
    ],
    "gk.failed": [
        "en": "Failed", "zh": "失败", "ja": "失敗", "ko": "실패",
        "es": "Falló", "fr": "Échec",
    ],
    "gk.idleHint": [
        "en": "Click \"Start download\" to begin; progress shows here.",
        "zh": "点「开始下载」开始，这里实时显示进度。",
        "ja": "「ダウンロード開始」を押すと始まり、ここに進捗が表示されます。",
        "ko": "\"다운로드 시작\"을 누르면 시작되고 여기에 진행 상황이 표시됩니다.",
        "es": "Pulsa «Iniciar descarga» para empezar; el progreso aparece aquí.",
        "fr": "Cliquez sur « Démarrer le téléchargement » ; la progression s'affiche ici.",
    ],

    // MARK: 刘海卡片
    "card.needApproval": [
        "en": "APPROVAL NEEDED", "zh": "需要审批", "ja": "承認が必要",
        "ko": "승인 필요", "es": "APROBACIÓN NECESARIA", "fr": "APPROBATION REQUISE",
    ],
    "card.approve": [
        "en": "Approve", "zh": "通过", "ja": "承認", "ko": "승인",
        "es": "Aprobar", "fr": "Approuver",
    ],
    "card.deny": [
        "en": "Deny", "zh": "拒绝", "ja": "拒否", "ko": "거부",
        "es": "Rechazar", "fr": "Refuser",
    ],
    "card.hint": [
        "en": "Gesture, or press ⌃⇧Y to approve / ⌃⇧N to deny",
        "zh": "比手势，或按 ⌃⇧Y 通过 / ⌃⇧N 拒绝",
        "ja": "ジェスチャー、または ⌃⇧Y で承認 / ⌃⇧N で拒否",
        "ko": "제스처를 하거나 ⌃⇧Y 승인 / ⌃⇧N 거부",
        "es": "Haz un gesto, o pulsa ⌃⇧Y para aprobar / ⌃⇧N para rechazar",
        "fr": "Faites un geste, ou appuyez sur ⌃⇧Y pour approuver / ⌃⇧N pour refuser",
    ],
    "card.approved": [
        "en": "Approved", "zh": "已通过", "ja": "承認しました",
        "ko": "승인됨", "es": "Aprobado", "fr": "Approuvé",
    ],
    "card.denied": [
        "en": "Denied", "zh": "已拒绝", "ja": "拒否しました",
        "ko": "거부됨", "es": "Rechazado", "fr": "Refusé",
    ],
    "card.alwaysAllow": [
        "en": "Always allow this", "zh": "总是允许这条",
        "ja": "今後は自動許可", "ko": "항상 허용",
        "es": "Permitir siempre", "fr": "Toujours autoriser",
    ],
    "alwaysAllow.notifyTitle": [
        "en": "Added to auto-allow", "zh": "已加入自动放行",
        "ja": "自動許可に追加しました", "ko": "자동 허용에 추가됨",
        "es": "Añadido a auto-permitir", "fr": "Ajouté à l'autorisation auto",
    ],
    "card.noOperation": [
        "en": "(no operation name)", "zh": "（未提供操作名）",
        "ja": "（操作名なし）", "ko": "(작업 이름 없음)",
        "es": "(sin nombre de operación)", "fr": "(aucun nom d'opération)",
    ],

    // MARK: 设置窗
    "settings.windowTitle": [
        "en": "Gesture Approve · Settings", "zh": "手势审批 · 设置",
        "ja": "ジェスチャー承認 · 設定", "ko": "제스처 승인 · 설정",
        "es": "Gesture Approve · Ajustes", "fr": "Gesture Approve · Réglages",
    ],
    "settings.section.connect": [
        "en": "Connect AI tools", "zh": "接入 AI 工具",
        "ja": "AI ツールと連携", "ko": "AI 도구 연결",
        "es": "Conectar herramientas de IA", "fr": "Connecter les outils d'IA",
    ],
    "settings.connectGemini": [
        "en": "Connect Gemini CLI", "zh": "接入 Gemini CLI",
        "ja": "Gemini CLI と連携", "ko": "Gemini CLI 연결",
        "es": "Conectar Gemini CLI", "fr": "Connecter Gemini CLI",
    ],
    "settings.connectKimi": [
        "en": "Connect Kimi CLI", "zh": "接入 Kimi CLI",
        "ja": "Kimi CLI と連携", "ko": "Kimi CLI 연결",
        "es": "Conectar Kimi CLI", "fr": "Connecter Kimi CLI",
    ],
    "settings.connectClaude": [
        "en": "Connect Claude Code", "zh": "接入 Claude Code",
        "ja": "Claude Code と連携", "ko": "Claude Code 연결",
        "es": "Conectar Claude Code", "fr": "Connecter Claude Code",
    ],
    "settings.connectCodex": [
        "en": "Connect Codex", "zh": "接入 Codex",
        "ja": "Codex と連携", "ko": "Codex 연결",
        "es": "Conectar Codex", "fr": "Connecter Codex",
    ],
    "settings.connectCodexNote": [
        "en": "After enabling, run /hooks in Codex and trust the gesture-approve hook — untrusted command hooks are skipped.",
        "zh": "开启后，在 Codex 里执行 /hooks 并信任 gesture-approve 这条 hook——未信任的命令 hook 会被跳过。",
        "ja": "有効化後、Codex で /hooks を実行し gesture-approve フックを信頼してください。未信頼のコマンドフックはスキップされます。",
        "ko": "활성화 후 Codex에서 /hooks를 실행해 gesture-approve 후크를 신뢰하세요. 신뢰되지 않은 명령 후크는 건너뜁니다.",
        "es": "Tras activarlo, ejecuta /hooks en Codex y confía en el hook gesture-approve; los hooks de comando no confiables se omiten.",
        "fr": "Après activation, exécutez /hooks dans Codex et faites confiance au hook gesture-approve — les hooks de commande non approuvés sont ignorés.",
    ],
    "settings.connectDesc": [
        "en": "Turning it on writes the matching config (your original is backed up) and applies to new CC/Codex sessions; turning it off removes it.",
        "zh": "开启即自动写入对应配置（已自动备份原文件），新开 CC/Codex 会话生效；关闭即移除。",
        "ja": "オンにすると対応する設定を自動で書き込み（元ファイルはバックアップ済み）、新しい CC/Codex セッションで有効になります。オフにすると削除します。",
        "ko": "켜면 해당 설정을 자동으로 기록하고(원본은 백업됨) 새 CC/Codex 세션부터 적용됩니다. 끄면 제거됩니다.",
        "es": "Al activarlo se escribe la configuración correspondiente (se respalda el original) y se aplica a las nuevas sesiones de CC/Codex; al desactivarlo se elimina.",
        "fr": "L'activer écrit la configuration correspondante (l'original est sauvegardé) et s'applique aux nouvelles sessions CC/Codex ; le désactiver la supprime.",
    ],
    "settings.hotkeyDesc": [
        "en": "During approval: ⌃⇧Y approve · ⌃⇧N deny (or gesture). On timeout / when not connected, it falls back to the normal terminal prompt.",
        "zh": "审批时：⌃⇧Y 通过 · ⌃⇧N 拒绝（或比手势）；超时/未接入会回退到终端正常审批。",
        "ja": "承認時：⌃⇧Y で承認 · ⌃⇧N で拒否（またはジェスチャー）。タイムアウトや未連携の場合はターミナルの通常承認に戻ります。",
        "ko": "승인 시: ⌃⇧Y 승인 · ⌃⇧N 거부 (또는 제스처). 시간 초과/미연결 시 터미널의 기본 승인으로 되돌아갑니다.",
        "es": "Durante la aprobación: ⌃⇧Y aprobar · ⌃⇧N rechazar (o gesto). Si caduca o no está conectado, vuelve al terminal normal.",
        "fr": "Pendant l'approbation : ⌃⇧Y approuver · ⌃⇧N refuser (ou geste). En cas de délai dépassé ou de non-connexion, retour au terminal normal.",
    ],
    "settings.section.video": [
        "en": "Video source", "zh": "视频输入源", "ja": "映像入力",
        "ko": "비디오 입력", "es": "Fuente de vídeo", "fr": "Source vidéo",
    ],
    "settings.refresh.help": [
        "en": "Refresh device list", "zh": "刷新设备列表",
        "ja": "デバイス一覧を更新", "ko": "기기 목록 새로고침",
        "es": "Actualizar lista de dispositivos", "fr": "Actualiser la liste des appareils",
    ],
    "settings.rotation.none": [
        "en": "No rotation", "zh": "不旋转", "ja": "回転なし",
        "ko": "회전 없음", "es": "Sin rotación", "fr": "Aucune rotation",
    ],
    "settings.rotation.help": [
        "en": "Rotate the whole image", "zh": "画面整体旋转角度",
        "ja": "映像全体の回転角度", "ko": "전체 화면 회전 각도",
        "es": "Ángulo de rotación de la imagen", "fr": "Angle de rotation de l'image",
    ],
    "settings.esp32.noPreview": [
        "en": "ESP32-CAM serial source · no live preview", "zh": "ESP32-CAM 串口源 · 无实时预览",
        "ja": "ESP32-CAM シリアル入力 · ライブプレビューなし", "ko": "ESP32-CAM 시리얼 입력 · 실시간 미리보기 없음",
        "es": "Fuente serie ESP32-CAM · sin vista previa", "fr": "Source série ESP32-CAM · pas d'aperçu en direct",
    ],
    "settings.esp32.noPreviewHint": [
        "en": "After flashing and connecting, verify with \"Test approval card\"",
        "zh": "刷好固件并接上后，用「测试审批卡片」验证",
        "ja": "ファームウェア書き込みと接続後、「承認カードをテスト」で確認してください",
        "ko": "펌웨어 플래시 후 연결하고 \"승인 카드 테스트\"로 확인하세요",
        "es": "Tras flashear y conectar, verifica con «Probar tarjeta de aprobación»",
        "fr": "Après le flash et la connexion, vérifiez avec « Tester la carte d'approbation »",
    ],
    "settings.section.engine": [
        "en": "Recognition engine", "zh": "识别引擎", "ja": "認識エンジン",
        "ko": "인식 엔진", "es": "Motor de reconocimiento", "fr": "Moteur de reconnaissance",
    ],
    "settings.engine.vision": [
        "en": "Apple Vision (built-in · tiny)", "zh": "Apple Vision（内置 · 体积小）",
        "ja": "Apple Vision（内蔵 · 軽量）", "ko": "Apple Vision (내장 · 경량)",
        "es": "Apple Vision (integrado · ligero)", "fr": "Apple Vision (intégré · léger)",
    ],
    "settings.engine.mediapipe": [
        "en": "MediaPipe (more accurate · ~300 MB download)", "zh": "MediaPipe（更准 · 需下载 ~300MB）",
        "ja": "MediaPipe（高精度 · 約300MBのダウンロード）", "ko": "MediaPipe (더 정확 · 약 300MB 다운로드)",
        "es": "MediaPipe (más preciso · descarga de ~300 MB)", "fr": "MediaPipe (plus précis · téléchargement d'environ 300 Mo)",
    ],
    "settings.engine.installed": [
        "en": "Installed", "zh": "已安装", "ja": "インストール済み",
        "ko": "설치됨", "es": "Instalado", "fr": "Installé",
    ],
    "settings.engine.notInstalled": [
        "en": "Not installed (download to enable)", "zh": "未安装（先下载才会生效）",
        "ja": "未インストール（ダウンロードで有効化）", "ko": "설치 안 됨 (다운로드해야 적용)",
        "es": "No instalado (descárgalo para activar)", "fr": "Non installé (téléchargez pour activer)",
    ],
    "settings.engine.redownload": [
        "en": "Download again…", "zh": "重新下载…", "ja": "再ダウンロード…",
        "ko": "다시 다운로드…", "es": "Descargar de nuevo…", "fr": "Retélécharger…",
    ],
    "settings.engine.download": [
        "en": "Download…", "zh": "下载安装…", "ja": "ダウンロード…",
        "ko": "다운로드…", "es": "Descargar…", "fr": "Télécharger…",
    ],
    "settings.engine.desc": [
        "en": "Vision is built-in with zero dependencies and moderate accuracy; MediaPipe needs a ~300 MB runtime but is more accurate and stable.",
        "zh": "Vision 内置零依赖、准度一般；MediaPipe 需下载约 300MB 运行时，识别更准更稳。",
        "ja": "Vision は内蔵・依存なしで精度はそこそこ。MediaPipe は約300MBのランタイムが必要ですが、より正確で安定します。",
        "ko": "Vision은 내장·무의존성이며 정확도는 보통입니다. MediaPipe는 약 300MB 런타임이 필요하지만 더 정확하고 안정적입니다.",
        "es": "Vision es integrado, sin dependencias y de precisión media; MediaPipe necesita un runtime de ~300 MB pero es más preciso y estable.",
        "fr": "Vision est intégré, sans dépendances et de précision moyenne ; MediaPipe nécessite un runtime d'environ 300 Mo mais est plus précis et stable.",
    ],
    "settings.section.precision": [
        "en": "Recognition strictness", "zh": "识别精准度", "ja": "認識の厳しさ",
        "ko": "인식 엄격도", "es": "Rigor del reconocimiento", "fr": "Rigueur de la reconnaissance",
    ],
    "settings.precision.loose": [
        "en": "Loose", "zh": "宽松", "ja": "緩い", "ko": "느슨함",
        "es": "Flexible", "fr": "Souple",
    ],
    "settings.precision.standard": [
        "en": "Standard", "zh": "标准", "ja": "標準", "ko": "표준",
        "es": "Estándar", "fr": "Standard",
    ],
    "settings.precision.strict": [
        "en": "Strict", "zh": "严格", "ja": "厳しい", "ko": "엄격",
        "es": "Estricto", "fr": "Strict",
    ],
    "settings.section.smartgate": [
        "en": "Smart gate (local LLM)", "zh": "智能放行（本地 LLM）",
        "ja": "スマートゲート（ローカル LLM）", "ko": "스마트 게이트（로컬 LLM）",
        "es": "Puerta inteligente (LLM local)", "fr": "Portail intelligent (LLM local)",
    ],
    "settings.smartgate.enable": [
        "en": "Auto-allow obviously-safe commands via local LLM",
        "zh": "用本地 LLM 自动放行明显安全的命令",
        "ja": "ローカル LLM で明らかに安全なコマンドを自動承認",
        "ko": "로컬 LLM으로 명백히 안전한 명령 자동 통과",
        "es": "Permitir comandos obviamente seguros mediante LLM local",
        "fr": "Auto-autoriser les commandes manifestement sûres via un LLM local",
    ],
    "settings.smartgate.installed": [
        "en": "Model ready", "zh": "模型组件就绪", "ja": "モデル準備完了",
        "ko": "모델 준비됨", "es": "Modelo listo", "fr": "Modèle prêt",
    ],
    "settings.smartgate.notInstalled": [
        "en": "Component not installed — gesture still works",
        "zh": "组件未安装 — 仍按手势审批",
        "ja": "コンポーネント未インストール — ジェスチャーは有効",
        "ko": "구성요소 미설치 — 제스처는 계속 작동",
        "es": "Componente no instalado — el gesto sigue funcionando",
        "fr": "Composant non installé — le geste fonctionne toujours",
    ],
    "settings.smartgate.download": [
        "en": "Download", "zh": "下载", "ja": "ダウンロード", "ko": "다운로드",
        "es": "Descargar", "fr": "Télécharger",
    ],
    "settings.smartgate.redownload": [
        "en": "Re-download", "zh": "重新下载", "ja": "再ダウンロード", "ko": "다시 다운로드",
        "es": "Volver a descargar", "fr": "Retélécharger",
    ],
    "settings.smartgate.desc": [
        "en": "When on, a small local model (Qwen3-1.7B) judges each command; only obviously-safe ones skip the gesture. Runs fully on-device (private), adds ~1s. Dangerous commands always require a gesture (deny-list fallback). Anything uncertain or offline falls back to the gesture.",
        "zh": "开启后，本地小模型（Qwen3-1.7B）判断每条命令，只有明显安全的才免手势。全程本地运行（隐私不外泄），约多 1 秒。危险命令永远要手势（deny-list 保底）；不确定或离线一律回退手势。",
        "ja": "オンにすると、ローカルの小型モデル（Qwen3-1.7B）が各コマンドを判定し、明らかに安全なものだけジェスチャーを省略します。完全にオンデバイス（プライバシー保護）で約1秒追加。危険なコマンドは常にジェスチャーが必要（deny-list フォールバック）。不確実・オフライン時はジェスチャーに戻ります。",
        "ko": "켜면 로컬 소형 모델(Qwen3-1.7B)이 각 명령을 판단해 명백히 안전한 것만 제스처를 생략합니다. 완전 온디바이스(개인정보 보호), 약 1초 추가. 위험한 명령은 항상 제스처 필요(deny-list 폴백). 불확실하거나 오프라인이면 제스처로 되돌립니다.",
        "es": "Cuando está activo, un pequeño modelo local (Qwen3-1.7B) evalúa cada comando; solo los obviamente seguros omiten el gesto. Funciona totalmente en el dispositivo (privado), añade ~1s. Los comandos peligrosos siempre requieren gesto (lista de denegación). Lo incierto o sin conexión vuelve al gesto.",
        "fr": "Activé, un petit modèle local (Qwen3-1.7B) évalue chaque commande ; seules les commandes manifestement sûres évitent le geste. Entièrement sur l'appareil (privé), ajoute ~1s. Les commandes dangereuses exigent toujours un geste (liste de refus). En cas de doute ou hors ligne, retour au geste.",
    ],
    "settings.smartgate.hookNote": [
        "en": "Claude and Codex already have a smart hook (mode-aware / fires only when they'd prompt), so they don't need this local model. It mainly helps CLIs like Gemini and Kimi that fire on every tool call.",
        "zh": "Claude 和 Codex 已内置智能 hook(按权限模式 / 只在该问时才触发),无需本地 LLM 辅助。此功能主要惠及 Gemini、Kimi 这类每次工具调用都触发的 CLI。",
        "ja": "Claude と Codex は既にスマート hook を備えており（モード対応／確認が必要な時のみ発火）、このローカルモデルは不要です。主にツール呼び出しごとに発火する Gemini や Kimi のような CLI に有効です。",
        "ko": "Claude와 Codex는 이미 스마트 hook을 갖추고 있어(모드 인식 / 물어봐야 할 때만 발동) 이 로컬 모델이 필요 없습니다. 주로 모든 도구 호출마다 발동하는 Gemini, Kimi 같은 CLI에 유용합니다.",
        "es": "Claude y Codex ya tienen un hook inteligente (según el modo / solo se activa cuando preguntarían), así que no necesitan este modelo local. Ayuda sobre todo a CLIs como Gemini y Kimi que se activan en cada llamada de herramienta.",
        "fr": "Claude et Codex disposent déjà d'un hook intelligent (selon le mode / ne se déclenche que s'ils demanderaient), ils n'ont donc pas besoin de ce modèle local. Utile surtout pour des CLI comme Gemini et Kimi qui se déclenchent à chaque appel d'outil.",
    ],
    // MARK: Agent 完成通知（Claude Code 的 Stop hook → 桌面横幅 + Remote Hub /events）
    "settings.section.agentnotify": [
        "en": "Agent finished alerts", "zh": "Agent 完成通知",
        "ja": "エージェント完了通知", "ko": "에이전트 완료 알림",
        "es": "Avisos de agente terminado", "fr": "Alertes de fin d'agent",
    ],
    "settings.agentnotify.desc": [
        "en": "Get told the moment the agent finishes a turn. Installs a Stop hook (Claude Code: ~/.claude/settings.json · Codex: ~/.codex/config.toml). It only watches — it never blocks or changes what the agent does. Gemini and Kimi have no equivalent event.",
        "zh": "Agent 跑完一轮的那一刻就告诉你。装的是 Stop hook（Claude Code 写 ~/.claude/settings.json，Codex 写 ~/.codex/config.toml）。它只旁观，绝不阻塞或改变 agent 的行为。Gemini、Kimi 没有对应事件。",
        "ja": "エージェントが一区切りついた瞬間に知らせます。Stop hook を追加します（Claude Code は ~/.claude/settings.json、Codex は ~/.codex/config.toml）。監視するだけで、動作を止めたり変えたりしません。Gemini と Kimi には相当するイベントがありません。",
        "ko": "에이전트가 한 턴을 마치는 순간 알려줍니다. Stop hook을 설치합니다(Claude Code는 ~/.claude/settings.json, Codex는 ~/.codex/config.toml). 관찰만 할 뿐 막거나 바꾸지 않습니다. Gemini와 Kimi에는 해당 이벤트가 없습니다.",
        "es": "Te avisa en cuanto el agente termina un turno. Instala un hook Stop (Claude Code: ~/.claude/settings.json · Codex: ~/.codex/config.toml). Solo observa: nunca bloquea ni cambia lo que hace el agente. Gemini y Kimi no tienen un evento equivalente.",
        "fr": "Vous prévient dès que l'agent termine un tour. Installe un hook Stop (Claude Code : ~/.claude/settings.json · Codex : ~/.codex/config.toml). Il se contente d'observer : il ne bloque ni ne modifie l'agent. Gemini et Kimi n'ont pas d'événement équivalent.",
    ],
    "settings.agentnotify.codexTrust": [
        "en": "Codex asks once: next time you open it, the hooks review appears — press t (\"Trust all\") or the hook won't run. Your existing notify setting is left alone.",
        "zh": "Codex 需要信任一次：下次打开它会弹 hooks 审阅，按 t（Trust all）即可，否则 hook 不会运行。你已有的 notify 配置不会被动。",
        "ja": "Codex は一度だけ確認します：次回起動時に hooks レビューが出るので t（Trust all）を押してください。押さないと hook は動きません。既存の notify 設定には触れません。",
        "ko": "Codex는 한 번 확인합니다: 다음에 열면 hooks 검토가 뜨니 t(Trust all)를 누르세요. 누르지 않으면 hook이 실행되지 않습니다. 기존 notify 설정은 건드리지 않습니다.",
        "es": "Codex pregunta una vez: la próxima vez que lo abras aparecerá la revisión de hooks — pulsa t (\"Trust all\") o el hook no se ejecutará. Tu ajuste notify existente no se toca.",
        "fr": "Codex demande une fois : à la prochaine ouverture, la revue des hooks apparaît — appuyez sur t (« Trust all ») sinon le hook ne s'exécutera pas. Votre réglage notify existant n'est pas touché.",
    ],
    "settings.agentnotify.desktop": [
        "en": "Desktop notification (system banner)", "zh": "桌面通知（系统横幅）",
        "ja": "デスクトップ通知（バナー）", "ko": "데스크톱 알림(배너)",
        "es": "Notificación de escritorio (banner)", "fr": "Notification bureau (bannière)",
    ],
    "settings.agentnotify.hub": [
        "en": "Push to the Remote Hub (visible on your phone)",
        "zh": "推送到远程 Hub（手机上可见）",
        "ja": "リモート Hub に送る（スマホで見える）",
        "ko": "원격 Hub로 푸시(휴대폰에서 확인)",
        "es": "Enviar al Hub remoto (visible en el móvil)",
        "fr": "Envoyer au Hub distant (visible sur le téléphone)",
    ],
    "settings.agentnotify.hubNote": [
        "en": "Devices read them from the Hub's GET /events long-poll; the Hub page shows the latest ones at the top.",
        "zh": "设备走 Hub 的 GET /events 长轮询取；Hub 页面顶部也会显示最近几条。",
        "ja": "デバイスは Hub の GET /events（ロングポーリング）で取得します。Hub のページ上部にも最近の分が並びます。",
        "ko": "장치는 Hub의 GET /events 롱 폴링으로 가져옵니다. Hub 페이지 상단에도 최근 항목이 표시됩니다.",
        "es": "Los dispositivos las leen con el long-poll GET /events del Hub; la página del Hub muestra las últimas arriba.",
        "fr": "Les appareils les lisent via le long-poll GET /events du Hub ; la page du Hub affiche les dernières en haut.",
    ],
    // 专注状态权限：没有它，勿扰/专注时完成提示音照样会响
    "settings.agentnotify.focusMissing": [
        "en": "No Focus permission — the sound will still play during Do Not Disturb",
        "zh": "未获得「专注模式」权限 —— 勿扰时提示音仍会响",
        "ja": "「集中モード」の権限がありません —— おやすみ中でも音が鳴ります",
        "ko": "「집중 모드」 권한 없음 — 방해 금지 중에도 소리가 납니다",
        "es": "Sin permiso de Concentración: el sonido seguirá sonando en No molestar",
        "fr": "Pas d'autorisation Concentration — le son se déclenchera même en Ne pas déranger",
    ],
    "settings.agentnotify.focusGrant": [
        "en": "Grant…", "zh": "去授权…", "ja": "許可する…", "ko": "권한 부여…",
        "es": "Conceder…", "fr": "Autoriser…",
    ],
    "focus.alert.title": [
        "en": "Agent alerts need Focus permission",
        "zh": "完成通知需要「专注模式」权限",
        "ja": "完了通知には「集中モード」の権限が必要です",
        "ko": "완료 알림에는 「집중 모드」 권한이 필요합니다",
        "es": "Los avisos del agente necesitan permiso de Concentración",
        "fr": "Les alertes d'agent nécessitent l'autorisation Concentration",
    ],
    "focus.alert.body": [
        "en": "Without it GestureApprove can't tell whether a Focus is on, so the completion sound plays even during Do Not Disturb. macOS only asks once, so grant it in System Settings → Privacy & Security → Focus. It reads one thing — Focus on or off — and nothing leaves your Mac.",
        "zh": "没有它，GestureApprove 无法判断你是否开着专注模式，勿扰时那声提示音照样会响。macOS 只会询问一次，所以请到「系统设置 → 隐私与安全性 → 专注模式」里打开。它只读一个状态——专注开着还是关着——不会离开这台 Mac。",
        "ja": "これがないと集中モード中かどうか判別できず、おやすみ中でも完了音が鳴ります。macOS は一度しか尋ねないため「システム設定 → プライバシーとセキュリティ → 集中モード」で許可してください。読み取るのは集中モードのオン/オフだけで、Mac の外には出ません。",
        "ko": "이 권한이 없으면 집중 모드 여부를 알 수 없어 방해 금지 중에도 완료음이 납니다. macOS는 한 번만 묻기 때문에 「시스템 설정 → 개인정보 보호 및 보안 → 집중 모드」에서 허용해 주세요. 집중 모드의 켜짐/꺼짐만 읽으며 Mac 밖으로 나가지 않습니다.",
        "es": "Sin él, GestureApprove no sabe si hay una Concentración activa y el sonido suena incluso en No molestar. macOS solo pregunta una vez: concédelo en Ajustes del Sistema → Privacidad y seguridad → Concentración. Solo lee si la Concentración está activa; nada sale de tu Mac.",
        "fr": "Sans elle, GestureApprove ignore si un mode Concentration est actif et le son se déclenche même en Ne pas déranger. macOS ne demande qu'une fois : accordez-la dans Réglages Système → Confidentialité et sécurité → Concentration. Elle lit uniquement l'état actif/inactif ; rien ne quitte votre Mac.",
    ],
    "focus.alert.open": [
        "en": "Open System Settings", "zh": "打开系统设置",
        "ja": "システム設定を開く", "ko": "시스템 설정 열기",
        "es": "Abrir Ajustes del Sistema", "fr": "Ouvrir Réglages Système",
    ],
    "focus.alert.disable": [
        "en": "Turn off agent alerts", "zh": "关闭完成通知",
        "ja": "完了通知をオフにする", "ko": "완료 알림 끄기",
        "es": "Desactivar los avisos", "fr": "Désactiver les alertes",
    ],
    "focus.alert.later": [
        "en": "Later", "zh": "以后再说", "ja": "あとで", "ko": "나중에",
        "es": "Más tarde", "fr": "Plus tard",
    ],
    "agent.notify.waiting": [
        "en": "Waiting for your input", "zh": "在等你回话",
        "ja": "あなたの入力を待っています", "ko": "당신의 입력을 기다리는 중",
        "es": "Esperando tu respuesta", "fr": "En attente de votre réponse",
    ],
    "agent.notify.title": [
        "en": "Agent finished", "zh": "Agent 已完成",
        "ja": "エージェント完了", "ko": "에이전트 완료",
        "es": "Agente terminado", "fr": "Agent terminé",
    ],
    "agent.notify.noSummary": [
        "en": "This turn is done (no text reply to show).",
        "zh": "这一轮结束了（没有可显示的文字回复）。",
        "ja": "この一区切りが終わりました（表示できる返答テキストはありません）。",
        "ko": "이번 턴이 끝났습니다(표시할 텍스트 응답 없음).",
        "es": "Este turno terminó (sin respuesta de texto que mostrar).",
        "fr": "Ce tour est terminé (aucune réponse textuelle à afficher).",
    ],
    "settings.section.deviceapi": [
        "en": "Remote approval devices", "zh": "远程审批设备",
        "ja": "リモート承認デバイス", "ko": "원격 승인 장치",
        "es": "Dispositivos de aprobación remota", "fr": "Appareils d'approbation à distance",
    ],
    "settings.deviceapi.enable": [
        "en": "Approve from network devices (ESP32, etc.) via API",
        "zh": "允许网络设备（ESP32 等）经 API 审批",
        "ja": "ネットワーク機器（ESP32 など）から API で承認",
        "ko": "네트워크 장치(ESP32 등)에서 API로 승인",
        "es": "Aprobar desde dispositivos de red (ESP32, etc.) vía API",
        "fr": "Approuver depuis des appareils réseau (ESP32, etc.) via l'API",
    ],
    "settings.deviceapi.desc": [
        "en": "Opens a token-protected LAN port so a device can watch for pending approvals and approve/deny — same effect as a gesture or click. The local hook port stays loopback-only. Command text is sent over the LAN in the clear, so use it only on a network you trust.",
        "zh": "开放一个受 token 保护的局域网端口，设备可监听待审批并通过/拒绝——效果等同手势或点击。本地 hook 端口仍只绑回环。命令内容以明文经局域网传输，请仅在可信网络使用。",
        "ja": "トークンで保護された LAN ポートを開き、デバイスが承認待ちを監視して承認/拒否できます（ジェスチャーやクリックと同じ効果）。ローカルの hook ポートはループバック限定のままです。コマンド内容は LAN 上を平文で送るため、信頼できるネットワークでのみ使用してください。",
        "ko": "토큰으로 보호된 LAN 포트를 열어 장치가 대기 중인 승인을 감시하고 승인/거부할 수 있습니다(제스처·클릭과 동일 효과). 로컬 hook 포트는 루프백 전용을 유지합니다. 명령 내용은 LAN에서 평문으로 전송되므로 신뢰하는 네트워크에서만 사용하세요.",
        "es": "Abre un puerto LAN protegido con token para que un dispositivo vigile las aprobaciones pendientes y apruebe/rechace, con el mismo efecto que un gesto o clic. El puerto local del hook sigue siendo solo loopback. El texto del comando se envía por la LAN sin cifrar; úsalo solo en una red de confianza.",
        "fr": "Ouvre un port LAN protégé par jeton pour qu'un appareil surveille les approbations en attente et approuve/refuse — même effet qu'un geste ou un clic. Le port local du hook reste en loopback uniquement. Le texte des commandes transite en clair sur le LAN ; à n'utiliser que sur un réseau de confiance.",
    ],
    "settings.deviceapi.openConfig": [
        "en": "View connection info & pair devices in the config page →",
        "zh": "在配置页查看连接信息、配对设备 →",
        "ja": "設定ページで接続情報の確認・デバイスのペアリング →",
        "ko": "구성 페이지에서 연결 정보 확인 및 장치 페어링 →",
        "es": "Ver info de conexión y emparejar dispositivos en la página de configuración →",
        "fr": "Voir les infos de connexion et appairer les appareils dans la page de configuration →",
    ],
    "settings.deviceapi.address": [
        "en": "Address", "zh": "地址", "ja": "アドレス", "ko": "주소",
        "es": "Dirección", "fr": "Adresse",
    ],
    "settings.deviceapi.otherAddr": [
        "en": "Other:", "zh": "其它：", "ja": "その他：", "ko": "기타:",
        "es": "Otras:", "fr": "Autres :",
    ],
    "settings.deviceapi.noIP": [
        "en": "no network", "zh": "无网络", "ja": "ネットワークなし", "ko": "네트워크 없음",
        "es": "sin red", "fr": "aucun réseau",
    ],
    "settings.deviceapi.copy": [
        "en": "Copy", "zh": "复制", "ja": "コピー", "ko": "복사",
        "es": "Copiar", "fr": "Copier",
    ],
    "settings.section.allowlist": [
        "en": "Auto-allow rules", "zh": "自动放行规则", "ja": "自動承認ルール",
        "ko": "자동 통과 규칙", "es": "Reglas de auto-aprobación", "fr": "Règles d'auto-autorisation",
    ],
    "settings.allowlist.desc": [
        "en": "Commands matching any line (regex) pass without a card. Matched against \"tool: content\", e.g. Bash: ls.",
        "zh": "命中任一行(正则)的命令直接通过、不弹手势卡片。匹配「工具: 内容」，如 Bash: ls。",
        "ja": "いずれかの行（正規表現）に一致するコマンドはカードなしで承認されます。「ツール: 内容」（例: Bash: ls）に対して照合します。",
        "ko": "어느 한 줄(정규식)에 일치하는 명령은 카드 없이 통과합니다. \"도구: 내용\"(예: Bash: ls)에 대해 매칭합니다.",
        "es": "Los comandos que coincidan con cualquier línea (regex) pasan sin tarjeta. Se compara con «herramienta: contenido», p. ej. Bash: ls.",
        "fr": "Les commandes correspondant à une ligne (regex) passent sans carte. Comparé à « outil : contenu », p. ex. Bash: ls.",
    ],
    "settings.language": [
        "en": "Language", "zh": "语言", "ja": "言語",
        "ko": "언어", "es": "Idioma", "fr": "Langue",
    ],
    "settings.language.system": [
        "en": "System", "zh": "跟随系统", "ja": "システムに従う",
        "ko": "시스템 설정", "es": "Sistema", "fr": "Système",
    ],
    "settings.language.note": [
        "en": "The menu bar and window title update after restart.",
        "zh": "菜单栏与窗口标题在重启后更新。",
        "ja": "メニューバーとウィンドウタイトルは再起動後に更新されます。",
        "ko": "메뉴 막대와 창 제목은 재시작 후 갱신됩니다.",
        "es": "La barra de menús y el título de la ventana se actualizan al reiniciar.",
        "fr": "La barre de menus et le titre de la fenêtre se mettent à jour après redémarrage.",
    ],
    "settings.allowlist.restore": [
        "en": "Restore defaults", "zh": "恢复默认", "ja": "初期設定に戻す",
        "ko": "기본값 복원", "es": "Restaurar valores", "fr": "Rétablir",
    ],
    "settings.allowlist.restoreConfirm": [
        "en": "Restore the auto-allow rules to defaults? Your edits to the regex list will be replaced.",
        "zh": "把自动放行规则恢复为默认？你对正则列表的修改将被覆盖。",
        "ja": "自動承認ルールを初期設定に戻しますか？ 正規表現リストへの変更は置き換えられます。",
        "ko": "자동 통과 규칙을 기본값으로 복원할까요? 정규식 목록의 수정 내용이 대체됩니다.",
        "es": "¿Restaurar las reglas de auto-aprobación a sus valores por defecto? Tus cambios en la lista de regex se reemplazarán.",
        "fr": "Rétablir les règles d'auto-autorisation par défaut ? Vos modifications de la liste regex seront remplacées.",
    ],
    "settings.cancel": [
        "en": "Cancel", "zh": "取消", "ja": "キャンセル",
        "ko": "취소", "es": "Cancelar", "fr": "Annuler",
    ],
    "settings.version": [
        "en": "Version", "zh": "版本", "ja": "バージョン",
        "ko": "버전", "es": "Versión", "fr": "Version",
    ],
    "settings.checkUpdate": [
        "en": "Check for updates", "zh": "检查更新", "ja": "アップデートを確認",
        "ko": "업데이트 확인", "es": "Buscar actualizaciones", "fr": "Vérifier les mises à jour",
    ],
    "settings.checking": [
        "en": "Checking…", "zh": "检查中…", "ja": "確認中…",
        "ko": "확인 중…", "es": "Comprobando…", "fr": "Vérification…",
    ],
    "settings.upToDate": [
        "en": "You're on the latest version", "zh": "已是最新版本",
        "ja": "最新バージョンです", "ko": "최신 버전입니다",
        "es": "Tienes la última versión", "fr": "Vous avez la dernière version",
    ],
    "settings.updateAvailable": [
        "en": "New version available:", "zh": "有新版本：",
        "ja": "新しいバージョンがあります：", "ko": "새 버전 있음:",
        "es": "Nueva versión disponible:", "fr": "Nouvelle version disponible :",
    ],
    "settings.updateFailed": [
        "en": "Check failed (network?)", "zh": "检查失败（网络？）",
        "ja": "確認に失敗（ネットワーク？）", "ko": "확인 실패 (네트워크?)",
        "es": "Error al comprobar (¿red?)", "fr": "Échec de la vérification (réseau ?)",
    ],
    "settings.download": [
        "en": "Download", "zh": "下载", "ja": "ダウンロード",
        "ko": "다운로드", "es": "Descargar", "fr": "Télécharger",
    ],
    "settings.installUpdate": [
        "en": "Update now", "zh": "立即更新", "ja": "今すぐ更新",
        "ko": "지금 업데이트", "es": "Actualizar ahora", "fr": "Mettre à jour",
    ],
    "settings.update.downloading": [
        "en": "Downloading…", "zh": "下载中…", "ja": "ダウンロード中…",
        "ko": "다운로드 중…", "es": "Descargando…", "fr": "Téléchargement…",
    ],
    "settings.update.installing": [
        "en": "Installing — the app will relaunch…", "zh": "安装中，应用即将重启…",
        "ja": "インストール中、アプリを再起動します…", "ko": "설치 중 — 앱이 다시 시작됩니다…",
        "es": "Instalando — la app se reiniciará…", "fr": "Installation — l'app va redémarrer…",
    ],
    "settings.update.installFailed": [
        "en": "Update failed (network?)", "zh": "更新失败（网络？）",
        "ja": "更新に失敗（ネットワーク？）", "ko": "업데이트 실패(네트워크?)",
        "es": "Error al actualizar (¿red?)", "fr": "Échec de la mise à jour (réseau ?)",
    ],
    "settings.section.general": [
        "en": "General", "zh": "通用", "ja": "一般",
        "ko": "일반", "es": "General", "fr": "Général",
    ],
    "settings.section.trusted": [
        "en": "Trusted commands", "zh": "信任的命令", "ja": "信頼済みコマンド",
        "ko": "신뢰한 명령", "es": "Comandos de confianza", "fr": "Commandes de confiance",
    ],
    "settings.trusted.desc": [
        "en": "Exact commands you approved with \"Always allow\". They pass without a card — but dangerous ones still always need a gesture.",
        "zh": "你在卡片上点「总是允许」信任的整条命令，之后免手势直接通过；但危险命令仍始终要手势。",
        "ja": "「今後は自動許可」で信頼した完全一致のコマンド。カードなしで通過しますが、危険なコマンドは常にジェスチャーが必要です。",
        "ko": "\"항상 허용\"으로 신뢰한 정확한 명령. 카드 없이 통과하지만 위험한 명령은 항상 제스처가 필요합니다.",
        "es": "Comandos exactos que aprobaste con «Permitir siempre». Pasan sin tarjeta, pero los peligrosos siempre requieren un gesto.",
        "fr": "Commandes exactes approuvées via « Toujours autoriser ». Elles passent sans carte, mais les commandes dangereuses exigent toujours un geste.",
    ],
    "settings.trusted.empty": [
        "en": "None yet — tap \"Always allow\" on a card to add one.",
        "zh": "暂无——在卡片上点「总是允许」即可添加。",
        "ja": "まだありません — カードの「今後は自動許可」で追加できます。",
        "ko": "아직 없음 — 카드에서 \"항상 허용\"을 눌러 추가하세요.",
        "es": "Aún ninguno: pulsa «Permitir siempre» en una tarjeta para añadir.",
        "fr": "Aucune pour l'instant — appuyez sur « Toujours autoriser » sur une carte pour en ajouter.",
    ],
    "settings.trusted.remove": [
        "en": "Remove", "zh": "移除", "ja": "削除",
        "ko": "제거", "es": "Quitar", "fr": "Retirer",
    ],
    "settings.esp32card.title": [
        "en": "Use an ESP32-CAM as your camera", "zh": "使用 ESP32-CAM 作为摄像头",
        "ja": "ESP32-CAM をカメラとして使う", "ko": "ESP32-CAM을 카메라로 사용",
        "es": "Usar un ESP32-CAM como cámara", "fr": "Utiliser un ESP32-CAM comme caméra",
    ],
    "settings.esp32card.desc": [
        "en": "No suitable camera? Flash an ESP32-CAM module with the matching firmware and use it as your approval camera.",
        "zh": "没有合适的摄像头？用一块 ESP32-CAM 模块，刷入配套固件就能当审批摄像头。",
        "ja": "適したカメラがない？ ESP32-CAM モジュールに専用ファームウェアを書き込めば承認用カメラになります。",
        "ko": "적당한 카메라가 없나요? ESP32-CAM 모듈에 전용 펌웨어를 플래시하면 승인용 카메라로 쓸 수 있습니다.",
        "es": "¿No tienes una cámara adecuada? Flashea un módulo ESP32-CAM con el firmware correspondiente y úsalo como cámara de aprobación.",
        "fr": "Pas de caméra adaptée ? Flashez un module ESP32-CAM avec le firmware adapté et utilisez-le comme caméra d'approbation.",
    ],
    "settings.alert.title": [
        "en": "Connection failed", "zh": "接入失败", "ja": "連携に失敗しました",
        "ko": "연결 실패", "es": "Error de conexión", "fr": "Échec de la connexion",
    ],
    "settings.alert.ok": [
        "en": "OK", "zh": "好", "ja": "OK", "ko": "확인", "es": "Aceptar", "fr": "OK",
    ],

    // MARK: 视频源名 & 脚本运行器
    "video.esp32": [
        "en": "ESP32-CAM (serial)", "zh": "ESP32-CAM（串口）",
        "ja": "ESP32-CAM（シリアル）", "ko": "ESP32-CAM(시리얼)",
        "es": "ESP32-CAM (serie)", "fr": "ESP32-CAM (série)",
    ],
    "video.disconnected": [
        "en": "⚠️ Selected camera disconnected", "zh": "⚠️ 所选摄像头已断开",
        "ja": "⚠️ 選択したカメラが切断されました", "ko": "⚠️ 선택한 카메라 연결 끊김",
        "es": "⚠️ Cámara seleccionada desconectada", "fr": "⚠️ Caméra sélectionnée déconnectée",
    ],
    "video.disconnected.hint": [
        "en": "The selected camera is unplugged. Approvals temporarily use the default camera and switch back automatically once it's reconnected. Pick another camera above to change it for good.",
        "zh": "所选摄像头已拔出。审批将临时改用默认摄像头，插回后自动切回；也可在上方直接改选其它摄像头。",
        "ja": "選択したカメラが取り外されています。承認時は一時的にデフォルトカメラを使用し、再接続すると自動的に戻ります。上で別のカメラを選ぶこともできます。",
        "ko": "선택한 카메라가 분리되었습니다. 승인 시 임시로 기본 카메라를 사용하며, 다시 연결되면 자동으로 전환됩니다. 위에서 다른 카메라를 선택할 수도 있습니다.",
        "es": "La cámara seleccionada está desconectada. Las aprobaciones usarán temporalmente la cámara predeterminada y volverán automáticamente al reconectarla. También puedes elegir otra cámara arriba.",
        "fr": "La caméra sélectionnée est débranchée. Les approbations utiliseront temporairement la caméra par défaut et rebasculeront automatiquement une fois reconnectée. Vous pouvez aussi choisir une autre caméra ci-dessus.",
    ],
    "script.preparing": [
        "en": "Preparing…", "zh": "准备中…", "ja": "準備中…",
        "ko": "준비 중…", "es": "Preparando…", "fr": "Préparation…",
    ],
    "script.idle": [
        "en": "Idle", "zh": "空闲", "ja": "待機中",
        "ko": "대기 중", "es": "Inactivo", "fr": "Inactif",
    ],
    "script.notFound": [
        "en": "Script not found: ", "zh": "找不到脚本：",
        "ja": "スクリプトが見つかりません：", "ko": "스크립트를 찾을 수 없음: ",
        "es": "Script no encontrado: ", "fr": "Script introuvable : ",
    ],
    "script.cannotLaunch": [
        "en": "Cannot launch: ", "zh": "无法启动：",
        "ja": "起動できません：", "ko": "실행할 수 없음: ",
        "es": "No se puede iniciar: ", "fr": "Impossible de lancer : ",
    ],

    // MARK: 守门员下载脚本进度（download_gatekeeper.sh，经环境变量传入）
    "gk.sh.download": [
        "en": "Downloading gatekeeper component", "zh": "下载守门员组件",
        "ja": "ゲートキーパーをダウンロード", "ko": "게이트키퍼 다운로드",
        "es": "Descargando el guardián", "fr": "Téléchargement du gardien",
    ],
    "gk.sh.extract": [
        "en": "Unpacking to", "zh": "解压到", "ja": "展開先", "ko": "압축 해제 위치",
        "es": "Descomprimiendo en", "fr": "Décompression dans",
    ],
    "gk.sh.quarantine": [
        "en": "Clearing quarantine attribute", "zh": "清除隔离属性",
        "ja": "隔離属性を解除", "ko": "격리 속성 제거",
        "es": "Quitando la cuarentena", "fr": "Levée de la quarantaine",
    ],
    "gk.sh.missingBin": [
        "en": "Missing executable after unpack:", "zh": "解压后缺少可执行文件：",
        "ja": "展開後に実行ファイルがありません：", "ko": "압축 해제 후 실행 파일 없음:",
        "es": "Falta el ejecutable tras descomprimir:", "fr": "Exécutable manquant après décompression :",
    ],
    "gk.sh.missingBundle": [
        "en": "Missing mlx-swift_Cmlx.bundle (Metal library) — cannot run",
        "zh": "缺少 mlx-swift_Cmlx.bundle（Metal 库），无法运行",
        "ja": "mlx-swift_Cmlx.bundle（Metal ライブラリ）がなく実行できません",
        "ko": "mlx-swift_Cmlx.bundle(Metal 라이브러리) 없음 — 실행 불가",
        "es": "Falta mlx-swift_Cmlx.bundle (biblioteca Metal); no se puede ejecutar",
        "fr": "mlx-swift_Cmlx.bundle (bibliothèque Metal) manquant — exécution impossible",
    ],
    "gk.sh.signOk": [
        "en": "Signature verified", "zh": "签名校验通过",
        "ja": "署名を検証しました", "ko": "서명 확인됨",
        "es": "Firma verificada", "fr": "Signature vérifiée",
    ],
    "gk.sh.signWarn": [
        "en": "⚠️ Signature not verified (ad-hoc still runs)",
        "zh": "⚠️ 签名校验未通过（ad-hoc 仍可运行）",
        "ja": "⚠️ 署名未検証（ad-hoc でも実行可）",
        "ko": "⚠️ 서명 미확인 (ad-hoc 실행 가능)",
        "es": "⚠️ Firma no verificada (ad-hoc igual funciona)",
        "fr": "⚠️ Signature non vérifiée (ad-hoc fonctionne quand même)",
    ],
    "gk.sh.prefetch": [
        "en": "Prefetching model weights (~1GB; slow the first time, instant if cached)",
        "zh": "预取模型权重（约 1GB，首次较慢；已缓存则秒过）",
        "ja": "モデルの重みを事前取得（約1GB、初回は低速、キャッシュ済みなら即時）",
        "ko": "모델 가중치 미리 받기(~1GB, 최초 느림, 캐시 시 즉시)",
        "es": "Precargando pesos del modelo (~1GB; lento la primera vez, instantáneo si está en caché)",
        "fr": "Pré-téléchargement des poids (~1 Go ; lent la première fois, instantané si en cache)",
    ],
    "gk.sh.prefetchFail": [
        "en": "Model prefetch failed (network?). The helper is in place — retry later via \"Re-download\" in Settings.",
        "zh": "模型预取失败（网络问题？）。helper 已就位，可稍后在设置里「重新下载」重试。",
        "ja": "モデルの事前取得に失敗（ネットワーク？）。ヘルパーは配置済み。設定の「再ダウンロード」で後ほど再試行できます。",
        "ko": "모델 미리 받기 실패(네트워크?). 헬퍼는 설치됨 — 설정의 \"다시 다운로드\"로 나중에 재시도하세요.",
        "es": "Falló la precarga del modelo (¿red?). El ayudante está listo; reintenta luego con «Volver a descargar» en Ajustes.",
        "fr": "Échec du pré-téléchargement (réseau ?). L'assistant est en place — réessayez via « Retélécharger » dans Réglages.",
    ],
    "gk.sh.ready": [
        "en": "Gatekeeper + model ready ✅", "zh": "守门员 + 模型就绪 ✅",
        "ja": "ゲートキーパー + モデル準備完了 ✅", "ko": "게이트키퍼 + 모델 준비됨 ✅",
        "es": "Guardián + modelo listos ✅", "fr": "Gardien + modèle prêts ✅",
    ],
    // helper(GestureGatekeeper）prefetch 时打到 stderr 的进度，经环境变量按界面语言传入。
    "gk.sh.modelCache": [
        "en": "Model cache dir:", "zh": "模型缓存目录：",
        "ja": "モデルキャッシュ：", "ko": "모델 캐시 폴더:",
        "es": "Caché del modelo:", "fr": "Cache du modèle :",
    ],
    "gk.sh.downloading": [   // 后面接「 <秒数>s 」与 downloadingSuffix
        "en": "Downloading… elapsed", "zh": "下载中…已用",
        "ja": "ダウンロード中…経過", "ko": "다운로드 중… 경과",
        "es": "Descargando… transcurrido", "fr": "Téléchargement… écoulé",
    ],
    "gk.sh.downloadingSuffix": [
        "en": "(model is ~1GB, first run takes a while)",
        "zh": "（模型约 1GB，首次请耐心等待）",
        "ja": "（モデルは約1GB、初回はお待ちください）",
        "ko": "(모델 약 1GB, 최초 실행은 시간이 걸립니다)",
        "es": "(el modelo pesa ~1GB, la primera vez tarda)",
        "fr": "(le modèle fait ~1 Go, la première fois prend du temps)",
    ],
    "gk.sh.prefetchDone": [
        "en": "Prefetch complete, model ready", "zh": "预取完成，模型已就绪",
        "ja": "事前取得完了、モデル準備完了", "ko": "미리 받기 완료, 모델 준비됨",
        "es": "Precarga completa, modelo listo", "fr": "Pré-téléchargement terminé, modèle prêt",
    ],
    "gk.sh.loadingModel": [   // 后面接「 <模型id> 」与 loadingModelSuffix
        "en": "Loading model", "zh": "加载模型",
        "ja": "モデルを読み込み中", "ko": "모델 로딩 중",
        "es": "Cargando modelo", "fr": "Chargement du modèle",
    ],
    "gk.sh.loadingModelSuffix": [
        "en": "(downloads from HuggingFace on first run)",
        "zh": "（首次会从 HuggingFace 下载）",
        "ja": "（初回は HuggingFace からダウンロード）",
        "ko": "(최초 실행 시 HuggingFace에서 다운로드)",
        "es": "(se descarga de HuggingFace la primera vez)",
        "fr": "(téléchargé depuis HuggingFace au premier lancement)",
    ],
    "gk.sh.downloadPct": [   // 后面接「 <百分比>% 」
        "en": "Downloading", "zh": "下载", "ja": "ダウンロード",
        "ko": "다운로드", "es": "Descargando", "fr": "Téléchargement",
    ],
    "gk.sh.modelReady": [   // 后面接「 <秒数>s 」
        "en": "Model ready in", "zh": "模型就绪，耗时",
        "ja": "モデル準備完了、所要", "ko": "모델 준비됨, 소요",
        "es": "Modelo listo en", "fr": "Modèle prêt en",
    ],

    // MARK: MediaPipe 安装脚本进度（setup_mediapipe.sh / download_model.py，经环境变量传入）
    "mp.sh.venv": [
        "en": "Creating venv:", "zh": "创建 venv：", "ja": "venv を作成：",
        "ko": "venv 생성:", "es": "Creando venv:", "fr": "Création du venv :",
    ],
    "mp.sh.deps": [
        "en": "Installing dependencies", "zh": "安装依赖", "ja": "依存関係をインストール",
        "ko": "의존성 설치", "es": "Instalando dependencias", "fr": "Installation des dépendances",
    ],
    "mp.sh.model": [
        "en": "Downloading the MediaPipe gesture model", "zh": "下载 MediaPipe 手势模型",
        "ja": "MediaPipe ジェスチャーモデルをダウンロード", "ko": "MediaPipe 제스처 모델 다운로드",
        "es": "Descargando el modelo de gestos de MediaPipe", "fr": "Téléchargement du modèle de gestes MediaPipe",
    ],
    "mp.sh.done": [
        "en": "Done. MediaPipe is ready.", "zh": "完成。MediaPipe 已就绪。",
        "ja": "完了。MediaPipe の準備ができました。", "ko": "완료. MediaPipe가 준비되었습니다.",
        "es": "Listo. MediaPipe está preparado.", "fr": "Terminé. MediaPipe est prêt.",
    ],
    "mp.sh.modelExists": [
        "en": "Model already present:", "zh": "模型已存在：",
        "ja": "モデルは既にあります：", "ko": "모델이 이미 있음:",
        "es": "El modelo ya existe:", "fr": "Modèle déjà présent :",
    ],
    "mp.sh.modelDownload": [
        "en": "Downloading gesture model ->", "zh": "下载手势模型 ->",
        "ja": "ジェスチャーモデルをダウンロード ->", "ko": "제스처 모델 다운로드 ->",
        "es": "Descargando modelo de gestos ->", "fr": "Téléchargement du modèle ->",
    ],
    "mp.sh.modelDone": [
        "en": "Done,", "zh": "完成，", "ja": "完了、", "ko": "완료,",
        "es": "Listo,", "fr": "Terminé,",
    ],
    "mp.sh.bytes": [
        "en": "bytes", "zh": "字节", "ja": "バイト", "ko": "바이트",
        "es": "bytes", "fr": "octets",
    ],

    // MARK: 固件刷写脚本进度（flash.sh，经环境变量传入）
    "fw.sh.prepEsptool": [
        "en": "First run: preparing the esptool flasher (~20MB, one time)…",
        "zh": "首次使用：正在准备烧录工具 esptool（约 20MB，仅此一次）…",
        "ja": "初回：書き込みツール esptool を準備中（約20MB、初回のみ）…",
        "ko": "최초 실행: esptool 플래셔 준비 중(~20MB, 1회)…",
        "es": "Primera vez: preparando esptool (~20MB, una sola vez)…",
        "fr": "Première fois : préparation d'esptool (~20 Mo, une seule fois)…",
    ],
    "fw.sh.noPython": [
        "en": "python3 not found; cannot install esptool.", "zh": "未找到 python3，无法安装 esptool。",
        "ja": "python3 が見つからず esptool をインストールできません。", "ko": "python3을 찾을 수 없어 esptool을 설치할 수 없습니다.",
        "es": "No se encontró python3; no se puede instalar esptool.", "fr": "python3 introuvable ; impossible d'installer esptool.",
    ],
    "fw.sh.venvFail": [
        "en": "Failed to create venv.", "zh": "创建 venv 失败。",
        "ja": "venv の作成に失敗しました。", "ko": "venv 생성 실패.",
        "es": "Error al crear el venv.", "fr": "Échec de la création du venv.",
    ],
    "fw.sh.esptoolFail": [
        "en": "Failed to install esptool (check network).", "zh": "安装 esptool 失败（检查网络）。",
        "ja": "esptool のインストールに失敗（ネットワークを確認）。", "ko": "esptool 설치 실패(네트워크 확인).",
        "es": "Error al instalar esptool (revisa la red).", "fr": "Échec de l'installation d'esptool (vérifiez le réseau).",
    ],
    "fw.sh.esptoolReady": [
        "en": "esptool ready.", "zh": "esptool 就绪。", "ja": "esptool 準備完了。",
        "ko": "esptool 준비됨.", "es": "esptool listo.", "fr": "esptool prêt.",
    ],
    "fw.sh.noPort": [
        "en": "No serial port found. Make sure the ESP32-CAM is plugged in via a USB-to-serial adapter.",
        "zh": "没找到串口。请确认 ESP32-CAM 已通过 USB-串口适配器插入电脑。",
        "ja": "シリアルポートが見つかりません。ESP32-CAM が USB-シリアル変換アダプタで接続されているか確認してください。",
        "ko": "시리얼 포트를 찾을 수 없습니다. ESP32-CAM이 USB-시리얼 어댑터로 연결됐는지 확인하세요.",
        "es": "No se encontró puerto serie. Asegúrate de que el ESP32-CAM esté conectado por un adaptador USB-serie.",
        "fr": "Aucun port série trouvé. Vérifiez que l'ESP32-CAM est branché via un adaptateur USB-série.",
    ],
    "fw.sh.port": [
        "en": "Serial port:", "zh": "串口：", "ja": "シリアルポート：",
        "ko": "시리얼 포트:", "es": "Puerto serie:", "fr": "Port série :",
    ],
    "fw.sh.flashing": [
        "en": "Flashing firmware…", "zh": "开始刷写固件…", "ja": "ファームウェアを書き込み中…",
        "ko": "펌웨어 플래시 중…", "es": "Flasheando firmware…", "fr": "Flash du firmware…",
    ],
    "fw.sh.success": [
        "en": "✅ Flash succeeded. Back in Settings, set the video source to \"ESP32-CAM (serial)\".",
        "zh": "✅ 刷写成功。回到设置，把视频输入源选成「ESP32-CAM（串口）」即可。",
        "ja": "✅ 書き込み成功。設定で映像入力を「ESP32-CAM（シリアル）」に設定してください。",
        "ko": "✅ 플래시 성공. 설정에서 비디오 입력을 \"ESP32-CAM(시리얼)\"로 선택하세요.",
        "es": "✅ Flasheo correcto. En Ajustes, elige la fuente de vídeo «ESP32-CAM (serie)».",
        "fr": "✅ Flash réussi. Dans Réglages, choisissez la source vidéo « ESP32-CAM (série) ».",
    ],
    "fw.sh.failed": [
        "en": "Flash failed", "zh": "刷写失败", "ja": "書き込み失敗",
        "ko": "플래시 실패", "es": "Flasheo fallido", "fr": "Échec du flash",
    ],
    "fw.sh.failHint": [
        "en": "If a bare FTDI has no auto-reset: tie GPIO0 to GND → reset → click \"Flash again\".",
        "zh": "裸 FTDI 接线若没自动复位：GPIO0 接 GND → 复位 → 点「重新刷写」。",
        "ja": "素の FTDI で自動リセットしない場合：GPIO0 を GND に → リセット → 「再書き込み」をクリック。",
        "ko": "베어 FTDI가 자동 리셋되지 않으면: GPIO0을 GND에 → 리셋 → \"다시 플래시\" 클릭.",
        "es": "Si un FTDI sin reset automático: conecta GPIO0 a GND → reinicia → pulsa «Volver a flashear».",
        "fr": "Si un FTDI nu sans reset auto : reliez GPIO0 à GND → reset → cliquez sur « Reflasher ».",
    ],
]
