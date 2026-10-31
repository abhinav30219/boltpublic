# Bolt

Bolt is an on-device health companion for iPhone that pairs Google's **Gemma** (running locally through LiteRT-LM) with a [**Petoi Quaddle open source robot dog**](https://github.com/PetoiCamp/opencat-gemma/commits/main/). Gemma reads your live vitals and activity and writes short insight cards and chat answers, and a 3D companion on screen mirrors the connected Petoi Quaddle's moves. Everything runs on the phone; nothing is sent to a server.

The original Bolt app was built to work with a specific proprietary wearable (the Clair Band). This repository replaces that dependency entirely: instead of the Clair Band, Bolt now reads heart rate from **any standard Bluetooth heart-rate device** (the Bluetooth SIG Heart Rate Service), and falls back to the **iPhone's own Core Motion sensors** for activity, steps, and motion. No proprietary band, protocol, or model is required, so the app runs with any HR strap or watch, or with no accessory at all.

## What it does

- **Live heart rate** from any standard Bluetooth Heart Rate strap or watch (Bluetooth SIG Heart Rate Service, `0x180D`). Optional battery and skin-temperature if the device exposes them.
- **Activity and steps** from Apple Core Motion (`CMMotionActivity` + `CMPedometer`): walking, running, still, cycling, step count and cadence, all on-device.
- **Gemma insight cards and chat**: Gemma 4 E2B runs locally via LiteRT-LM and writes short cards as your data changes, and answers questions using tools over your live metrics and a small on-device memory.
- **Robot companion**: a 3D companion (RealityKit / SceneKit) reacts to your activity and mirrors moves sent to a connected [**Petoi Quaddle open source robot dog**](https://github.com/PetoiCamp/opencat-gemma/commits/main/) (wave, flip, walk, idle). Trigger a flip with an on-screen button or a phone shake.
- **Basic fall heuristic** (clearly labelled, not a medical device): a simple phone-accelerometer impact-plus-stillness detector, with a manual "simulate a fall" button for demos.
- **Demo mode**: a synthetic session so you can try the whole flow with no band and no robot.

## Project layout

| Path | What |
| --- | --- |
| `project.yml` | XcodeGen spec (iOS 17, SwiftPM packages) |
| `App/Sources/App` | `BoltApp`, `AppModel` (the 1 Hz loop, card queue, chat, recording, replay) |
| `App/Sources/AI` | `GemmaService` (LiteRT-LM engine) and `ChatTools` |
| `App/Sources/Band` | `HeartRateBand` (standard Bluetooth Heart Rate Service) |
| `App/Sources/Motion` | `MotionActivityEngine` (Core Motion activity + pedometer), `PhoneMotionSource` (accelerometer for fall / gesture) |
| `App/Sources/Companion` + `App/Sources/Robot` | the 3D companion and the Petoi robot link |
| `App/Sources/Screens` | Home, Ask (chat), Memory, Under the hood, Settings, data source picker |
| `Packages/BoltCore` | Logic that doesn't need iOS: metrics store and baselines, activity timeline, trigger rules, prompts, tools, memory, recording/replay, companion pose solver, robot moves, SQLite history. Unit-tested (149 tests). |

## Build

1. Install XcodeGen: `brew install xcodegen`
2. Generate and open:
   ```
   xcodegen generate
   open Bolt.xcodeproj
   ```
3. Let Xcode resolve packages. If LiteRT-LM complains about Git LFS:
   `GIT_LFS_SKIP_SMUDGE=1 xcodebuild -resolvePackageDependencies -project Bolt.xcodeproj`
4. Set your own development team under Signing & Capabilities.
5. Run on a real iPhone (15 Pro or newer recommended). The GPU path for Gemma needs a device, not the simulator.

## Put a Gemma model on the phone (once)

The LLM weights are not bundled (they are large and change often). After installing the app:

1. Download a Gemma `.litertlm` model (for example `gemma-4-E2B-it-gpu.litertlm`).
2. Connect the iPhone, open Finder, select the iPhone, go to **Files**, open **Bolt**, and drag the model in.
3. In the app's onboarding (or **Under the hood**), tap **Refresh**, then **Load model**. The first load compiles GPU shaders and can take tens of seconds.

Without a model, cards and chat fall back to templates; the rest of the app still works.

## Notes

- **Privacy**: all processing is on-device. Bluetooth is used only to connect to a heart-rate band and the robot.
- **Fall detection** here is a basic heuristic for demonstration, not a medical or safety-certified feature.
- Built for the AGI House Gemma hackathon, integrating **Gemma** (Google) and the [**Petoi Quaddle open source robot dog**](https://github.com/PetoiCamp/opencat-gemma/commits/main/).

## License

MIT. See [LICENSE](LICENSE).
