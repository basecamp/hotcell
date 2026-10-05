---
type: Design
title: "Threat model"
order: 1
description: "What Hot Cell is, the problem it solves, and what a cell is defended against."
---

# Threat model

This page states what Hot Cell is, the problem it exists to solve, and what a cell is defended against.

## What this is

Hot Cell moves untrusted work out of a privileged application process into an unprivileged,
resource-capped, network-less sibling container. The application reaches in through a narrow interface.
The work never reaches out.

A hot cell is a shielded chamber for handling highly radioactive material. The operator stays outside and
manipulates the contents remotely, and nothing leaves except by controlled transfer. The vocabulary
follows: **hot** is untrusted, **cold** is trusted, and material is **posted in** and **posted out**.
Everything else uses the ordinary word.

## The problem

Firejail and similar sandboxes do not work inside a container, because containers and sandboxing use the
same kernel features. An application deployed in a container therefore runs media libraries unconfined. A
vulnerability in libvips, `soffice`, `mutool`, `ffmpeg`, or ImageMagick, reached through an uploaded file,
executes with the application's secrets, its database credentials, its code, and its network.

Two properties of `/proc` shape the response. Scrubbing a tool's environment does not help, because a
file-read primitive can retarget `/proc/<parent>/environ` at a same-UID process and read the environment
that the scrubbed invocation was supposed to hide. And moving secrets out of the environment does not help
either, because the same primitive reads arbitrary files, including a credentials file such as
`config/master.key`.

That leaves two remedies: a bubblewrap or nsjail wrapper inside the application image, or a separate
conversion service holding no secrets. Hot Cell is the second. The second also avoids an open question the
first carries, which is whether an in-image wrapper survives the container runtime it is deployed under.
That is the verification firejail does not pass.

## Threat model

Assume arbitrary code execution inside a cell, or merely an arbitrary file read, reached through a
malicious input file. The design must make that outcome cheap.

In scope: reading application code or secrets, reaching the database, reaching the network, reading
another request's memory or environment, consuming the host's CPU or disk, escalating through a path the
application later opens, and reaching a different cell's toolchain.

Out of scope: a kernel container escape, a malicious operation implementation, and denial of service
against a cell.

Out of scope means the design does not promise to stop it, not that it is harmless. A malicious operation
— most plausibly a supply-chain compromise in a gem an operation depends on — is in fact contained by
everything here, because an operation runs in the same cell under the same limits as the library it
calls. It is excluded because it is not what this design is *for*, and because treating it as in scope
would drag operation review and dependency policy into a document about a transport.

The minimum requirement is a PID and mount namespace exposing only the input and output, with no `/proc`
and no application filesystem. Hot Cell meets the namespace requirement by being a separate container, and
**exceeds the input/output part**: descriptors mean there is no path in the cell to expose or to traverse,
rather than a narrowed set of bind mounts. The `/proc` requirement is treated separately in
[Worker isolation](worker-isolation.md), because it is the one part a container boundary does not give us for free.
