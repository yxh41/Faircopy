# Faircopy

**Elevate your writing with just a click.**

An AI writing assistant for iOS. Proofread, rewrite, and refine your tone from the text editing menu, using an OpenAI-compatible provider of your choice.

[简体中文](Resources/i18n/zh-Hans/README.md)

![Preview](Resources/Preview.png)

## Table of Contents

- [Lite Edition](#lite-edition)
- [Key Features](#key-features)
- [User Guide](#user-guide)
- [Compatibility](#compatibility)
- [Building from Source](#building-from-source)
- [Acknowledgments](#acknowledgments)
- [License](#license)

## Lite Edition

Faircopy Lite packages the writing assistant as a standalone app. It can be used with [TrollFools](https://github.com/Lessica/TrollFools/) or similar injection tools to bring writing tools into other apps.

To build a `.tipa` package, follow the [build instructions](#building-from-source) below. Configure your own endpoint and model before using the writing tools.

## Key Features

- **Proofread** — Correct spelling, grammar, and punctuation while preserving your meaning.
- **Rewrite** — Improve clarity and flow with a fresh expression of the same ideas.
- **Friendly Tone** — Make messages and everyday writing warmer and more approachable.
- **Professional Tone** — Refine wording for formal, business, or academic communication.
- **Concise Mode** — Remove unnecessary words and keep the essentials.
- **Custom AI Server Configuration** — Connect to an OpenAI-compatible provider or a server you host yourself, with your choice of model.

## User Guide

### Installation

On a compatible jailbroken device, install the `.deb` package for your environment using a package manager such as Sileo. The project supports rootless and RootHide builds; see [Building from Source](#building-from-source).

For the standalone app, see [Lite Edition](#lite-edition).

### Setup Endpoints

Open Faircopy's preferences or the companion app, add an endpoint URL and API key, then select a model. You can configure multiple endpoints and switch between models from the writing tools interface.

The text you submit is sent to your configured server for processing. Choose a provider whose data policy suits your needs, or use a self-hosted server.

#### OpenAI API Providers

The following endpoint examples can be entered in Faircopy. Obtain an API key from your provider and choose a model available to your account.

| Provider | Endpoint | API Key |
| --- | --- | --- |
| [OpenAI](https://platform.openai.com/) | `https://api.openai.com` | [Manage keys](https://platform.openai.com/api-keys) |
| [Together AI](https://www.together.ai/) | `https://api.together.xyz` | [Manage keys](https://api.together.ai/settings/api-keys) |
| [OpenRouter](https://openrouter.ai/) | `https://openrouter.ai/api` | [Manage keys](https://openrouter.ai/settings/keys) |
| [Groq](https://groq.com/) | `https://api.groq.com/openai` | [Manage keys](https://console.groq.com/keys) |
| [NVIDIA NIM](https://build.nvidia.com/) | `https://integrate.api.nvidia.com` | [Developer portal](https://build.nvidia.com/) |

Faircopy adds the `/v1` API path automatically; use the base addresses shown above. Model availability and usage limits are determined by each provider.

The GitHub Models endpoint listed in earlier versions of this guide is no longer available. See [GitHub's service notice](https://docs.github.com/en/github-models).

#### Self-Host AI Server

You can also connect to an OpenAI-compatible server powered by [Ollama](https://ollama.com/) or [Xinference](https://github.com/xorbitsai/inference). Enter an address reachable from your iOS device, configure authentication if required, and select a model served by that endpoint.

## Compatibility

- **iOS:** 15.0 or later.
- **Tweak:** Requires a compatible jailbreak; rootless and RootHide package configurations are included.
- **Lite Edition:** Requires a compatible TrollStore environment. Integration with other apps requires TrollFools or a similar injection tool.
- **Text editing:** Supports UIKit text fields and text views, with WebKit integration. Availability depends on the app's text editing implementation.

## Building from Source

### Requirements

- macOS and Xcode with the iOS SDK.
- [Theos](https://github.com/owngoal-dev/theos) installed at `~/theos`, with its SDKs and build dependencies configured.
- [`swift-create-xcframework@5.9`](https://github.com/Lessica/swift-create-xcframework/releases/tag/v5.9), `xcbeautify`, and `ldid` available in `PATH`.
- For Lite Edition packaging: `insert_dylib` and `7z`.

Keep the checked-in `Package.resolved` files when resolving Swift dependencies.

### Rootless Package

```sh
git clone https://github.com/owngoal-dev/WriteNow.git
cd WriteNow
source devkit/rootless.sh
FINALPACKAGE=1 make package
```

The generated `.deb` file is placed in `packages/`.

### RootHide Package

Use the `legacy-roothide` tag of the RootHide toolchain:

```sh
git clone --recursive --branch legacy-roothide https://github.com/owngoal-dev/theos-roothide.git ~/theos-roothide-legacy
```

Configure its SDKs, then build from the Faircopy repository:

```sh
source devkit/roothide.sh
FINALPACKAGE=1 make package
```

### Lite Edition Package

```sh
source devkit/rootless.sh
./devkit/compile.sh
```

The generated `FaircopyLite_*.tipa` file is placed in `packages/` for installation with TrollStore.

## Acknowledgments

Faircopy is built with these open-source projects:

- [OpenAI for Swift](https://github.com/MacPaw/OpenAI) — OpenAI-compatible API client.
- [SwiftNIO](https://github.com/apple/swift-nio) and [NIOSSL](https://github.com/apple/swift-nio-ssl) — Networking and TLS.
- [ColorfulX](https://github.com/Lakr233/ColorfulX), [ColorVector](https://github.com/Lakr233/ColorVector), [SpringInterpolation](https://github.com/Lakr233/SpringInterpolation), and [MSDisplayLink](https://github.com/Lakr233/MSDisplayLink) — Colors and animation.
- [SwiftUI Introspect](https://github.com/siteline/swiftui-introspect) — Access to underlying UIKit views.
- [libroot](https://github.com/opa334/libroot) — Jailbreak path support.

See [Third-party Notices](THIRD_PARTY_NOTICES.md) for dependency licenses.

## License

Faircopy is available under the [MIT License](LICENSE).

---

**Made with ♥ by OwnGoal Studio**
