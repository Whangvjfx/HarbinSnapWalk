# 随手画步 (HarbinSnapWalk)

一款为哈尔滨工程大学 (HEU) 师生及步行爱好者量身打造的 iOS 17 原生随手画路网吸附步行 App。

## 核心特性

1. **随手画线自动吸附路网 (Sketch-to-Snap)**：
   - 用户点击画笔后可在地图上自由手绘折线或闭环圈。
   - 通过弦长距离几何抽稀算法智能提取 3~7 个控制锚点。
   - 串联调用 iOS 原生 `MKDirections` 步行模式（国内底层直连高德底图），秒级贴合真实人行道与马路。
2. **默认锁定哈工程西一门**：
   - 默认中心锚定哈工程西一门（`45.77305° N, 126.67837° E`）。
   - 内置哈工程中心区（11号楼）、军工操场、奥列霍夫广场、文庙街南门、文化公园、斯大林公园等预设。
3. **免付费证书自动化构建 (Zero-Cert Entitlements)**：
   - 纯原生 `CMPedometer` 步数协处理器读取，无 HealthKit 限制，免签自签放行。
   - 采用 `XcodeGen` 规范化管理工程结构，通过 GitHub Actions (macOS 14 Runner) 自动化构建打包未签名 `.ipa`。
4. **低功耗 GPS 调度与第一人称视角朝向跟随**：
   - 10米级定位精度（`kCLLocationAccuracyNearestTenMeters`）、10米位移过滤与 `.fitness` 健身曲线。
   - 三态视角自由切换：自由浏览、位置居中、朝向跟随（按需启用磁力计电子罗盘）。

## 自动化构建与安装指引

### 1. 推送代码至 GitHub
```bash
git init
git add .
git commit -m "feat: initial commit of HarbinSnapWalk"
git branch -M main
git remote add origin https://github.com/<your-username>/HarbinSnapWalk.git
git push -u origin main
```

### 2. GitHub Actions 云端编译
- 推送代码至 `main` 或 `master` 分支后，GitHub Actions 会自动触发 `.github/workflows/build-ipa.yml`。
- 构建完成后，在 Actions 运行页面的 **Artifacts** 区域即可下载 `HarbinSnapWalk-IPA` 压缩包（内含 `HarbinSnapWalk-Unsigned.ipa`）。

### 3. Sideloadly / AltStore 自签安装
1. 将下载解压得到的 `HarbinSnapWalk-Unsigned.ipa` 传入电脑。
2. 打开 **Sideloadly** 或 **AltStore**。
3. 连接 iPhone，输入 Apple ID 进行个人免费证书签名并安装到手机。
4. 在 iPhone **设置 -> 通用 -> VPN 与设备管理** 中信任您的开发者证书即可启动体验。
