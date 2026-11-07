# Engineering documentation

English | [简体中文](zh/README.md)

This index lists the engineering documents in the current checkout. Register new Markdown documents under `docs/` in the table for their reading category. English is the default; Chinese translations live under `docs/zh/`.

## Contracts

| Document | Question answered |
| --- | --- |
| [api.md](api.md) | How do third-party addons load, register content, and query or modify the world through `MC.API`? |
| [fault-handling.md](fault-handling.md) | How should internal dependency and resource failures be reported, diagnosed, and handled? |
| [native-cpp-standard.md](native-cpp-standard.md) | How is Native C++ code organized, named, checked, and managed across resource and thread boundaries? |
| [localization.md](localization.md) | How are localization JSON resources packaged, checked, loaded, selected, queried, and used for client-translated player messages? |
| [MC Item conversion rules](../addons/mc_item/AGENTS.md) | How are Minecraft item spaces, units, transforms, and projection converted to Source? |

## Reference

| Document | Question answered |
| --- | --- |
| [README.md](README.md) | Where should readers start with the engineering documentation? |
| [native.md](native.md) | How is the MineMod Native client module installed, diagnosed, and built from source? |
| [airboat-water.md](airboat-water.md) | How do native Source airboats float and drive on Minecraft water? |
| [Project overview](../README.md) | What does MineMod provide, how is the repository organized, and how can developers contribute? |
| [User manual](../docs-user/README.md) | How do players install and play MineMod, manage saves and presets, select packs, and import worlds? |
| [CONTEXT.md](../CONTEXT.md) | What do block states, sections, world packages, and overlays mean? |
| [convar.md](../convar.md) | How are `mc_*` variables and detailed lighting parameters used? |
| [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) | What are the sources and license requirements of third-party components and ported algorithms? |
| [Native SDK](../native/sdk/README.md) | Which SDK dependencies are required to build the Native module? |
| [Shader compiler](../tools/shader_compiler/README.md) | How are compilers prepared, shaders built, and display settings published? |
| [World importer](<../tools/world importer/README.md>) | How is the Java Edition world importer used? |
| [zh/](zh/README.md) | Where are the Chinese project overview, engineering documents, user manual, and tool instructions? |

Categories describe how a document is read: **Contracts** define required behavior; **Reference** supports lookup; **Pitfalls** explain failure modes; **Design** records architecture and tradeoffs; **Process** describes workflows; **External research** analyzes other projects. A subdirectory's index entry covers its contents.
