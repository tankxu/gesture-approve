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
