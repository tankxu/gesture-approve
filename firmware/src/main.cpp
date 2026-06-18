// ESP32-CAM 审批摄像头固件
//
// 协议（与 bridge/esp32cam.py 必须一致）：
//   主机 -> ESP32（以 '\n' 结尾的命令行）：
//     CAP   抓一帧 JPEG 发回
//     PING  回 "PONG\n"，用于握手/探活
//     L1    打开状态指示灯（板载红灯 GPIO33，等待手势时点亮）
//     L0    关闭状态指示灯
//   ESP32 -> 主机（帧）：
//     魔数 0xA5 0x5A 0xA5 0x5A + 4 字节小端长度(uint32) + 该长度的 JPEG 原始字节
//   其余文本（如 PONG、启动日志）与帧数据靠魔数区分，主机扫描魔数即可跳过噪声。

#include "esp_camera.h"
#include <Arduino.h>

// ===== AI-Thinker ESP32-CAM 引脚 =====
#if defined(CAMERA_MODEL_AI_THINKER)
#define PWDN_GPIO_NUM 32
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM 0
#define SIOD_GPIO_NUM 26
#define SIOC_GPIO_NUM 27
#define Y9_GPIO_NUM 35
#define Y8_GPIO_NUM 34
#define Y7_GPIO_NUM 39
#define Y6_GPIO_NUM 36
#define Y5_GPIO_NUM 21
#define Y4_GPIO_NUM 19
#define Y3_GPIO_NUM 18
#define Y2_GPIO_NUM 5
#define VSYNC_GPIO_NUM 25
#define HREF_GPIO_NUM 23
#define PCLK_GPIO_NUM 22
#define STATUS_LED_GPIO 33  // 板载红色 LED，低电平点亮
#else
#error "请在 platformio.ini 定义相机型号，例如 -DCAMERA_MODEL_AI_THINKER"
#endif

static const uint8_t FRAME_MAGIC[4] = {0xA5, 0x5A, 0xA5, 0x5A};

static void setStatusLed(bool on) {
  // GPIO33 低电平点亮
  digitalWrite(STATUS_LED_GPIO, on ? LOW : HIGH);
}

static bool initCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_QVGA;   // 320x240，对手势识别够用且帧小、传输快
  config.jpeg_quality = 12;             // 0(最好/最大) - 63(最差/最小)
  config.grab_mode = CAMERA_GRAB_LATEST; // 总是拿最新一帧，降低延迟
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.fb_count = 2;

  if (!psramFound()) {
    // 没有 PSRAM 时退化配置
    config.frame_size = FRAMESIZE_QQVGA;
    config.fb_location = CAMERA_FB_IN_DRAM;
    config.fb_count = 1;
  }

  esp_err_t err = esp_camera_init(&config);
  return err == ESP_OK;
}

static void sendFrame() {
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) {
    return;  // 抓帧失败，主机会因超时重试
  }
  uint32_t len = fb->len;
  Serial.write(FRAME_MAGIC, 4);
  Serial.write((uint8_t *)&len, 4);  // 小端
  Serial.write(fb->buf, fb->len);
  Serial.flush();
  esp_camera_fb_return(fb);
}

void setup() {
  pinMode(STATUS_LED_GPIO, OUTPUT);
  setStatusLed(false);
  Serial.begin(921600);
  Serial.setRxBufferSize(1024);
  delay(100);

  if (!initCamera()) {
    // 初始化失败时慢闪指示灯，主机端 PING 也不会得到 PONG
    while (true) {
      setStatusLed(true);
      delay(150);
      setStatusLed(false);
      delay(850);
    }
  }
  // 丢弃前几帧（自动曝光/白平衡稳定）
  for (int i = 0; i < 3; i++) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (fb) esp_camera_fb_return(fb);
  }
}

void loop() {
  static String cmd;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      cmd.trim();
      if (cmd == "CAP") {
        sendFrame();
      } else if (cmd == "PING") {
        Serial.print("PONG\n");
        Serial.flush();
      } else if (cmd == "L1") {
        setStatusLed(true);
      } else if (cmd == "L0") {
        setStatusLed(false);
      }
      cmd = "";
    } else if (cmd.length() < 16) {
      cmd += c;
    }
  }
}
