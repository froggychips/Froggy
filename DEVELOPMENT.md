# Froggy Engineering Guide

Welcome to Froggy core development. This document defines the standards, tools,
and practices for achieving high performance on **Apple Silicon (ARM64)**.

## 1. Toolchain

* **Instruments (Time Profiler & Memory Graph):** The primary profiling tool.
  Watch unified memory carefully — leaks in `VisionActor` are critical.
* **Swift-Format:** The formatting standard. Required before every commit.
* **xcbeautify:** Use for analyzing build logs: `swift build | xcbeautify`.
* **Sourcery:** Template code generation (Sendable/Actor boilerplate).

## 2. Automation (MCP Layer)

Development uses a suite of MCP servers:

* **FileSystem MCP:** Access to the codebase.
* **GitHub MCP:** Repository and PR management.
* **Local LLM MCP:** Runtime management of MLX models.
* **System Monitor MCP:** Visualization of Vortex metrics (RAM/Process State).

## 3. Knowledge base and decision-making

* **Swift 6 Migration:** All modules must conform to `Strict Concurrency`.
* **MLX Swift Reference:** The primary source for working with tensors.
* **ADR (Architecture Decision Records):** All key decisions (for example,
  choosing an Actor over a Lock) must be recorded in `/docs/adr/`.

## 4. Skills

* **Swift Concurrency Debugging:** Deep understanding of `Task` and `Actor`.
* **Metal Performance Shaders (MPS):** Inference optimization for the GPU
  cache on M-series chips.
* **ARM64 Assembly:** Basic understanding of memory access for optimizing
  MLX layers.

---

*Follow the conventions, write clean code, optimize for ARM64.*
