//
//  Workspace_iOS.swift
//  Browser iOS
//
//  The old SavedWorkspace snapshot types lived here. Workspaces are now real
//  SwiftData models (ResearchLedger.swift) whose tabs carry `workspaceId`, so
//  nothing needs to be snapshotted or restored — see docs/phase1-design.md.
//  LedgerMigrator imports any snapshots saved by an older build.
//
