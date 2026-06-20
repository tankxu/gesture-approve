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

    static func string(_ key: String) -> String {
        guard let entry = table[key] else { return key }
        return entry[lang] ?? entry["en"] ?? key
    }
}

/// 取本地化文案的快捷函数。
func L(_ key: String) -> String { I18n.string(key) }

private let table: [String: [String: String]] = [
    // MARK: 菜单
    "menu.running": [
        "en": "GestureApprove · Running", "zh": "手势审批 · 运行中",
        "ja": "ジェスチャー承認 · 実行中", "ko": "제스처 승인 · 실행 중",
        "es": "GestureApprove · En ejecución", "fr": "GestureApprove · En cours",
    ],
    "menu.enable": [
        "en": "Enable approval gating", "zh": "启用审批拦截",
        "ja": "承認ゲートを有効化", "ko": "승인 게이트 사용",
        "es": "Activar control de aprobación", "fr": "Activer le contrôle d'approbation",
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
    "menu.quit": [
        "en": "Quit", "zh": "退出", "ja": "終了", "ko": "종료",
        "es": "Salir", "fr": "Quitter",
    ],
    "app.name": [
        "en": "GestureApprove", "zh": "手势审批",
        "ja": "ジェスチャー承認", "ko": "제스처 승인",
        "es": "GestureApprove", "fr": "GestureApprove",
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
        "en": "GestureApprove · Test result", "zh": "手势审批 · 测试结果",
        "ja": "ジェスチャー承認 · テスト結果", "ko": "제스처 승인 · 테스트 결과",
        "es": "GestureApprove · Resultado de la prueba", "fr": "GestureApprove · Résultat du test",
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
        "en": "GestureApprove · Settings", "zh": "手势审批 · 设置",
        "ja": "ジェスチャー承認 · 設定", "ko": "제스처 승인 · 설정",
        "es": "GestureApprove · Ajustes", "fr": "GestureApprove · Réglages",
    ],
    "settings.section.connect": [
        "en": "Connect AI tools", "zh": "接入 AI 工具",
        "ja": "AI ツールと連携", "ko": "AI 도구 연결",
        "es": "Conectar herramientas de IA", "fr": "Connecter les outils d'IA",
    ],
    "settings.connectClaude": [
        "en": "Connect Claude Code", "zh": "接入 Claude Code",
        "ja": "Claude Code と連携", "ko": "Claude Code 연결",
        "es": "Conectar Claude Code", "fr": "Connecter Claude Code",
    ],
    "settings.connectCodex": [
        "en": "Connect Codex CLI", "zh": "接入 Codex CLI",
        "ja": "Codex CLI と連携", "ko": "Codex CLI 연결",
        "es": "Conectar Codex CLI", "fr": "Connecter Codex CLI",
    ],
    "settings.connectCodexNote": [
        "en": "Codex hooks run only in the terminal CLI (not the desktop app). After enabling, run /hooks in Codex and trust the gesture-approve hook.",
        "zh": "Codex 的 hook 仅在终端 CLI 生效（桌面版不支持）。开启后，在 Codex 里执行 /hooks 并信任 gesture-approve 这条 hook。",
        "ja": "Codex のフックはターミナル CLI でのみ動作します（デスクトップ版は非対応）。有効化後、Codex で /hooks を実行し gesture-approve フックを信頼してください。",
        "ko": "Codex 후크는 터미널 CLI에서만 작동합니다(데스크톱 앱 미지원). 활성화 후 Codex에서 /hooks를 실행해 gesture-approve 후크를 신뢰하세요.",
        "es": "Los hooks de Codex solo funcionan en la CLI de terminal (no en la app de escritorio). Tras activarlo, ejecuta /hooks en Codex y confía en el hook gesture-approve.",
        "fr": "Les hooks Codex ne fonctionnent que dans la CLI du terminal (pas l'app de bureau). Après activation, exécutez /hooks dans Codex et faites confiance au hook gesture-approve.",
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
]
